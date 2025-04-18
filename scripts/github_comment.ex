defmodule GithubComment do
  @github_token System.fetch_env!("GITHUB_TOKEN")
  @repo System.fetch_env!("GITHUB_REPOSITORY")
  @github_api "https://api.github.com"

  def post_suggestion_comment(
        pr_number,
        commit_id,
        file_path,
        start_line,
        end_line \\ nil,
        comment_body
      ) do
    url = "#{@github_api}/repos/#{@repo}/pulls/#{pr_number}/comments"

    base_payload = %{
      body: comment_body,
      commit_id: commit_id,
      path: file_path
    }

    request_payload =
      if not is_nil(end_line) and end_line != start_line do
        Map.merge(base_payload, %{
          start_line: start_line,
          line: end_line,
          side: "RIGHT",
          start_side: "RIGHT"
        })
      else
        Map.merge(base_payload, %{
          line: start_line,
          side: "RIGHT"
        })
      end

    line_info =
      if not is_nil(end_line) and end_line != start_line,
        do: "#{start_line}-#{end_line}",
        else: "#{start_line}"

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
          receive_timeout: 120_000
        )

      dbg(response)

      IO.puts(
        "Successfully posted comment to #{file_path}:#{line_info}. Status: #{response.status}"
      )
    rescue
      e ->
        IO.puts("Error posting comment to GitHub for #{file_path}:#{line_info}: #{inspect(e)}")
    end
  end

  def get_pr_number do
    github_ref = System.get_env("GITHUB_REF")

    case Regex.run(~r{refs/pull/(\d+)/merge}, github_ref) do
      [_, pr_num_str] ->
        String.to_integer(pr_num_str)

      _ ->
        IO.puts("Could not extract PR number from GITHUB_REF '#{github_ref}'.")
        nil
    end
  rescue
    _ ->
      IO.puts("Error parsing PR number from GITHUB_REF.")
      nil
  end
end
