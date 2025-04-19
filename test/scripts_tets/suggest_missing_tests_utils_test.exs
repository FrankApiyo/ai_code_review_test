Code.require_file("../../scripts/suggest_missing_tests_utils.ex", __DIR__)

defmodule SuggestMissingTestsUtilsTest do
  use ExUnit.Case, async: true
  # If functions are private and Elixir >= 1.15, use @tag :visible
  # Otherwise, ensure functions are public (`def`) for testing.
  # @tag :visible
  alias SuggestMissingTestsUtils

  # Helper to create added_line data
  defp added_line(file, line, code \\ "some code") do
    %{file: file, line: line, code: code}
  end

  describe "build_coverage_map/1" do
    test "returns an empty map for empty input list" do
      assert SuggestMissingTestsUtils.build_coverage_map([]) == %{}
    end

    test "builds map for a single valid coverage entry" do
      input = [
        %{
          "name" => "lib/my_app/file1.ex",
          "coverage" => [1, 0, nil, 1],
          "source" => "line1\nline2\nline3\nline4"
        }
      ]

      expected = %{
        "lib/my_app/file1.ex" => %{
          coverage: [1, 0, nil, 1],
          source_lines: ["line1", "line2", "line3", "line4"]
        }
      }

      assert SuggestMissingTestsUtils.build_coverage_map(input) == expected
    end

    test "builds map for multiple valid coverage entries" do
      input = [
        %{
          "name" => "lib/my_app/file1.ex",
          "coverage" => [1, 0],
          "source" => "line1\nline2"
        },
        %{
          "name" => "lib/my_app/file2.ex",
          "coverage" => [nil, 5],
          "source" => "lineA\nlineB"
        }
      ]

      expected = %{
        "lib/my_app/file1.ex" => %{coverage: [1, 0], source_lines: ["line1", "line2"]},
        "lib/my_app/file2.ex" => %{coverage: [nil, 5], source_lines: ["lineA", "lineB"]}
      }

      assert SuggestMissingTestsUtils.build_coverage_map(input) == expected
    end

    test "skips entries with mismatched coverage and source line counts and captures warning" do
      input = [
        %{
          "name" => "lib/my_app/valid.ex",
          "coverage" => [1],
          "source" => "line1"
        },
        %{
          "name" => "lib/my_app/mismatch.ex",
          # 2 coverage values
          "coverage" => [1, 0],
          # 1 source line
          "source" => "lineA"
        }
      ]

      expected_map = %{
        "lib/my_app/valid.ex" => %{coverage: [1], source_lines: ["line1"]}
      }

      # Capture stderr output
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert SuggestMissingTestsUtils.build_coverage_map(input) == expected_map
        end)

      assert output =~
               "Warning: Skipping invalid or incomplete coverage entry for file: lib/my_app/mismatch.ex"
    end

    test "skips entries with missing or invalid fields and captures warning" do
      input = [
        %{
          "name" => "lib/my_app/valid.ex",
          "coverage" => [1],
          "source" => "line1"
        },
        # Missing name
        %{"coverage" => [1, 0], "source" => "lineA\nlineB"},
        # Missing coverage
        %{"name" => "lib/my_app/no_cov.ex", "source" => "lineC"},
        # Missing source
        %{"name" => "lib/my_app/no_src.ex", "coverage" => [1]},
        %{
          "name" => "lib/my_app/bad_cov.ex",
          # Invalid coverage type
          "coverage" => "not_a_list",
          "source" => "lineD"
        }
      ]

      expected_map = %{
        "lib/my_app/valid.ex" => %{coverage: [1], source_lines: ["line1"]}
      }

      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert SuggestMissingTestsUtils.build_coverage_map(input) == expected_map
        end)

      # Check for warnings (order might vary)
      assert output =~ "Warning: Skipping invalid or incomplete coverage entry for file: Unknown"

      assert output =~
               "Warning: Skipping invalid or incomplete coverage entry for file: lib/my_app/no_cov.ex"

      assert output =~
               "Warning: Skipping invalid or incomplete coverage entry for file: lib/my_app/no_src.ex"

      assert output =~
               "Warning: Skipping invalid or incomplete coverage entry for file: lib/my_app/bad_cov.ex"
    end

    test "handles source with trailing newline correctly" do
      input = [
        %{
          "name" => "lib/my_app/trailing.ex",
          # 3 coverage values
          "coverage" => [1, 0, nil],
          # 2 lines + empty string after split
          "source" => "line1\nline2\n"
        }
      ]

      # String.split("line1\nline2\n", "\n") -> ["line1", "line2", ""] (3 elements)
      expected = %{
        "lib/my_app/trailing.ex" => %{
          coverage: [1, 0, nil],
          source_lines: ["line1", "line2", ""]
        }
      }

      assert SuggestMissingTestsUtils.build_coverage_map(input) == expected
    end
  end

  describe "filter_added_uncovered/2" do
    # Setup a sample coverage map for reuse
    setup do
      coverage_map = %{
        # Lines 1-4
        "lib/file1.ex" => %{coverage: [1, 0, nil, 5], source_lines: ["", "", "", ""]},
        # Lines 1-2
        "lib/file2.ex" => %{coverage: [0, 0], source_lines: ["", ""]}
      }

      %{coverage_map: coverage_map}
    end

    test "returns empty list when added_lines is empty", %{coverage_map: map} do
      assert SuggestMissingTestsUtils.filter_added_uncovered([], map) == []
    end

    test "filters out lines from files not in coverage map", %{coverage_map: map} do
      lines = [added_line("lib/unknown.ex", 1)]
      assert SuggestMissingTestsUtils.filter_added_uncovered(lines, map) == []
    end

    test "filters out lines with non-zero coverage", %{coverage_map: map} do
      lines = [
        # Coverage = 1
        added_line("lib/file1.ex", 1),
        # Coverage = 5
        added_line("lib/file1.ex", 4)
      ]

      assert SuggestMissingTestsUtils.filter_added_uncovered(lines, map) == []
    end

    test "filters out lines with nil coverage", %{coverage_map: map} do
      # Coverage = nil
      lines = [added_line("lib/file1.ex", 3)]
      assert SuggestMissingTestsUtils.filter_added_uncovered(lines, map) == []
    end

    test "keeps lines with zero coverage", %{coverage_map: map} do
      # Coverage = 0
      line_f1_l2 = added_line("lib/file1.ex", 2)
      # Coverage = 0
      line_f2_l1 = added_line("lib/file2.ex", 1)
      # Coverage = 0
      line_f2_l2 = added_line("lib/file2.ex", 2)
      lines = [line_f1_l2, line_f2_l1, line_f2_l2]

      # Order should be preserved
      expected = [line_f1_l2, line_f2_l1, line_f2_l2]
      assert SuggestMissingTestsUtils.filter_added_uncovered(lines, map) == expected
    end

    test "handles mix of covered, uncovered, and unknown lines", %{coverage_map: map} do
      lines = [
        # Covered (1) -> filter out
        added_line("lib/file1.ex", 1),
        # Uncovered (0) -> keep
        added_line("lib/file1.ex", 2),
        # Unknown file -> filter out
        added_line("lib/unknown.ex", 1),
        # Uncovered (0) -> keep
        added_line("lib/file2.ex", 1),
        # Nil coverage -> filter out
        added_line("lib/file1.ex", 3)
      ]

      expected = [
        added_line("lib/file1.ex", 2),
        added_line("lib/file2.ex", 1)
      ]

      assert SuggestMissingTestsUtils.filter_added_uncovered(lines, map) == expected
    end

    test "filters out lines with out-of-bounds line numbers and captures warning", %{
      coverage_map: map
    } do
      lines = [
        # Line num 0 -> index -1 (out of bounds)
        added_line("lib/file1.ex", 0),
        # Line num 5 -> index 4 (out of bounds for length 4)
        added_line("lib/file1.ex", 5),
        # Line num 2 -> index 1 (valid, uncovered=0) -> keep
        added_line("lib/file1.ex", 2)
      ]

      expected = [added_line("lib/file1.ex", 2)]

      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert SuggestMissingTestsUtils.filter_added_uncovered(lines, map) == expected
        end)

      assert output =~
               "Warning: Line number 0 for file 'lib/file1.ex' is out of bounds for coverage data (length 4). Skipping check for this line."

      assert output =~
               "Warning: Line number 5 for file 'lib/file1.ex' is out of bounds for coverage data (length 4). Skipping check for this line."
    end
  end
end
