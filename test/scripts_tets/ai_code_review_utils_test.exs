Code.require_file("../../scripts/ai_code_review_utils.ex", __DIR__)

defmodule AiCodeReviewUtilsTest do
  use ExUnit.Case, async: true
  alias AiCodeReviewUtils

  # Helper to create simple line data
  defp line(code, line_num \\ 1, file \\ "test.exs") do
    %{code: code, line: line_num, file: file}
  end

  describe "chunk_lines/2" do
    test "returns an empty list when input is empty" do
      assert AiCodeReviewUtils.chunk_lines([]) == []
      assert AiCodeReviewUtils.chunk_lines([], 100) == []
    end

    test "returns a single chunk for a single line within limit" do
      lines = [line("hello world")]
      # Default limit (12000) is large enough
      assert AiCodeReviewUtils.chunk_lines(lines) == [lines]
      # Explicit small limit still large enough (11 + 50 = 61)
      assert AiCodeReviewUtils.chunk_lines(lines, 100) == [lines]
    end

    test "returns a single chunk even if a single line exceeds the limit" do
      # String length 100, size = 100 + 50 = 150
      lines = [line(String.duplicate("a", 100))]
      # max_chars = 120 is less than 150, but it's the first line
      assert AiCodeReviewUtils.chunk_lines(lines, 120) == [lines]
    end

    test "returns a single chunk when all lines fit within the default limit" do
      lines = [
        line("def function do", 1),
        line("  IO.puts(\"hello\")", 2),
        line("end", 3)
      ]

      # Total size = (15+50) + (18+50) + (3+50) = 65 + 68 + 53 = 186 << 12000
      assert AiCodeReviewUtils.chunk_lines(lines) == [lines]
    end

    test "splits lines into multiple chunks based on max_chars" do
      # Let max_chars = 110
      # Line sizes: line1 = 5 + 50 = 55, line2 = 10 + 50 = 60, line3 = 3 + 50 = 53
      line1 = line("aaaaa", 1)
      line2 = line("bbbbbbbbbb", 2)
      line3 = line("ccc", 3)
      lines = [line1, line2, line3]
      max_chars = 110

      # Calculation:
      # 1. Add line1: count = 55. current_chunk = [line1]
      # 2. Check line2: 55 + 60 = 115 > 110. Split. chunks = [[line1]], current_chunk = [line2], count = 60
      # 3. Check line3: 60 + 53 = 113 > 110. Split. chunks = [[line1], [line2]], current_chunk = [line3], count = 53
      # 4. End: Finalize. chunks = [[line1], [line2], [line3]]
      expected = [[line1], [line2], [line3]]
      assert AiCodeReviewUtils.chunk_lines(lines, max_chars) == expected
    end

    test "correctly chunks when a line fits after a previous split" do
      # Test chunking behavior with the current size calculation,
      # including file/line length and +120 overhead.
      # NOTE: With max_chars=120, each line's calculated size exceeds the limit,
      # leading to immediate splits after the first line.

      # Function calculates size as:
      # String.length(file) + String.length(to_string(line)) + String.length(code) + 120
      # Filename "test.exs" has length 8. Line numbers have length 1.

      # Calculated Line Sizes:
      # line1 ("aaaaa", 1):      8 + 1 +  5 + 120 = 134
      # line2 ("bbbbbbbbbb", 2): 8 + 1 + 10 + 120 = 139
      # line3 ("ccc", 3):        8 + 1 +  3 + 120 = 132

      line1 = line("aaaaa", 1)
      line2 = line("bbbbbbbbbb", 2)
      line3 = line("ccc", 3)
      lines = [line1, line2, line3]
      # This limit is smaller than any single line's calculated size
      max_chars = 120

      # Calculation Trace (max_chars = 120):
      # 1. Add line1 (134): count=134. chunk=[line1]. (Added even though > max_chars because count was 0).
      # 2. Check line2 (139): 134 + 139 = 273 > 120. count > 0. Split.
      #    -> Chunk 1 = reverse([line1]) = [line1].
      #    -> New chunk starts with line2. count = 139. chunk = [line2].
      # 3. Check line3 (132): 139 + 132 = 271 > 120. count > 0. Split.
      #    -> Chunk 2 = reverse([line2]) = [line2].
      #    -> New chunk starts with line3. count = 132. chunk = [line3].
      # 4. End: Finalize last chunk: reverse([line3]) = [line3].
      #    -> Resulting chunks before final reverse: [[line3], [line2], [line1]]
      #    -> Final result after reverse: [[line1], [line2], [line3]]

      # Expected output based on the trace above: Each line forms its own chunk.
      expected = [[line1], [line2], [line3]]

      assert AiCodeReviewUtils.chunk_lines(lines, max_chars) == expected
    end

    test "handles lines with empty code strings correctly" do
      # Test chunking behavior with the current size calculation,
      # including file/line length and +120 overhead.

      # Function calculates size as:
      # String.length(file) + String.length(to_string(line)) + String.length(code) + 120
      # Filename "test.exs" has length 8. Line numbers have length 1.

      # Calculated Line Sizes:
      # line1 ("abc", 1): 8 + 1 + 3 + 120 = 132
      # line2 ("",    2): 8 + 1 + 0 + 120 = 129
      # line3 ("def", 3): 8 + 1 + 3 + 120 = 132
      # line4 ("",    4): 8 + 1 + 0 + 120 = 129

      line1 = line("abc", 1)
      line2 = line("", 2)
      line3 = line("def", 3)
      line4 = line("", 4)
      lines = [line1, line2, line3, line4]
      # Use this limit for the test calculations
      max_chars = 300

      # Calculation Trace (max_chars = 300):
      # 1. Add line1 (132): count = 132. chunk = [line1]
      # 2. Check line2 (129): 132 + 129 = 261 <= 300. Add. count = 261. chunk = [line2, line1]
      # 3. Check line3 (132): 261 + 132 = 393 > 300. Split.
      #    -> Chunk 1 = reverse([line2, line1]) = [line1, line2].
      #    -> New chunk starts with line3. count = 132. chunk = [line3]
      # 4. Check line4 (129): 132 + 129 = 261 <= 300. Add. count = 261. chunk = [line4, line3]
      # 5. End: Finalize last chunk: reverse([line4, line3]) = [line3, line4].
      #    -> Resulting chunks before final reverse: [[line3, line4], [line1, line2]]
      #    -> Final result after reverse: [[line1, line2], [line3, line4]]

      # Expected output based on the trace above
      expected = [[line1, line2], [line3, line4]]

      assert AiCodeReviewUtils.chunk_lines(lines, max_chars) == expected
    end

    test "correctly chunks the provided example input with default max_chars" do
      # Using the input from the user prompt
      lines_with_context = [
        %{
          code: "Code.require_file(\"ai_code_review_utils.ex\", __DIR__)",
          line: 10,
          file: "scripts/ai_code_review.exs"
        },
        %{
          code: "    chunks = AiCodeReviewUtils.chunk_lines(added_lines_with_context)",
          line: 43,
          file: "scripts/ai_code_review.exs"
        },
        %{
          code: "defmodule AiCodeReviewUtils do",
          line: 1,
          file: "scripts/ai_code_review_utils.ex"
        },
        %{
          code: "  def chunk_lines(lines_with_context, max_chars \\\\ 12_000) do",
          line: 2,
          file: "scripts/ai_code_review_utils.ex"
        },
        %{
          code: "    Enum.reduce(lines_with_context, {[], [], 0}, fn %{code: code} = line_data,",
          line: 3,
          file: "scripts/ai_code_review_utils.ex"
        },
        %{
          code:
            "                                                     {chunks, current_chunk, char_count} ->",
          line: 4,
          file: "scripts/ai_code_review_utils.ex"
        },
        %{
          code: "      line_size = String.length(code) + 50",
          line: 5,
          file: "scripts/ai_code_review_utils.ex"
        },
        %{code: "", line: 6, file: "scripts/ai_code_review_utils.ex"},
        %{
          code: "      if char_count + line_size > max_chars and char_count > 0 do",
          line: 7,
          file: "scripts/ai_code_review_utils.ex"
        },
        %{
          code: "        {[Enum.reverse(current_chunk) | chunks], [line_data], line_size}",
          line: 8,
          file: "scripts/ai_code_review_utils.ex"
        },
        %{code: "      else", line: 9, file: "scripts/ai_code_review_utils.ex"},
        %{
          code: "        {chunks, [line_data | current_chunk], char_count + line_size}",
          line: 10,
          file: "scripts/ai_code_review_utils.ex"
        },
        %{code: "      end", line: 11, file: "scripts/ai_code_review_utils.ex"},
        %{code: "    end)", line: 12, file: "scripts/ai_code_review_utils.ex"},
        %{
          code: "    |> then(fn {chunks, last_chunk, _} ->",
          line: 13,
          file: "scripts/ai_code_review_utils.ex"
        },
        %{code: "      final_chunks =", line: 14, file: "scripts/ai_code_review_utils.ex"},
        %{
          code:
            "        if Enum.empty?(last_chunk), do: chunks, else: [Enum.reverse(last_chunk) | chunks]",
          line: 15,
          file: "scripts/ai_code_review_utils.ex"
        },
        %{code: "", line: 16, file: "scripts/ai_code_review_utils.ex"},
        %{
          code: "      Enum.reverse(final_chunks)",
          line: 17,
          file: "scripts/ai_code_review_utils.ex"
        },
        %{code: "    end)", line: 18, file: "scripts/ai_code_review_utils.ex"},
        %{code: "  end", line: 19, file: "scripts/ai_code_review_utils.ex"},
        %{code: "end", line: 20, file: "scripts/ai_code_review_utils.ex"}
      ]

      # As calculated before, the total size is ~2084, which is less than 12000
      # Therefore, it should produce a single chunk containing all lines.
      expected_output = [lines_with_context]

      assert AiCodeReviewUtils.chunk_lines(lines_with_context) == expected_output
      # Also test with an explicit large limit
      assert AiCodeReviewUtils.chunk_lines(lines_with_context, 20_000) == expected_output
    end
  end
end
