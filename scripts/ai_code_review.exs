Mix.install([
  {:req, "~> 0.4.5"},
  {:jason, "~> 1.4"},
  {:earmark, "~> 1.4"}
])

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
    IO.puts(diff)
    unchanged_and_added_lines = extract_changed_code(diff)
    IO.puts(unchanged_and_added_lines)

    unchanged_and_added_lines
    # |> chunk_lines()

    # |> Enum.each(fn chunk -u
    #   prompt = build_prompt(chunk, rules)
    #   response = analyze_with_ai(prompt)

    #   Enum.zip(chunk, response)
    #   |> Enum.each(fn {{line, code}, result} ->
    #     if result["violation"] do
    #       if dry_run? do
    #         IO.puts(
    #           "\n---\nDRY RUN: Would comment on line #{line}:\n#{code}\n#{inspect(result)}\n"
    #         )
    #       else
    #         post_comment(line, code, result)
    #       end
    #     end
    #   end)
    # end)
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

  defp chunk_lines(lines, max_chars \\ 12_000) do
    Enum.reduce(lines, {[], [], 0}, fn {line, code}, {chunks, current_chunk, char_count} ->
      code_size = String.length(code)

      if char_count + code_size > max_chars do
        {[Enum.reverse(current_chunk) | chunks], [{line, code}], code_size}
      else
        {chunks, [{line, code} | current_chunk], char_count + code_size}
      end
    end)
    |> then(fn {chunks, last_chunk, _} -> Enum.reverse([Enum.reverse(last_chunk) | chunks]) end)
  end

  defp build_prompt(chunk, rules) do
    rules_text =
      rules
      |> Enum.map(fn %{file: file, ast: ast} -> "- #{file}:\n#{flatten_md(ast)}" end)
      |> Enum.join("\n")

    code_snippets =
      chunk
      |> Enum.map(fn {_line, code} -> "```elixir\n#{code}\n```" end)
      |> Enum.join("\n\n")

    """
    Given the following Elixir code snippets, determine if any of them violate the provided anti-patterns.

    Respond in JSON list format:
    [
      { "violation": true/false, "rule_file": "file.md", "message": "...", "suggestion": "..." },
      ...
    ]

    Code:
    #{code_snippets}

    Rules:
    #{rules_text}
    """
  end

  defp analyze_with_ai(prompt) do
    Req.post!("https://api.openai.com/v1/chat/completions",
      headers: [
        {"Authorization", "Bearer #{@openai_key}"},
        {"Content-Type", "application/json"}
      ],
      json: %{
        model: "gpt-4o",
        messages: [
          %{role: "system", content: "You are an Elixir code reviewer."},
          %{role: "user", content: prompt}
        ],
        temperature: 0.2
      }
    )
    |> Map.get(:body)
    |> Map.get("choices")
    |> List.first()
    |> Map.get("message")
    |> Map.get("content")
    |> Jason.decode!()
  end

  defp post_comment(_line_number, _code, %{
         "message" => msg,
         "suggestion" => suggestion,
         "rule_file" => file
       }) do
    pr_number = get_pr_number()

    body = """
    ⚠️ **AI Code Review Suggestion**

    > #{msg}

    **Suggested fix:**
    ```elixir
    #{suggestion}
    ```

    📘 [View Rule](https://github.com/#{@repo}/blob/main/.ai-code-rules/#{file})
    """

    Req.post!("https://api.github.com/repos/#{@repo}/issues/#{pr_number}/comments",
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
