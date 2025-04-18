Mix.install([
  {:req, "~> 0.4.5"},
  {:jason, "~> 1.4"},
  {:earmark, "~> 1.4"}
])

Code.require_file("diff_parser.ex", __DIR__)
Code.require_file("git_utils.ex", __DIR__)
Code.require_file("github_comment.ex", __DIR__)

defmodule AICodeReview do
  @repo System.fetch_env!("GITHUB_REPOSITORY")
  @head_sha System.fetch_env!("PR_HEAD_SHA")
  @pr_branch System.fetch_env!("GITHUB_HEAD_REF")
  @base_ref System.fetch_env!("GITHUB_BASE_REF")
  @github_token System.fetch_env!("GITHUB_TOKEN")
  @gemini_endpoint "https://generativelanguage.googleapis.com/v1beta/models"
  @github_api "https://api.github.com"
  @rules_dir ".ai-code-rules"

  def run do
    IO.puts("Starting AI Code Review...")
    IO.puts("Repository: #{@repo}")
    IO.puts("PR Branch: #{@pr_branch}")
    IO.puts("Base Branch: #{@base_ref}")

    dry_run? = Enum.member?(System.argv(), "--dry-run")
    IO.puts("Dry Run: #{dry_run?}")

    rules = load_rules(@rules_dir)
    IO.puts("Loaded #{Enum.count(rules)} rules from #{@rules_dir}.")

    diff = GitUtils.get_pr_diff(@base_ref)
    IO.puts("Fetched PR diff.")

    added_lines_with_context = DiffParser.parse(diff)

    IO.puts(
      "Parsed diff, found #{Enum.count(added_lines_with_context)} added lines with context."
    )

    chunks = chunk_lines(added_lines_with_context)
    IO.puts("Split added lines into #{Enum.count(chunks)} chunks for AI review.")
    dbg(Enum.count(chunks))

    all_violations =
      Enum.with_index(chunks)
      |> Enum.flat_map(fn {chunk, index} ->
        chunk_index = index + 1

        if Enum.empty?(chunk) do
          IO.puts("--- Chunk #{chunk_index}: SKIPPED (Empty Chunk) ---")
          []
        else
          IO.puts("\n--- Processing Chunk #{chunk_index} ---")
          prompt = build_prompt(chunk, rules)

          IO.puts("===> Sending Chunk #{chunk_index} to AI for review...")

          try do
            response_text = review_code_with_gemini(prompt)

            dbg(response_text)
            violations = Jason.decode!(response_text)

            IO.puts(
              "Received and parsed AI response for Chunk #{chunk_index}. Found #{Enum.count(violations)} potential violations."
            )

            violations
          rescue
            e ->
              IO.puts("Error processing AI response for Chunk #{chunk_index}: #{inspect(e)}")
              []
          end
        end
      end)

    IO.puts("\n--- Posting Suggestions to GitHub ---")

    if dry_run? do
      IO.puts("DRY RUN: Skipping posting comments to GitHub.")

      Enum.each(all_violations, fn violation ->
        start_line = violation["line"]
        end_line = violation["end_line"]

        line_info =
          if end_line && end_line != start_line,
            do: "#{start_line}-#{end_line}",
            else: "#{start_line}"

        IO.puts("DRY RUN: Would post suggestion for #{violation["file"]}:#{line_info}")

        dbg(
          build_suggestion_body(
            violation["message"],
            violation["suggestion"],
            violation["rule_file"],
            start_line,
            end_line
          )
        )
      end)
    else
      dbg(all_violations)

      if Enum.empty?(all_violations) do
        IO.puts("No violations found by AI. No comments to post.")
      else
        IO.puts("Found #{Enum.count(all_violations)} violations. Posting suggestions...")
        dbg(all_violations)

        pr_number = GithubComment.get_pr_number()
        IO.puts("PR Number: #{pr_number}")
        IO.puts("HEAD Commit SHA: #{@head_sha}")

        Enum.each(all_violations, fn violation ->
          required_keys = ["file", "line", "message", "suggestion", "rule_file"]

          if Enum.all?(required_keys, &Map.has_key?(violation, &1)) do
            start_line = violation["line"]
            end_line = violation["end_line"]

            line_info =
              if end_line && end_line != start_line,
                do: "#{start_line}-#{end_line}",
                else: "#{start_line}"

            IO.puts("Posting suggestion for #{violation["file"]}:#{line_info}...")

            comment_body =
              build_suggestion_body(
                violation["message"],
                violation["suggestion"],
                violation["rule_file"],
                start_line,
                end_line
              )

            GithubComment.post_suggestion_comment(
              pr_number,
              @head_sha,
              violation["file"],
              start_line,
              end_line,
              comment_body
            )
          else
            IO.puts(
              "Warning: Skipping violation due to missing required keys (#{Enum.join(required_keys, ", ")}). Violation data:"
            )

            IO.inspect(violation)
          end
        end)

        IO.puts("Finished posting suggestions.")
      end
    end

    IO.puts("AI Code Review script finished.")
  end

  defp load_rules(dir) do
    if File.exists?(dir) and File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.map(fn file ->
        path = Path.join(dir, file)

        try do
          content = File.read!(path)
          %{file: file, content: content}
        rescue
          e ->
            IO.puts("Error reading or parsing rule file #{path}: #{inspect(e)}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
    else
      IO.puts(
        "Warning: Rules directory '#{dir}' not found or is not a directory. No rules loaded."
      )

      []
    end
  end

  defp chunk_lines(lines_with_context, max_chars \\ 12_000) do
    Enum.reduce(lines_with_context, {[], [], 0}, fn %{code: code} = line_data,
                                                    {chunks, current_chunk, char_count} ->
      line_size = String.length(code) + 50

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

  defp build_prompt(chunk, rules) do
    rules_text =
      rules
      |> Enum.map(fn %{file: file, content: content} ->
        "- Rule File: #{file}\n```markdown\n#{content}\n```"
      end)
      |> Enum.join("\n\n")

    code_snippets =
      chunk
      |> Enum.map(fn %{file: file, line: line, code: code} ->
        """
        File: #{file}
        Start Line: #{line}
        ```
        #{code}
        ```
        """
      end)
      |> Enum.join("\n---\n")

    """
    You are an AI code reviewer. Analyze the following code snippets based ONLY on the provided rules.
    Each snippet includes its original file path and the STARTING line number where the added code begins.

    Rules:
    #{rules_text}

    ---

    Code Snippets to Analyze:
    #{code_snippets}

    ---

    Instructions for your response:
    1. Review EACH code snippet provided above against ALL the rules.
    2. Respond ONLY with a valid JSON list ([...]). Do NOT include any text before or after the list.
    3. For EACH snippet where you find a violation of ANY rule:
       - Create a JSON object within the list.
       - This object MUST include:
         - "file": The exact file path provided for the snippet.
         - "line": The exact STARTING line number provided for the snippet where the violation begins.
         - "violation": MUST be boolean `true`.
         - "rule_file": The filename of the rule that was violated (e.g., "comments-overuse.md").
         - "message": A concise explanation of WHY the code violates the specific rule.
         - "suggestion": A code change suggestion formatted for GitHub's suggestion syntax. This should be the complete code to replace the affected line(s). If the suggestion is to remove lines, provide an empty string "".
                    - for suggestions, Make sure you don't replace a line entirely when you can just modify it
                    - in addition, while writing suggestions, make sure to suggest the change based on the context (the lines before and after the line(s) you are changing)
       - This object MAY optionally include:
         - "end_line": If the violation and suggestion span MULTIPLE lines, provide the line number of the LAST affected line in the original file. If the violation affects only a single line, you can omit this field or set it equal to "line".
    4. If a snippet violates multiple rules, create a SEPARATE JSON object for EACH violation.
    5. If NO violations are found in ANY of the provided snippets, respond with an empty JSON list: [].

    Example of a valid response object (single line):
    {
      "file": "path/to/original/file.ex",
      "line": 15,
      "violation": true,
      "rule_file": "style-guide.md",
      "message": "Inconsistent spacing.",
      "suggestion": "  def my_func(arg1, arg2)"
    }

    Example of a valid response object (multi-line):
    {
      "file": "path/to/another/file.ex",
      "line": 42,
      "end_line": 44,
      "violation": true,
      "rule_file": "refactoring-rule.md",
      "message": "This block can be simplified using Enum.map/2.",
      "suggestion": "result = Enum.map(items, fn item -> process(item) end)"
    }

    JSON Response:
    """
  end

  def get_gemini_key(),
    do: System.get_env("GEMINI_API_KEY") || raise("GEMINI_API_KEY environment variable not set")

  def review_code_with_gemini(prompt, model \\ "gemini-2.0-flash") do
    api_key = get_gemini_key()
    url = "#{@gemini_endpoint}/#{model}:generateContent?key=#{api_key}"

    request_body = %{
      "contents" => [
        %{
          "role" => "user",
          "parts" => [%{"text" => prompt}]
        }
      ],
      "generationConfig" => %{
        "temperature" => 0.2,
        "response_mime_type" => "application/json"
      }
    }

    response =
      Req.post!(url,
        headers: [
          {"Content-Type", "application/json"}
        ],
        json: request_body,
        # 6 minutes
        receive_timeout: 360_000
      )

    text_content =
      response.body
      |> Map.fetch!("candidates")
      |> case do
        [candidate | _] -> candidate |> Map.fetch!("content") |> Map.fetch!("parts")
        _ -> nil
      end
      |> case do
        [%{"text" => text} | _] -> text
        _ -> nil
      end

    if text_content do
      cleaned_text =
        text_content
        |> String.trim()
        |> String.trim_leading("```json")
        |> String.trim_leading("```")
        |> String.trim_trailing("```")
        |> String.trim()

      cleaned_text
    else
      finish_reason =
        response.body
        |> Map.get("candidates")
        |> List.first()
        |> Map.get("finishReason", "UNKNOWN")

      safety_ratings =
        response.body |> Map.get("candidates") |> List.first() |> Map.get("safetyRatings", [])

      raise """
      Failed to extract text content from Gemini response.
      Finish Reason: #{inspect(finish_reason)}
      Safety Ratings: #{inspect(safety_ratings)}
      Response Body: #{inspect(response.body)}
      """
    end
  end

  defp build_suggestion_body(message, suggestion, rule_file, start_line, end_line \\ nil) do
    repo_url_base = "https://github.com/#{@repo}"
    rule_link_path = Path.join([@rules_dir, rule_file]) |> String.replace("\\", "/")
    rule_link = "[View Rule](#{repo_url_base}/blob/#{@head_sha}/#{rule_link_path})"

    line_indicator =
      if end_line && end_line != start_line do
        "(Lines #{start_line}-#{end_line})"
      else
        "(Line #{start_line})"
      end

    """
    🤖 **AI Code Review Suggestion** #{line_indicator}

    **Issue:**
    > #{message}

    **Suggestion:**
    ```suggestion
    #{suggestion}
    ```

    ---
    *Rule: #{rule_file} (#{rule_link})*
    """
  end
end

AICodeReview.run()
