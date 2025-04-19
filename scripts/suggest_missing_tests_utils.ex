defmodule SuggestMissingTestsUtils do
  @doc """
  Builds a map from the coverage data list for efficient lookups.
  Map structure: FilePath => %{coverage: [...], source_lines: [...]}
  """
  def build_coverage_map(coverage_data) when is_list(coverage_data) do
    Enum.reduce(coverage_data, %{}, fn file_coverage, acc ->
      file_name = Map.get(file_coverage, "name")
      coverage = Map.get(file_coverage, "coverage")
      source_lines_str = Map.get(file_coverage, "source")

      if is_binary(source_lines_str) do
        source_lines_list = String.split(source_lines_str, "\n")

        if is_binary(file_name) && is_list(coverage) && is_list(source_lines_list) &&
             length(coverage) == length(source_lines_list) do
          Map.put(acc, file_name, %{
            coverage: coverage,
            source_lines: source_lines_list
          })
        else
          IO.puts(
            :stderr,
            "Warning: Skipping invalid or incomplete coverage entry for file: #{file_name || "Unknown"} (check name, coverage list, source format/length)"
          )

          acc
        end
      else
        IO.puts(
          :stderr,
          "Warning: Skipping invalid or incomplete coverage entry for file: #{file_name || "Unknown"} (missing or invalid source)"
        )

        acc
      end
    end)
  end

  @doc """
  Filters the list of added lines to keep only those with coverage == 0.
  """
  def filter_added_uncovered(added_lines, coverage_map) do
    Enum.filter(added_lines, fn %{file: file_path, line: line_num} ->
      case Map.get(coverage_map, file_path) do
        nil ->
          false

        %{coverage: coverage_list} ->
          coverage_index = line_num - 1

          if coverage_index >= 0 and coverage_index < length(coverage_list) do
            coverage_value = Enum.at(coverage_list, coverage_index)
            coverage_value == 0
          else
            IO.puts(
              :stderr,
              "Warning: Line number #{line_num} for file '#{file_path}' is out of bounds for coverage data (length #{length(coverage_list)}). Skipping check for this line."
            )

            false
          end
      end
    end)
  end
end
