# scripts/git_utils.ex

defmodule GitUtils do
  @moduledoc """
  Provides utility functions for interacting with Git.
  """

  @doc """
  Fetches the specified base_ref from origin and generates a git diff
  between the fetched base_ref and the current HEAD.

  Uses `unified=0` and `--no-color` for machine-readable output suitable
  for parsing by `DiffParser`.

  Args:
    - `base_ref` (String): The base branch name (e.g., "main", "develop").

  Returns:
    - (String): The raw diff text on success.

  Raises:
    - RuntimeError: If the `git fetch` or `git diff` command fails.
  """
  def get_pr_diff(base_ref) when is_binary(base_ref) and base_ref != "" do
    target_ref = "origin/#{base_ref}"
    IO.puts("Fetching base ref '#{base_ref}' from origin...")

    # Fetch command - using --depth=1 can speed things up in CI if full history isn't needed
    # Redirect stderr to stdout to capture potential fetch errors in the output
    case System.cmd("git", ["fetch", "--depth=1", "origin", base_ref], stderr_to_stdout: true) do
      {output, 0} ->
        IO.puts("Fetch successful.")

      # Optionally print output for verbose logging: IO.puts(output)
      {error_out, code} ->
        # Log a warning but continue; the ref might already exist locally from a previous fetch
        IO.puts(
          :stderr,
          "Warning: git fetch failed (exit #{code}). Attempting diff anyway.\nError: #{error_out}"
        )
    end

    IO.puts("Generating diff between HEAD and #{target_ref}...")
    # Prepare arguments for the diff command
    # --no-ext-diff: Avoids external diff helpers
    # --no-indent-heuristic: Can sometimes help with cleaner diffs for parsing
    cmd_args = [
      "diff",
      target_ref,
      "HEAD",
      "--unified=0",
      "--no-color",
      "--no-ext-diff",
      "--no-indent-heuristic"
    ]

    # Execute the diff command
    case System.cmd("git", cmd_args, stderr_to_stdout: true) do
      {out, 0} ->
        # Return the diff text on success
        out

      {output_or_error, code} ->
        # Raise an error on failure, including the command output/error for debugging
        raise "Failed to get PR diff between #{target_ref} and HEAD (exit #{code}): #{output_or_error}"
    end
  end

  def get_pr_diff(_base_ref) do
    raise ArgumentError, "base_ref must be a non-empty string"
  end
end
