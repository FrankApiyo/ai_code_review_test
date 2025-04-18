# test
Mix.install([
  {:req, "~> 0.4.5"},
  {:jason, "~> 1.4"},
  {:earmark, "~> 1.4"}
])

Code.require_file("diff_parser.ex", __DIR__)
Code.require_file("git_utils.ex", __DIR__)

defmodule AICodeReview do
  # e.g., "owner/repo"
  @repo System.fetch_env!("GITHUB_REPOSITORY")
  @head_sha System.fetch_env!("PR_HEAD_SHA")
  # Branch being merged
  @pr_branch System.fetch_env!("GITHUB_HEAD_REF")
  # Branch being merged into
  @base_ref System.fetch_env!("GITHUB_BASE_REF")
  @github_token System.fetch_env!("GITHUB_TOKEN")
  # @github_sha System.fetch_env!("GITHUB_SHA") # Often the merge commit, might need HEAD commit

  # --- Constants ---
  @gemini_endpoint "https://generativelanguage.googleapis.com/v1beta/models"
  @github_api "https://api.github.com"
  @rules_dir ".ai-code-rules"

  def run do
    IO.puts("Starting AI Code Review...")
    IO.puts("Repository: #{@repo}")
    IO.puts("PR Branch: #{@pr_branch}")
    IO.puts("Base Branch: #{@base_ref}")

    # check dry run flag
    dry_run? = Enum.member?(System.argv(), "--dry-run")
    IO.puts("Dry Run: #{dry_run?}")

    # --- Get Required Info ---
    rules = load_rules(@rules_dir)
    IO.puts("Loaded #{Enum.count(rules)} rules from #{@rules_dir}.")

    diff = GitUtils.get_pr_diff(@base_ref)
    IO.puts("Fetched PR diff.")
    # IO.puts("--- DIFF START ---")
    # IO.puts(diff)
    # IO.puts("--- DIFF END ---")

    added_lines_with_context = DiffParser.parse(diff)

    IO.puts(
      "Parsed diff, found #{Enum.count(added_lines_with_context)} added lines with context."
    )

    # --- Process Chunks ---
    chunks = chunk_lines(added_lines_with_context)
    IO.puts("Split added lines into #{Enum.count(chunks)} chunks for AI review.")
    dbg(Enum.count(chunks))

    all_violations =
      Enum.with_index(chunks)
      |> Enum.flat_map(fn {chunk, index} ->
        chunk_index = index + 1

        if Enum.empty?(chunk) do
          IO.puts("--- Chunk #{chunk_index}: SKIPPED (Empty Chunk) ---")
          # Return empty list for empty chunk
          []
        else
          IO.puts("\n--- Processing Chunk #{chunk_index} ---")
          prompt = build_prompt(chunk, rules)

          if dry_run? do
            IO.puts("===> DRY RUN: Would send Chunk #{chunk_index} to AI...")
            IO.puts("--- Prompt for Chunk #{chunk_index} ---")
            IO.puts(prompt)
            # Return empty list in dry run
            []
          else
            IO.puts("===> Sending Chunk #{chunk_index} to AI for review...")

            try do
              # Send to AI and parse response
              response_text = review_code_with_gemini(prompt)

              # IO.inspect(response_text, label: "Raw AI Response Text for Chunk #{chunk_index}") # Debug raw text
              # Decode JSON response
              dbg(response_text)
              violations = Jason.decode!(response_text)

              IO.puts(
                "Received and parsed AI response for Chunk #{chunk_index}. Found #{Enum.count(violations)} potential violations."
              )

              # IO.inspect(violations, label: "Parsed Violations for Chunk #{chunk_index}")
              # Return list of violations for this chunk
              violations
            rescue
              e ->
                IO.puts("Error processing AI response for Chunk #{chunk_index}: #{inspect(e)}")
                # Optionally inspect the raw response if decoding failed
                # IO.inspect(response_text, label: "Failed Raw AI Response for Chunk #{chunk_index}")
                # Return empty list on error
                []
            end
          end
        end
      end)

    # --- Post Comments to GitHub ---
    IO.puts("\n--- Posting Suggestions to GitHub ---")

    if dry_run? do
      IO.puts("DRY RUN: Skipping posting comments to GitHub.")

      Enum.each(all_violations, fn violation ->
        IO.puts("DRY RUN: Would post suggestion for #{violation["file"]}:#{violation["line"]}")
        # IO.inspect(violation) # Optionally print violation details in dry run
      end)
    else
      dbg(all_violations)

      if Enum.empty?(all_violations) do
        IO.puts("No violations found by AI. No comments to post.")
      else
        IO.puts("Found #{Enum.count(all_violations)} violations. Posting suggestions...")
        dbg(all_violations)

        # Fetch PR number and HEAD commit SHA *before* processing chunks
        pr_number = get_pr_number()
        IO.puts("PR Number: #{pr_number}")
        IO.puts("HEAD Commit SHA: #{@head_sha}")

        Enum.each(all_violations, fn violation ->
          # Validate required fields before posting
          required_keys = ["file", "line", "message", "suggestion", "rule_file"]

          if Enum.all?(required_keys, &Map.has_key?(violation, &1)) do
            IO.puts("Posting suggestion for #{violation["file"]}:#{violation["line"]}...")

            post_suggestion_comment(
              pr_number,
              @head_sha,
              violation["file"],
              violation["line"],
              violation["message"],
              violation["suggestion"],
              violation["rule_file"]
            )
          else
            IO.puts("Warning: Skipping violation due to missing keys. Violation data:")
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
          # Use Earmark to parse, but flatten_md is simpler for prompt generation
          # {:ok, md, _} = Earmark.as_ast(content)
          # Store raw content for simpler flatten_md
          %{file: file, content: content}
        rescue
          e ->
            IO.puts("Error reading or parsing rule file #{path}: #{inspect(e)}")
            # Skip this file
            nil
        end
      end)
      # Remove files that failed to load/parse
      |> Enum.reject(&is_nil/1)
    else
      IO.puts(
        "Warning: Rules directory '#{dir}' not found or is not a directory. No rules loaded."
      )

      []
    end
  end

  defp get_pr_number do
    # GITHUB_REF for pull requests looks like "refs/pull/123/merge"
    github_ref = System.get_env("GITHUB_REF")
    IO.inspect(Regex.run(~r{refs/pull/(\d+)/merge}, github_ref))

    case Regex.run(~r{refs/pull/(\d+)/merge}, github_ref) do
      [_, pr_num_str] ->
        String.to_integer(pr_num_str)

      _ ->
        # Fallback to API call if GITHUB_REF format isn't as expected
        IO.puts("Could not extract PR number from GITHUB_REF '#{github_ref}'.")
    end
  rescue
    _ ->
      IO.puts("Error parsing PR number from GITHUB_REF.")
  end

  # --- AI Interaction ---

  defp chunk_lines(lines_with_context, max_chars \\ 12_000) do
    Enum.reduce(lines_with_context, {[], [], 0}, fn %{code: code} = line_data,
                                                    {chunks, current_chunk, char_count} ->
      # Estimate size: code length + file/line info overhead (approx 50 chars)
      line_size = String.length(code) + 50

      # If adding the current line exceeds max_chars AND the current chunk is not empty,
      # finalize the current chunk and start a new one with the current line.
      if char_count + line_size > max_chars and char_count > 0 do
        {[Enum.reverse(current_chunk) | chunks], [line_data], line_size}
      else
        # Otherwise, add the current line to the current chunk.
        {chunks, [line_data | current_chunk], char_count + line_size}
      end
    end)
    |> then(fn {chunks, last_chunk, _} ->
      # Add the last chunk if it's not empty
      final_chunks =
        if Enum.empty?(last_chunk), do: chunks, else: [Enum.reverse(last_chunk) | chunks]

      Enum.reverse(final_chunks)
    end)
  end

  defp build_prompt(chunk, rules) do
    rules_text =
      rules
      # Use raw content now
      |> Enum.map(fn %{file: file, content: content} ->
        "- Rule File: #{file}\n```markdown\n#{content}\n```"
      end)
      |> Enum.join("\n\n")

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
      |> Enum.join("\n---\n")

    """
    You are an AI code reviewer. Analyze the following code snippets based ONLY on the provided rules.
    Each snippet includes its original file path and the line number where the added code begins.

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
         - "line": The exact line number provided for the snippet.
         - "violation": MUST be boolean `true`.
         - "rule_file": The filename of the rule that was violated (e.g., "comments-overuse.md").
         - "message": A concise explanation of WHY the code violates the specific rule.
         - "suggestion": A code change suggestion for the developer to fix the violation. This should be the code the developer can apply. If the suggestion is to remove the line, provide an empty string ""
         - the suggestion should be the code that can be used to replace the line (code that should be in place of what is currently on the line)
      - look at each line carefully please and don't have a line replaced with "" when it could have been edited a different way. you are a pro. reviewer
                        
                        
    4. If a snippet violates multiple rules, create a SEPARATE JSON object for EACH violation.
    5. If NO violations are found in ANY of the provided snippets, respond with an empty JSON list: [].

    Example of a valid response object within the list:
    {
      "file": "path/to/original/file.ex",
      "line": 15,
      "violation": true,
      "rule_file": "comments-overuse.md",
      "message": "This comment explains self-evident code.",
      "suggestion": ""
    }

    JSON Response:
    """
  end

  def get_gemini_key(),
    do: System.get_env("GEMINI_API_KEY") || raise("GEMINI_API_KEY environment variable not set")

  # Using Flash for potential speed/cost benefit
  def review_code_with_gemini(prompt, model \\ "gemini-2.0-flash") do
    api_key = get_gemini_key()
    url = "#{@gemini_endpoint}/#{model}:generateContent?key=#{api_key}"

    # Note: Gemini API doesn't have a dedicated system prompt field like some others.
    # We prepend it to the user prompt.
    # system_instruction = "You are a code reviewer. Please respond *only* with valid JSON."
    # full_prompt = system_instruction <> "\n\n" <> prompt
    # The prompt already includes detailed instructions, including the JSON output format.

    request_body = %{
      "contents" => [
        %{
          "role" => "user",
          # Use the prompt directly
          "parts" => [%{"text" => prompt}]
        }
      ],
      "generationConfig" => %{
        # Lower temperature for more deterministic output
        "temperature" => 0.2,
        # Request JSON output format
        "response_mime_type" => "application/json"
      }
    }

    response =
      Req.post!(url,
        headers: [
          {"Content-Type", "application/json"}
        ],
        json: request_body,
        # 6 minutes timeout
        receive_timeout: 360_000
      )

    # IO.inspect(response, label: "Full Gemini Response") # Debug full response

    # --- Safely extract text ---
    text_content =
      response.body
      |> Map.get("candidates")
      |> case do
        [candidate | _] -> candidate |> Map.get("content") |> Map.get("parts")
        _ -> nil
      end
      |> case do
        [%{"text" => text} | _] -> text
        _ -> nil
      end

    if text_content do
      # Clean potential markdown fences if Gemini wraps the JSON
      cleaned_text =
        text_content
        |> String.trim()
        |> String.trim_leading("```json")
        |> String.trim_leading("```")
        |> String.trim_trailing("```")
        |> String.trim()

      # Return the cleaned text for JSON parsing
      cleaned_text
    else
      # Handle cases where the expected structure isn't present
      finish_reason =
        response.body |> Map.get("candidates") |> List.first() |> Map.get("finishReason")

      safety_ratings =
        response.body |> Map.get("candidates") |> List.first() |> Map.get("safetyRatings")

      raise """
      Failed to extract text content from Gemini response.
      Finish Reason: #{inspect(finish_reason)}
      Safety Ratings: #{inspect(safety_ratings)}
      Response Body: #{inspect(response.body)}
      """
    end
  end

  # --- GitHub Comment Posting ---

  defp build_suggestion_body(message, suggestion, rule_file) do
    repo_url_base = "https://github.com/#{@repo}"
    # Ensure rule file path is relative for the link
    # Adjust base path if rules are elsewhere
    rule_link_path = Path.join([@rules_dir, rule_file])
    # Link to rule in commit
    rule_link =
      "[View Rule](#{repo_url_base}/blob/#{@head_sha}/#{@rules_dir}/#{rule_file})"

    """
    🤖 **AI Code Review Suggestion**

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

  # Renamed and modified function
  defp post_suggestion_comment(
         pr_number,
         commit_id,
         file_path,
         line_number,
         message,
         suggestion,
         rule_file
       ) do
    url = "#{@github_api}/repos/#{@repo}/pulls/#{pr_number}/comments"

    comment_body = build_suggestion_body(message, suggestion, rule_file)

    request_payload = %{
      body: comment_body,
      commit_id: commit_id,
      path: file_path,
      line: line_number,
      side: "RIGHT"
    }

    dbg(request_payload)

    # Debug payload
    IO.inspect(request_payload, label: "GitHub Comment Payload")

    try do
      response =
        Req.post!(url,
          headers: [
            {"Authorization", "Bearer #{@github_token}"},
            {"Accept", "application/vnd.github+json"},
            {"X-GitHub-Api-Version", "2022-11-28"}
          ],
          json: request_payload,
          # Increase timeout for GitHub API calls as well
          # 1 minute
          receive_timeout: 120_000
        )

      dbg(response)

      IO.puts(
        "Successfully posted comment to #{file_path}:#{line_number}. Status: #{response.status}"
      )

      # IO.inspect(response.body) # Debug response body if needed
    rescue
      e ->
        IO.puts("Error posting comment to GitHub for #{file_path}:#{line_number}: #{inspect(e)}")
    end
  end

  # --- Utility Functions ---
  # Removed flatten_md as it's no longer used with raw rule content
  # defp flatten_md(ast) do ... end

  # Removed extract_changed_code as DiffParser handles line selection now
  # defp extract_changed_code(diff) do ... end
end

# Run the script
AICodeReview.run()
