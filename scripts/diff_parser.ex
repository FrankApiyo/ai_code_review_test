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
