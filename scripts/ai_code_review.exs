# test
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
          IO.puts("Warning: Could not parse file path from diff line: diff --git a/#{rest}")
          # Continue parsing, but this file might be skipped
          nil
      end

    # Reset line context for the new file
    parse_lines(tail, %{state | current_file: new_file, current_line: nil, lines_in_hunk: nil})
  end

  # Ignore index lines etc.
  defp parse_lines(["index " <> _ | tail], state), do: parse_lines(tail, state)
  defp parse_lines(["--- a/" <> _ | tail], state), do: parse_lines(tail, state)
  defp parse_lines(["+++ b/" <> _ | tail], state), do: parse_lines(tail, state)

  # Hunk header: Set starting line number and reset hunk counter
  defp parse_lines(["@@ -" <> hunk_info | tail], state) do
    # Ensure we have a current file before processing hunks
    if is_nil(state.current_file) do
      # Skip line if file context is missing (shouldn't happen in valid diff)
      IO.puts("Warning: Skipping hunk header because current_file is nil: @@ -#{hunk_info}")
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
        error ->
          IO.puts(
            "Warning: Failed to parse hunk header '@@ -#{hunk_info}': #{inspect(error)}. Skipping."
          )

          # Continue with previous state
          parse_lines(tail, state)
      end
    end
  end

  # Added line: Process ONLY if current_line is an integer (i.e., inside a valid hunk)
  defp parse_lines(
         ["+" <> code | tail],
         %{current_line: line_num, lines_in_hunk: lines_count} = state
       )
       when is_integer(line_num) do
    # Ensure current_file is also set
    if is_nil(state.current_file) do
      # Skip if no file context
      IO.puts("Warning: Skipping added line because current_file is nil: +#{code}")
      parse_lines(tail, state)
    else
      # The line number for an added line corresponds to its position in the *new* file.
      # The starting line number (`line_num`) plus the number of '+' and ' ' lines seen *so far*
      # within this hunk gives the correct line number for *this* added line.
      current_actual_line = line_num + lines_count
      new_result = %{file: state.current_file, line: current_actual_line, code: code}

      new_state = %{
        state
        | results: [new_result | state.results],
          # Increment line count *within the hunk* for the *next* line
          lines_in_hunk: lines_count + 1
      }

      parse_lines(tail, new_state)
    end
  end

  # Context line: Process ONLY if current_line is an integer
  defp parse_lines(
         [" " <> _code | tail],
         %{current_line: line_num, lines_in_hunk: lines_count} = state
       )
       when is_integer(line_num) do
    # Ensure current_file is also set
    if is_nil(state.current_file) do
      # Skip if no file context
      parse_lines(tail, state)
    else
      # Only increment the line count within the hunk for context lines
      new_state = %{state | lines_in_hunk: lines_count + 1}
      parse_lines(tail, new_state)
    end
  end

  # Removed line: We don't track removed lines, but we MUST NOT increment lines_in_hunk
  defp parse_lines(["-" <> _code | tail], %{current_line: line_num} = state)
       when is_integer(line_num) do
    # Don't increment lines_in_hunk
    parse_lines(tail, state)
  end

  # Skip all other lines (including '+', ' ' when current_line is nil, etc.)
  # Also catches empty lines.
  defp parse_lines([_other | tail], state) do
    parse_lines(tail, state)
  end
end

defmodule AICodeReview do
  # e.g., "owner/repo"
  @repo System.fetch_env!("GITHUB_REPOSITORY")
  # Branch being merged
  @pr_branch System.fetch_env!("GITHUB_HEAD_REF")
  # Branch being merged into
  @base_ref System.fetch_env!("GITHUB_BASE_REF")
  @github_token System.fetch_env!("GITHUB_TOKEN")
  # @github_sha System.fetch_env!("GITHUB_SHA") # Often the merge commit, might need HEAD commit

  # --- Constants ---
  @gemini_endpoint "https://generativelanguage.googleapis.com/v1beta/models"
  @github_api "https://api.github.com"
  # Directory for rule markdown files
  @rules_dir ".ai-code-rules"

  def run do
    IO.puts("Starting AI Code Review...")
    IO.puts("Repository: #{@repo}")
    IO.puts("PR Branch: #{@pr_branch}")
    IO.puts("Base Branch: #{@base_ref}")

    dry_run? = Enum.member?(System.argv(), "--dry-run")
    IO.puts("Dry Run: #{dry_run?}")

    # --- Get Required Info ---
    rules = load_rules(@rules_dir)
    IO.puts("Loaded #{Enum.count(rules)} rules from #{@rules_dir}.")

    diff = get_pr_diff()
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
        #        pr_number = get_pr_number()
        #        head_commit_sha = get_head_commit_sha()
        #        IO.puts("PR Number: #{pr_number}")
        #        IO.puts("HEAD Commit SHA: #{head_commit_sha}")

        Enum.each(all_violations, fn violation ->
          # Validate required fields before posting
          required_keys = ["file", "line", "message", "suggestion", "rule_file"]

          if Enum.all?(required_keys, &Map.has_key?(violation, &1)) do
            IO.puts("Posting suggestion for #{violation["file"]}:#{violation["line"]}...")

            #            post_suggestion_comment(
            #              pr_number,
            #              head_commit_sha,
            #              violation["file"],
            #              violation["line"],
            #              violation["message"],
            #              violation["suggestion"],
            #              violation["rule_file"]
            #            )
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

  # --- Git and GitHub API Functions ---

  defp get_pr_diff do
    target_ref = "origin/#{@base_ref}"
    # Ensure the base ref is fetched
    System.cmd("git", ["fetch", "origin", @base_ref])

    IO.puts("Generating diff between HEAD and #{target_ref}...")
    # unified=0 shows only changed lines, which simplifies parsing a bit
    # but requires careful line number tracking
    case System.cmd("git", ["diff", target_ref, "HEAD", "--unified=0"], stderr_to_stdout: true) do
      {out, 0} ->
        out

      {output_or_error, code} ->
        raise "Failed to get PR diff between #{target_ref} and HEAD (exit #{code}): #{output_or_error}"
    end
  end

  defp get_head_commit_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} ->
        String.trim(sha)

      {error_out, code} ->
        raise "Failed to get HEAD commit SHA (exit #{code}): #{error_out}"
    end
  end

  defp get_pr_number do
    # GITHUB_REF for pull requests looks like "refs/pull/123/merge"
    github_ref = System.get_env("GITHUB_REF")

    case Regex.run(~r{refs/pull/(\d+)/merge}, github_ref) do
      [_, pr_num_str] ->
        String.to_integer(pr_num_str)

      _ ->
        # Fallback to API call if GITHUB_REF format isn't as expected
        IO.puts(
          "Could not extract PR number from GITHUB_REF '#{github_ref}'. Falling back to API call."
        )

        fetch_pr_number_from_api()
    end
  rescue
    _ ->
      IO.puts("Error parsing PR number from GITHUB_REF. Falling back to API call.")
      fetch_pr_number_from_api()
  end

  defp fetch_pr_number_from_api do
    # This uses the branch name, which might find multiple PRs if the branch
    # name was reused. Using GITHUB_REF is generally more reliable.
    url =
      "#{@github_api}/repos/#{@repo}/pulls?head=#{@repo |> String.split("/") |> List.first()}:#{@pr_branch}&state=open"

    IO.puts("Fetching PR number from API: #{url}")

    response =
      Req.get!(url,
        headers: [
          {"Authorization", "Bearer #{@github_token}"},
          {"Accept", "application/vnd.github+json"},
          {"X-GitHub-Api-Version", "2022-11-28"}
        ]
      )

    case response.status do
      200 ->
        case Jason.decode!(response.body) do
          # Take the first open PR found for the branch
          [%{"number" => number} | _] ->
            number

          [] ->
            raise "No open pull requests found via API for branch #{@pr_branch} in repo #{@repo}"
        end

      _ ->
        raise "Failed to fetch PR number from API. Status: #{response.status}, Body: #{inspect(response.body)}"
    end
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
    rule_link_path = Path.join(".github/workflows", @rules_dir, rule_file)
    # Link to rule in commit
    rule_link =
      "[View Rule](#{repo_url_base}/blob/#{get_head_commit_sha()}/#{@rules_dir}/#{rule_file})"

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
      # The line in the diff (in the new file) where the comment should appear
      line: line_number,
      # Comments on added lines belong to the "RIGHT" side of the diff
      side: "RIGHT"
    }

    # IO.inspect(request_payload, label: "GitHub Comment Payload") # Debug payload

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
          receive_timeout: 60_000
        )

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

# --- Run the script ---
# test
AICodeReview.run()
