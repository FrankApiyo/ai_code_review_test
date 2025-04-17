Mix.install([
  {:req, "~> 0.4.5"},
  {:jason, "~> 1.4"},
  {:earmark, "~> 1.4"}
])

defmodule DiffParser do
  def parse(diff_text) do
    # Keep empty lines if they exist
    lines = String.split(diff_text, "\n", trim: false)
    # Initialize state with nil line context
    initial_state = %{current_file: nil, current_line: nil, lines_in_hunk: nil, results: []}

    parse_lines(lines, initial_state)
    |> Map.get(:results)
    |> Enum.reverse()
  end

  # Base case
  defp parse_lines([], state), do: state

  # File header: Set current file, reset line context to nil
  defp parse_lines(["diff --git a/" <> rest | tail], state) do
    # Safer extraction of the 'b' file path
    new_file =
      case String.split(rest, " b/", parts: 2) do
        # Handle potential tabs/spaces
        [_, file_b_part] ->
          String.split(file_b_part, "\t", parts: 2) |> List.first() |> String.trim()

        # Or handle error if format is unexpected
        _ ->
          nil
      end

    # Reset line context for the new file
    parse_lines(tail, %{state | current_file: new_file, current_line: nil, lines_in_hunk: nil})
  end

  # Hunk header: Set starting line number and reset hunk counter
  defp parse_lines(["@@ -" <> hunk_info | tail], state) do
    # Ensure we have a current file before processing hunks
    if is_nil(state.current_file) do
      # Skip line if file context is missing (shouldn't happen in valid diff)
      parse_lines(tail, state)
    else
      try do
        # Extract the part after '+' e.g., "1,7 @@" or "1 @@"
        new_part = String.split(hunk_info, "+", parts: 2) |> Enum.at(1) |> String.trim()
        # Extract the starting line number before the comma or space
        new_start_str = String.split(new_part, [",", " "], parts: 2) |> List.first()
        new_start_line = String.to_integer(new_start_str)
        # Successfully parsed integer, we are now inside a hunk
        parse_lines(tail, %{state | current_line: new_start_line, lines_in_hunk: 0})
      rescue
        # Handle potential errors during parsing (e.g., invalid format, non-integer)
        # Skip malformed hunk header
        _error -> parse_lines(tail, state)
      end
    end
  end

  # Added line: Process ONLY if current_line is an integer (i.e., inside a valid hunk)
  defp parse_lines(["+" <> code | tail], %{current_line: line_num} = state)
       when is_integer(line_num) do
    # Ensure current_file is also set
    if is_nil(state.current_file) do
      # Skip if no file context
      parse_lines(tail, state)
    else
      new_result = %{file: state.current_file, line: line_num + state.lines_in_hunk, code: code}

      new_state = %{
        state
        | results: [new_result | state.results],
          # Increment line count *within the hunk* for the *next* line
          lines_in_hunk: state.lines_in_hunk + 1
      }

      parse_lines(tail, new_state)
    end
  end

  # Context line: Process ONLY if current_line is an integer
  defp parse_lines([" " <> _code | tail], %{current_line: line_num} = state)
       when is_integer(line_num) do
    # Ensure current_file is also set
    if is_nil(state.current_file) do
      # Skip if no file context
      parse_lines(tail, state)
    else
      # Only increment the line count within the hunk
      new_state = %{state | lines_in_hunk: state.lines_in_hunk + 1}
      parse_lines(tail, new_state)
    end
  end

  # Skip all other lines (including '+', ' ' when current_line is nil, '-', index, etc.)
  defp parse_lines([_other | tail], state) do
    parse_lines(tail, state)
  end
end

defmodule AICodeReview do
  @repo System.fetch_env!("GITHUB_REPOSITORY")
  @pr_branch System.fetch_env!("GITHUB_HEAD_REF")
  @base_ref System.fetch_env!("GITHUB_BASE_REF")
  @github_token System.fetch_env!("GITHUB_TOKEN")
  @openai_key System.fetch_env!("OPENAI_API_KEY")

  def run do
    dry_run? = Enum.member?(System.argv(), "--dry-run")
    rules = load_rules(".ai-code-rules")
    diff = get_pr_diff()
    added_lines_with_context = DiffParser.parse(diff)
    chunks = chunk_lines(added_lines_with_context)

    dbg(Enum.count(chunks))

    Enum.with_index(chunks)
    |> Enum.each(fn {chunk, index} ->
      if Enum.empty?(chunk) do
        IO.puts("--- Chunk #{index + 1}: SKIPPED (Empty Chunk) ---")
      else
        # Build the prompt for the current chunk
        prompt = build_prompt(chunk, rules)

        # Print the generated prompt clearly
        IO.puts("\n--- Prompt for Chunk #{index + 1} ---")

        if !dry_run? do
          IO.puts("===> Would send Chunk #{index + 1} to AI...")
          response = review_code(prompt)
          IO.inspect(response, label: "AI Response for Chunk #{index + 1}")
        else
          IO.puts("===> DRY RUN: Chunk #{index + 1} to AI...")
          IO.puts(prompt)
        end

        # ======================================================
      end
    end)
  end

  defp load_rules(dir) do
    dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".md"))
    |> Enum.map(fn file ->
      path = Path.join(dir, file)
      {:ok, md, _} = File.read!(path) |> Earmark.as_ast()
      %{file: file, ast: md}
    end)
  end

  defp get_pr_diff do
    target_ref = "origin/#{@base_ref}"

    case System.cmd("git", ["diff", target_ref, "--unified=0"], stderr_to_stdout: true) do
      {out, 0} ->
        out

      {output_or_error, code} ->
        raise "Failed to get PR diff against #{target_ref} (exit #{code}): #{output_or_error}"
    end
  end

  defp get_pr_number do
    url = "https://api.github.com/repos/#{@repo}/pulls?head=#{@repo}:#{@pr_branch}"

    response =
      Req.get!(url,
        headers: [
          {"Authorization", "Bearer #{@github_token}"},
          {"Accept", "application/vnd.github+json"}
        ]
      )

    case Jason.decode!(response.body) do
      [%{"number" => number} | _] -> number
      [] -> raise "No pull requests found for branch #{@pr_branch}"
    end
  end

  defp extract_changed_code(diff) do
    diff
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, "-"))
    |> Enum.map(&String.trim_leading(&1, "+"))
    |> Enum.join("\n")
  end

  defp chunk_lines(lines_with_context, max_chars \\ 12_000) do
    Enum.reduce(lines_with_context, {[], [], 0}, fn %{code: code} = line_data,
                                                    {chunks, current_chunk, char_count} ->
      code_size = String.length(code)

      # Ensure chunk isn't empty
      if char_count + code_size > max_chars and char_count > 0 do
        {[Enum.reverse(current_chunk) | chunks], [line_data], code_size}
      else
        {chunks, [line_data | current_chunk], char_count + code_size}
      end
    end)
    |> then(fn {chunks, last_chunk, _} -> Enum.reverse([Enum.reverse(last_chunk) | chunks]) end)
    # Filter out potentially empty chunks if the reduce logic allows it
    |> Enum.reject(&Enum.empty?/1)
  end

  defp build_prompt(chunk, rules) do
    rules_text =
      rules
      |> Enum.map(fn %{file: file, ast: ast} -> "- #{file}:\n#{flatten_md(ast)}" end)
      |> Enum.join("\n")

    code_snippets =
      chunk
      |> Enum.map(fn %{file: file, line: line, code: code} ->
        """
        File: #{file}
        Line: #{line}
        ```
        #{code}
        ```
        """
      end)
      # Separator between snippets
      |> Enum.join("\n\n---\n\n")

    """
    Analyze the following code snippets based on the provided rules.
    Each snippet includes its original file path and line number.

    Rules:
    #{rules_text}

    ---

    Code Snippets to Analyze:
    #{code_snippets}

    ---

    Respond ONLY with a valid JSON list. Each object in the list MUST correspond to a snippet where a rule violation is found.
    Each object MUST include the ORIGINAL "file" and "line" number provided for that snippet, along with "violation" (which must be true), "rule_file", "message", and "suggestion".
    If no violations are found for any snippet, respond with an empty JSON list: [].

    Example of a valid response object:
    {
      "file": "path/to/original/file.ex",
      "line": 15,
      "violation": true,
      "rule_file": "comments-overuse.md",
      "message": "This comment explains self-evident code.",
      "suggestion": "Consider removing the comment or renaming variables for clarity."
    }

    JSON Response:
    """
  end

  defp analyze_with_open_ai(prompt) do
    Req.post!("https://api.openai.com/v1/chat/completions",
      headers: [
        {"Authorization", "Bearer #{@openai_key}"},
        {"Content-Type", "application/json"}
      ],
      json: %{
        model: "gpt-4o",
        messages: [
          %{role: "system", content: "You are a keen code reviewer."},
          %{role: "user", content: prompt}
        ],
        temperature: 0.2
      }
    )
    |> Map.get(:body)
    |> dbg()
    |> Map.get("choices")
    |> List.first()
    |> Map.get("message")
    |> Map.get("content")
    |> Jason.decode!()
  end

  @gemini_endpoint "https://generativelanguage.googleapis.com/v1beta/models"

  defp analyze_with_gemini(prompt, api_key, model \\ "gemini-1.5-pro-latest") do
    system_instruction = "You are a code reviewer. Please respond *only* with valid JSON."
    full_prompt = system_instruction <> "\n\n" <> prompt

    url = "#{@gemini_endpoint}/#{model}:generateContent?key=#{api_key}"

    request_body = %{
      "contents" => [
        %{
          "role" => "user",
          "parts" => [%{"text" => full_prompt}]
        }
      ],
      "generationConfig" => %{
        "temperature" => 0.2,
        "response_mime_type" => "application/json"
      }
    }

    Req.post!(url,
      headers: [
        {"Content-Type", "application/json"}
      ],
      json: request_body,
      receive_timeout: 360_000
    )
    |> Map.get(:body)
    |> Map.get("candidates")
    |> List.first()
    |> Map.get("content")
    |> Map.get("parts")
    |> List.first()
    |> Map.get("text")
    |> Jason.decode!()
  end

  def get_gemini_key(), do: System.get_env("GEMINI_API_KEY")

  def review_code(prompt) do
    api_key = get_gemini_key()
    analyze_with_gemini(prompt, api_key)
  end

  defp post_comment(line_number, _code, %{
         "message" => msg,
         "suggestion" => suggestion,
         "rule_file" => file
       }) do
    pr_number = get_pr_number()

    body = """
    ⚠️ **AI Code Review Suggestion**

    > #{msg}

    **Suggested fix:**
    ```
    #{suggestion}
    ```

    📘 [View Rule](https://github.com/#{@repo}/blob/main/.ai-code-rules/#{file})
    """

    Req.post!("https://api.github.com/repos/#{@repo}/pulls/#{pr_number}/comments",
      headers: [
        {"Authorization", "Bearer #{@github_token}"},
        {"Content-Type", "application/json"}
      ],
      json: %{body: body}
    )
  end

  defp flatten_md(ast) do
    ast
    |> List.flatten()
    |> Enum.map(fn
      {tag, _, content} when is_list(content) -> "#{tag}: #{Enum.join(content, " ")}"
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end
end

AICodeReview.run()
