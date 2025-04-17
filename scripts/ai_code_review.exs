Mix.install([
  {:req, "~> 0.4.5"},
  {:jason, "~> 1.4"},
  {:earmark, "~> 1.4"}
])

defmodule AICodeReview do
  @repo System.fetch_env!("GITHUB_REPOSITORY")
  @pr_number System.fetch_env!("GITHUB_REF") |> String.split("/") |> List.last()
  @github_token System.fetch_env!("GITHUB_TOKEN")
  @openai_key System.fetch_env!("OPENAI_API_KEY")

  def run do
    rules = load_rules(".ai-code-rules")
    diff = get_pr_diff()
    green_lines = extract_green_lines(diff)

    green_lines
    |> Enum.each(fn {line, code} ->
      response = analyze_with_ai(code, rules)

      if response["violation"] do
        post_comment(line, code, response)
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
    {out, 0} =
      System.cmd("gh", ["pr", "diff", @pr_number, "--color=never"], stderr_to_stdout: true)

    out
  end

  defp extract_green_lines(diff) do
    diff
    |> String.split("\n")
    |> Enum.filter(&(String.starts_with?(&1, "+") and not String.starts_with?(&1, "+++")))
    |> Enum.map(&String.trim_leading(&1, "+"))
    |> Enum.with_index(1)
  end

  defp analyze_with_ai(code, rules) do
    rules_text =
      rules
      |> Enum.map(fn %{file: file, ast: ast} -> "- #{file}:\n#{flatten_md(ast)}" end)
      |> Enum.join("\n")

    prompt = """
    Given the Elixir code snippet below, determine if it violates any of these anti-patterns.

    Code:
    #{code}

    Rules:
    #{rules_text}

    Respond with JSON: { "violation": true/false, "rule_file": "file.md", "message": "...", "suggestion": "..." }
    """

    Req.post!("https://api.openai.com/v1/chat/completions",
      headers: [
        {"Authorization", "Bearer #{@openai_key}"},
        {"Content-Type", "application/json"}
      ],
      json: %{
        model: "gpt-4",
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

  defp post_comment(line_number, code, %{
         "message" => msg,
         "suggestion" => suggestion,
         "rule_file" => file
       }) do
    body = """
    ⚠️ **AI Code Review Suggestion**

    > #{msg}

    **Suggested fix:**
    ```elixir
    #{suggestion}
    ```

    📘 [View Rule](https://github.com/#{@repo}/blob/main/.ai-code-rules/#{file})
    """

    Req.post!("https://api.github.com/repos/#{@repo}/issues/#{@pr_number}/comments",
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
