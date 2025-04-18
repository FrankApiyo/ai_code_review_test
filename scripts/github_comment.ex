defmodule GithubComment do
  @github_token System.fetch_env!("GITHUB_TOKEN")
  @repo System.fetch_env!("GITHUB_REPOSITORY")
  @github_api "https://api.github.com"
  def post_suggestion_comment(
        pr_number,
        commit_id,
        file_path,
        line_number,
        comment_body
      ) do
    url = "#{@github_api}/repos/#{@repo}/pulls/#{pr_number}/comments"

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

  def get_pr_number do
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
end
