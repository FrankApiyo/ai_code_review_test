defmodule AiCodeReviewUtils do
  def chunk_lines(lines_with_context, max_chars \\ 12_000) do
    Enum.reduce(lines_with_context, {[], [], 0}, fn %{code: code} = line_data,
                                                    {chunks, current_chunk, char_count} ->
      line_size = String.length(code) + 50

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
