defmodule DiffParser do
  def parse(diff_text) do
    lines = String.split(diff_text, "\n", trim: false)
    initial_state = %{current_file: nil, current_line: nil, lines_in_hunk: nil, results: []}

    parse_lines(lines, initial_state)
    |> Map.get(:results)
    |> Enum.reverse()
  end

  defp parse_lines([], state), do: state

  defp parse_lines(["diff --git a/" <> rest | tail], state) do
    new_file =
      case String.split(rest, " b/", parts: 2) do
        [_, file_b_part] ->
          String.split(file_b_part, "\t", parts: 2) |> List.first() |> String.trim()

        _ ->
          IO.puts("Warning: Could not parse file path from diff line: diff --git a/#{rest}")
          nil
      end

    parse_lines(tail, %{state | current_file: new_file, current_line: nil, lines_in_hunk: nil})
  end

  defp parse_lines(["index " <> _ | tail], state), do: parse_lines(tail, state)
  defp parse_lines(["--- a/" <> _ | tail], state), do: parse_lines(tail, state)
  defp parse_lines(["+++ b/" <> _ | tail], state), do: parse_lines(tail, state)

  defp parse_lines(["@@ -" <> hunk_info | tail], state) do
    if is_nil(state.current_file) do
      IO.puts("Warning: Skipping hunk header because current_file is nil: @@ -#{hunk_info}")
      parse_lines(tail, state)
    else
      try do
        new_part = String.split(hunk_info, "+", parts: 2) |> Enum.at(1) |> String.trim()
        new_start_str = String.split(new_part, [",", " "], parts: 2) |> List.first()
        new_start_line = String.to_integer(new_start_str)
        parse_lines(tail, %{state | current_line: new_start_line, lines_in_hunk: 0})
      rescue
        error ->
          IO.puts(
            "Warning: Failed to parse hunk header '@@ -#{hunk_info}': #{inspect(error)}. Skipping."
          )

          parse_lines(tail, state)
      end
    end
  end

  defp parse_lines(
         ["+" <> code | tail],
         %{current_line: line_num, lines_in_hunk: lines_count} = state
       )
       when is_integer(line_num) do
    if is_nil(state.current_file) do
      IO.puts("Warning: Skipping added line because current_file is nil: +#{code}")
      parse_lines(tail, state)
    else
      current_actual_line = line_num + lines_count
      new_result = %{file: state.current_file, line: current_actual_line, code: code}

      new_state = %{
        state
        | results: [new_result | state.results],
          lines_in_hunk: lines_count + 1
      }

      parse_lines(tail, new_state)
    end
  end

  defp parse_lines(
         [" " <> _code | tail],
         %{current_line: line_num, lines_in_hunk: lines_count} = state
       )
       when is_integer(line_num) do
    if is_nil(state.current_file) do
      parse_lines(tail, state)
    else
      new_state = %{state | lines_in_hunk: lines_count + 1}
      parse_lines(tail, new_state)
    end
  end

  defp parse_lines(["-" <> _code | tail], %{current_line: line_num} = state)
       when is_integer(line_num) do
    parse_lines(tail, state)
  end

  defp parse_lines([_other | tail], state) do
    parse_lines(tail, state)
  end
end
