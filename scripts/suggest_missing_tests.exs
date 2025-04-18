Mix.install([
  {:req, "~> 0.4.5"},
  {:jason, "~> 1.4"}
])

Code.require_file("diff_parser.ex", __DIR__)
Code.require_file("git_utils.ex", __DIR__)
Code.require_file("github_comment.ex", __DIR__)

defmodule SuggestMissingTests do
  @coverage_file "cover/excoveralls.json"
  @gemini_endpoint "https://generativelanguage.googleapis.com/v1beta/models"
  @gemini_model "gemini-2.0-flash"
  @head_sha System.fetch_env!("PR_HEAD_SHA")

  defp get_base_ref do
    case System.fetch_env("GITHUB_BASE_REF") do
      {:ok, ref} -> ref
      :error -> raise "Required environment variable GITHUB_BASE_REF is not set."
    end
  end

  def run do
    IO.puts("Starting Suggest Missing Tests script...")
    IO.puts("Mode: Suggesting tests for lines ADDED in the diff and UNCOVERED.")

    dry_run? = Enum.member?(System.argv(), "--dry-run")
    IO.puts("Dry Run: #{dry_run?}")

    base_ref = get_base_ref()
    diff = GitUtils.get_pr_diff(base_ref)
    added_lines = DiffParser.parse(diff)

    IO.puts(
      "Parsed diff against base branch '#{base_ref}'. Found #{Enum.count(added_lines)} added lines."
    )

    if Enum.empty?(added_lines) do
      IO.puts("No added lines found in the diff. Exiting.")
      System.halt(0)
    end

    coverage_data = read_coverage_file(@coverage_file)
    IO.puts("Successfully read and parsed #{@coverage_file}.")
    coverage_map = build_coverage_map(coverage_data)
    IO.puts("Built coverage map for #{map_size(coverage_map)} files.")

    added_and_uncovered_lines = filter_added_uncovered(added_lines, coverage_map)

    IO.puts(
      "Filtered lines: Found #{Enum.count(added_and_uncovered_lines)} added lines that are also uncovered."
    )

    if Enum.empty?(added_and_uncovered_lines) do
      IO.puts("No added lines require test suggestions based on coverage. Exiting.")
      System.halt(0)
    end

    chunks = chunk_lines(added_and_uncovered_lines, 15_000)
    IO.puts("Split added & uncovered lines into #{Enum.count(chunks)} chunks for AI suggestion.")

    all_suggestions = process_chunks(chunks)

    output_suggestions(all_suggestions, dry_run?)

    IO.puts("\nSuggest Missing Tests script finished.")
  end

  @doc """
  Reads and parses the JSON coverage file.
  """
  defp read_coverage_file(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} ->
            if is_map(data) do
              case Map.get(data, "source_files") do
                source_files when is_list(source_files) ->
                  source_files

                _ ->
                  raise(
                    "Invalid JSON structure in #{path}: Expected a map containing a 'source_files' list."
                  )
              end
            else
              raise("Invalid JSON structure in #{path}: Expected a JSON object (map).")
            end

          {:error, reason} ->
            raise "Failed to decode JSON from #{path}: #{inspect(reason)}"
        end

      {:error, reason} ->
        raise "Failed to read coverage file #{path}: #{reason}"
    end
  end

  @doc """
  Builds a map from the coverage data list for efficient lookups.
  Map structure: FilePath => %{coverage: [...], source_lines: [...]}
  """
  defp build_coverage_map(coverage_data) when is_list(coverage_data) do
    Enum.reduce(coverage_data, %{}, fn file_coverage, acc ->
      file_name = Map.get(file_coverage, "name")
      coverage = Map.get(file_coverage, "coverage")
      source_lines = Map.get(file_coverage, "source")
      source_lines_list = String.split(source_lines, "\n")

      if is_binary(file_name) && is_list(coverage) && is_list(source_lines_list) &&
           length(coverage) == length(source_lines_list) do
        Map.put(acc, file_name, %{
          coverage: coverage,
          source_lines: source_lines_list
        })
      else
        IO.puts(
          :stderr,
          "Warning: Skipping invalid or incomplete coverage entry for file: #{file_name || "Unknown"}"
        )

        acc
      end
    end)
  end

  @doc """
  Filters the list of added lines to keep only those with coverage == 0.
  """
  defp filter_added_uncovered(added_lines, coverage_map) do
    Enum.filter(added_lines, fn %{file: file_path, line: line_num} ->
      case Map.get(coverage_map, file_path) do
        nil ->
          false

        %{coverage: coverage_list} ->
          coverage_index = line_num - 1

          if coverage_index >= 0 and coverage_index < length(coverage_list) do
            coverage_value = Enum.at(coverage_list, coverage_index)
            coverage_value == 0
          else
            IO.puts(
              :stderr,
              "Warning: Line number #{line_num} for file '#{file_path}' is out of bounds for coverage data (length #{length(coverage_list)}). Skipping check for this line."
            )

            false
          end
      end
    end)
  end

  @doc """
  Processes chunks of lines by sending them to the AI and collecting suggestions.
  """
  defp process_chunks(chunks) do
    Enum.with_index(chunks)
    |> Enum.flat_map(fn {chunk, index} ->
      chunk_index = index + 1

      if Enum.empty?(chunk) do
        IO.puts("--- Chunk #{chunk_index}: SKIPPED (Empty Chunk) ---")
        []
      else
        IO.puts("\n--- Processing Chunk #{chunk_index} (#{Enum.count(chunk)} lines) ---")
        prompt = build_suggestion_prompt(chunk)
        IO.puts("===> Sending Chunk #{chunk_index} to AI for test suggestions...")

        try do
          response_text = suggest_tests_with_gemini(prompt, @gemini_model)

          try do
            suggestions = Jason.decode!(response_text)

            IO.puts(
              "Received and parsed AI response for Chunk #{chunk_index}. Found #{Enum.count(suggestions)} suggestions."
            )

            suggestions
          rescue
            e in [Jason.DecodeError] ->
              IO.puts(
                :stderr,
                "Error decoding JSON response for Chunk #{chunk_index}: #{inspect(e)}"
              )

              IO.puts(:stderr, "Raw Response was:\n#{response_text}")
              []
          end
        catch
          {:error, type, message} ->
            IO.puts(
              :stderr,
              "Error processing AI request for Chunk #{chunk_index} [Type: #{type}]: #{message}"
            )

            []

          thrown_value ->
            IO.puts(
              :stderr,
              "Unexpected value thrown during AI request for Chunk #{chunk_index}: #{inspect(thrown_value)}"
            )

            []
        end
      end
    end)
  end

  @doc """
  Prints the collected suggestions to the console.
  """
  defp output_suggestions(all_suggestions, dry_run?) do
    IO.puts("\n--- AI Test Suggestions ---")
    pr_number = GithubComment.get_pr_number()
    IO.puts("PR Number: #{pr_number}")
    IO.puts("HEAD Commit SHA: #{@head_sha}")

    if Enum.empty?(all_suggestions) do
      IO.puts("No suggestions were generated by the AI for the added & uncovered lines.")
    else
      IO.puts("Total suggestions received: #{Enum.count(all_suggestions)}")

      Enum.each(all_suggestions, fn suggestion ->
        required_keys = ["file", "line", "original_code", "suggested_test"]

        if is_map(suggestion) && Enum.all?(required_keys, &Map.has_key?(suggestion, &1)) do
          test_suggestion =
            build_suggestion_body(suggestion["original_code"], suggestion["suggested_test"])

          IO.puts("--------------------")
          IO.puts("File: #{suggestion["file"]}")
          IO.puts("Line: #{suggestion["line"]}")
          IO.puts(test_suggestion)

          if !dry_run? do
            GithubComment.post_suggestion_comment(
              pr_number,
              @head_sha,
              suggestion["file"],
              suggestion["line"],
              nil,
              test_suggestion
            )
          else
            IO.puts("\nDry run complete. Suggestions printed above.")
          end
        else
          IO.puts("--------------------")
          IO.puts("Warning: Received suggestion item with missing or invalid format. Data:")
          IO.inspect(suggestion)
        end
      end)
    end
  end

  defp build_suggestion_body(original_code, test_suggestion) do
    """
    🤖 **AI Test Suggestion**

    ```elixir
     #{original_code}
    ```

    **Test suggestion:**
    ```elixir
    #{test_suggestion}
    ```
    """
  end

  # --- AI Interaction ---

  @doc """
  Splits the list of lines into chunks based on estimated character count.
  """
  defp chunk_lines(lines_data, max_chars \\ 15_000) do
    unless is_list(lines_data) and is_integer(max_chars) and max_chars > 0 do
      raise ArgumentError, "Invalid arguments for chunk_lines/2"
    end

    Enum.reduce(lines_data, {[], [], 0}, fn %{file: file, line: line, code: code} = line_data,
                                            {chunks, current_chunk, char_count} ->
      line_size = String.length(file) + String.length(to_string(line)) + String.length(code) + 80

      if char_count + line_size > max_chars and char_count > 0 do
        {[Enum.reverse(current_chunk) | chunks], [line_data], line_size}
      else
        {chunks, [line_data | current_chunk], char_count + line_size}
      end
    end)
    |> then(fn {chunks, last_chunk, _} ->
      final_chunks =
        if Enum.empty?(last_chunk), do: chunks, else: [Enum.reverse(last_chunk) | chunks]

      Enum.reverse(final_chunks)
    end)
  end

  @doc """
  Builds the prompt string to send to the Gemini API for a chunk of lines.
  """
  defp build_suggestion_prompt(chunk) do
    unless is_list(chunk) and Enum.all?(chunk, &match?(%{file: _, line: _, code: _}, &1)) do
      raise ArgumentError, "Invalid chunk format provided to build_suggestion_prompt/1"
    end

    code_snippets =
      chunk
      |> Enum.map(fn %{file: file, line: line, code: code} ->
        trimmed_code = String.trim(code)

        """
        File: #{file}
        Line: #{line}
        Uncovered Code:
        ```elixir
        #{trimmed_code}
        ```
        """
      end)
      |> Enum.join("\n---\n")

    """
    You are an AI assistant specialized in writing Elixir tests using the ExUnit framework.
    Your task is to analyze the provided Elixir code snippets, which represent lines recently ADDED to the codebase and are currently NOT covered by any tests. Suggest a basic ExUnit test case for EACH snippet.

    Code Snippets to Analyze:
    #{code_snippets}

    ---

    Instructions for your response:
    1. Review EACH code snippet provided above.
    2. For EACH snippet, suggest a simple, focused ExUnit test case (`test "..." do ... end`) that would cover the provided line of code.
       - Assume the code exists within a standard Elixir module structure. Focus on testing the logic of the given line.
       - If the line is part of a larger function, the test should aim to execute that specific line.
       - Keep setup minimal.
       - The test should be runnable ExUnit code. Include necessary `alias` or `import` if obvious and required for the snippet.
    3. Respond ONLY with a valid JSON list ([...]). Do NOT include any text, markdown formatting (like ```json), or explanations before or after the JSON list.
    4. The JSON list should contain one object for EACH snippet you provide a suggestion for.
    5. Each JSON object MUST include the following keys:
       - "file": The exact file path provided for the snippet.
       - "line": The exact line number provided for the snippet.
       - "original_code": The exact code snippet provided (use the trimmed version as shown in the input).
       - "suggested_test": A string containing the suggested ExUnit test case code. Use newline characters (`\\n`) for line breaks within the test code string. Ensure the suggestion is complete and syntactically valid Elixir test code.
    6. If you cannot reasonably suggest a test for a specific snippet (e.g., it's just `end`, a comment, purely declarative like `@moduledoc`, or lacks sufficient context), you MAY omit an object for that snippet in the response list.
    7. Ensure the entire response is a single, valid JSON list.

    Example of a valid response object within the list:
    {
      "file": "lib/my_app/calculator.ex",
      "line": 25,
      "original_code": "a + b",
      "suggested_test": "test \\"adds two positive numbers\\" do\\n  assert Calculator.add(2, 3) == 5\\nend"
    }

    JSON Response:
    """
  end

  @doc """
  Retrieves the Gemini API key from environment variables.
  """
  def get_gemini_key() do
    System.get_env("GEMINI_API_KEY") || raise("GEMINI_API_KEY environment variable not set")
  end

  @doc """
  Sends the prompt to the Gemini API and returns the text content of the response.
  Throws specific error tuples on failure.
  """
  def suggest_tests_with_gemini(prompt, model \\ @gemini_model) do
    api_key = get_gemini_key()
    url = "#{@gemini_endpoint}/#{model}:generateContent?key=#{api_key}"

    request_body = %{
      "contents" => [%{"role" => "user", "parts" => [%{"text" => prompt}]}],
      "generationConfig" => %{
        "temperature" => 0.5,
        "response_mime_type" => "application/json"
      }
    }

    case Req.post(url,
           headers: [{"Content-Type", "application/json"}, {"Accept", "application/json"}],
           json: request_body,
           receive_timeout: 300_000
         ) do
      {:ok, %{status: 200, body: response_body}} ->
        text_content =
          response_body
          |> Map.get("candidates")
          |> List.first()
          |> Map.get("content", %{})
          |> Map.get("parts", [])
          |> List.first()
          |> Map.get("text")

        if text_content do
          cleaned_text =
            text_content
            |> String.trim()
            |> String.replace(~r/^```json\s*/, "")
            |> String.replace(~r/\s*```$/, "")
            |> String.trim()

          cleaned_text
        else
          prompt_feedback = Map.get(response_body, "promptFeedback", %{})
          block_reason = Map.get(prompt_feedback, "blockReason", "Unknown")

          finish_reason =
            response_body
            |> Map.get("candidates")
            |> List.first()
            |> Map.get("finishReason", "Unknown")

          if block_reason != "Unknown" && block_reason != "BLOCK_REASON_UNSPECIFIED" do
            throw(
              {:error, :api_blocked,
               "Gemini request blocked. Reason: #{inspect(block_reason)}. Finish Reason: #{finish_reason}. Feedback: #{inspect(prompt_feedback)}"}
            )
          else
            throw(
              {:error, :api_no_content,
               "Failed to extract text content from Gemini response. Finish Reason: #{finish_reason}. Body: #{inspect(response_body)}"}
            )
          end
        end

      {:ok, %{status: status, body: error_body}} when status >= 400 ->
        error_details = Map.get(error_body, "error", %{})
        error_message = Map.get(error_details, "message", "Unknown API error")

        throw(
          {:error, :api_http_error,
           "Gemini API request failed with HTTP status #{status}. Message: #{error_message}. Body: #{inspect(error_body)}"}
        )

      {:error, reason} ->
        throw({:error, :req_error, "HTTP request library error: #{inspect(reason)}"})
    end
  end
end

SuggestMissingTests.run()
