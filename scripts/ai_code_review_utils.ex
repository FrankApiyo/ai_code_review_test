defmodule AiCodeReviewUtils do
  def chunk_lines(lines_data, max_chars \\ 15_000) do
    unless is_list(lines_data) and is_integer(max_chars) and max_chars > 0 do
      raise ArgumentError, "Invalid arguments for chunk_lines/2"
    end

    Enum.reduce(lines_data, {[], [], 0}, fn %{file: file, line: line, code: code} = line_data,
                                            {chunks, current_chunk, char_count} ->
      line_size = String.length(file) + String.length(to_string(line)) + String.length(code) + 120

      if char_count + line_size > max_chars and char_count > 0 do
        {[Enum.reverse(current_chunk) | chunks], [line_data], line_size}
      else
        {chunks, [line_data | current_chunk], char_count + line_size}
      end
    end)
    |> then(fn {chunks, last_chunk, _} ->
      final_chunks =
        if Enum.empty?(last_chunk), do: chunks, else: [Enum.reverse(last_chunk) | chunks]

      Enum.reverse(final_chunks)
    end)
  end
end
