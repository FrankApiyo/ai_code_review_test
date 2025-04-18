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

    case System.cmd("git", ["fetch", "--depth=1", "origin", base_ref], stderr_to_stdout: true) do
      {_output, 0} ->
        IO.puts("Fetch successful.")

      {error_out, code} ->
        IO.puts(
          :stderr,
          "Warning: git fetch failed (exit #{code}). Attempting diff anyway.\nError: #{error_out}"
        )
    end

    IO.puts("Generating diff between HEAD and #{target_ref}...")

    cmd_args = [
      "diff",
      target_ref,
      "HEAD",
      "--unified=0",
      "--no-color",
      "--no-ext-diff",
      "--no-indent-heuristic"
    ]

    case System.cmd("git", cmd_args, stderr_to_stdout: true) do
      {out, 0} ->
        out

      {output_or_error, code} ->
        raise "Failed to get PR diff between #{target_ref} and HEAD (exit #{code}): #{output_or_error}"
    end
  end

  def get_pr_diff(_base_ref) do
    raise ArgumentError, "base_ref must be a non-empty string"
  end
end
