Code.require_file("../../scripts/diff_parser.ex", __DIR__)

defmodule DiffParserTest do
  use ExUnit.Case

  alias DiffParser

  test "parses a simple diff with added lines" do
    diff_text = """
    diff --git a/file1.txt b/file1.txt
    index 0000000..e69de29 100644
    --- a/file1.txt
    +++ b/file1.txt
    @@ -0,0 +1,3 @@
    +This is the first added line.
    +This is the second added line.
    +And a third one.
    """

    expected = [
      %{file: "file1.txt", line: 1, code: "This is the first added line."},
      %{file: "file1.txt", line: 2, code: "This is the second added line."},
      %{file: "file1.txt", line: 3, code: "And a third one."}
    ]

    assert DiffParser.parse(diff_text) == expected
  end

  test "parses a diff with multiple files" do
    diff_text = """
    diff --git a/file1.txt b/file1.txt
    index 0000000..e69de29 100644
    --- a/file1.txt
    +++ b/file1.txt
    @@ -0,0 +1 @@
    +Added line in file1.
    diff --git a/path/to/file2.ex b/path/to/file2.ex
    index 0000000..f00d7a8 100644
    --- a/path/to/file2.ex
    +++ b/path/to/file2.ex
    @@ -5,2 +5,3 @@ Existing line
    +  def new_function do
    +    :ok
    +  end
     Another existing line
    """

    expected = [
      %{file: "file1.txt", line: 1, code: "Added line in file1."},
      %{file: "path/to/file2.ex", line: 5, code: "  def new_function do"},
      %{file: "path/to/file2.ex", line: 6, code: "    :ok"},
      %{file: "path/to/file2.ex", line: 7, code: "  end"}
    ]

    assert DiffParser.parse(diff_text) == expected
  end

  test "parses a diff with multiple hunks in one file" do
    diff_text = """
    diff --git a/config.exs b/config.exs
    index 1234567..abcdef0 100644
    --- a/config.exs
    +++ b/config.exs
    @@ -10,3 +10,4 @@ Some context
     config :my_app, key: :value
    +config :my_app, new_key: :new_value
     More context
    @@ -25,0 +27,2 @@ Other context
    +config :another_app, setting: true
    +config :another_app, feature: "enabled"
    """

    expected = [
      %{file: "config.exs", line: 11, code: "config :my_app, new_key: :new_value"},
      %{file: "config.exs", line: 27, code: "config :another_app, setting: true"},
      %{file: "config.exs", line: 28, code: "config :another_app, feature: \"enabled\""}
    ]

    assert DiffParser.parse(diff_text) == expected
  end

  test "parses diff with mixed line types, only extracting added lines" do
    diff_text = """
    diff --git a/main.py b/main.py
    index abcdef0..1234567 100644
    --- a/main.py
    +++ b/main.py
    @@ -5,4 +5,5 @@ def old_function():
     print("hello")
    - removed_line = True
    + added_line_1 = True
    + added_line_2 = False # Example calculation: line 5 (start) + 1 (context) + 1 (added) = line 7
      common_line = 1
    - another_removed = "foo"
    + another_added = "bar" # Example calculation: line 5 (start) + 1 (context) + 1 (added) + 1 (added) + 1 (context) = line 9
    """

    expected = [
      %{file: "main.py", line: 6, code: " added_line_1 = True"},
      %{
        file: "main.py",
        line: 7,
        code:
          " added_line_2 = False # Example calculation: line 5 (start) + 1 (context) + 1 (added) = line 7"
      },
      %{
        file: "main.py",
        line: 9,
        code:
          " another_added = \"bar\" # Example calculation: line 5 (start) + 1 (context) + 1 (added) + 1 (added) + 1 (context) = line 9"
      }
    ]

    assert DiffParser.parse(diff_text) == expected
  end

  test "returns an empty list for empty diff input" do
    assert DiffParser.parse("") == []
  end

  test "returns an empty list for diff with no added lines" do
    diff_text = """
    diff --git a/README.md b/README.md
    index 1111111..2222222 100644
    --- a/README.md
    +++ b/README.md
    @@ -1,3 +1,2 @@
     # Project Title
    -Old description
     Some paragraph.
    """

    assert DiffParser.parse(diff_text) == []
  end

  test "returns an empty list for diff with only headers" do
    diff_text = """
    diff --git a/file.txt b/file.txt
    index 0000000..e69de29 100644
    --- a/file.txt
    +++ b/file.txt
    """

    assert DiffParser.parse(diff_text) == []
  end

  test "skips hunks with malformed headers" do
    diff_text = """
    diff --git a/file1.txt b/file1.txt
    index 0000000..e69de29 100644
    --- a/file1.txt
    +++ b/file1.txt
    @@ -1,1 +NotANumber,3 @@
    +This line should be skipped because the hunk header is bad.
    @@ -5,1 +5,2 @@
     Context
    +This line should be parsed.
    """

    # We can't easily assert IO.puts in standard tests,
    # but we can assert that only the valid hunk was processed.
    expected = [
      %{file: "file1.txt", line: 6, code: "This line should be parsed."}
    ]

    assert DiffParser.parse(diff_text) == expected
  end

  test "skips lines if no file context is established" do
    diff_text = """
    @@ -1,1 +1,2 @@
    +This added line has no file context.
    diff --git a/real_file.txt b/real_file.txt
    --- a/real_file.txt
    +++ b/real_file.txt
    @@ -1,1 +1,1 @@
    +This line should be included.
    +This added line also has no file context.
    """

    # Again, asserting based on the result, assuming warnings are printed.
    expected = [
      %{code: "This line should be included.", file: "real_file.txt", line: 1},
      %{code: "This added line also has no file context.", file: "real_file.txt", line: 2}
    ]

    assert DiffParser.parse(diff_text) == expected
  end

  test "parses diff with spaces in the filename" do
    diff_text = """
    diff --git a/my file with spaces.txt b/my file with spaces.txt
    index 0000000..1111111 100644
    --- a/my file with spaces.txt
    +++ b/my file with spaces.txt
    @@ -0,0 +1,3 @@
    +First line in spaced file.
    +
    +Third line after a blank one.
    diff --git a/another/path with space/file.ex b/another/path with space/file.ex
    index 2222222..3333333 100644
    --- a/another/path with space/file.ex
    +++ b/another/path with space/file.ex
    @@ -5,0 +6,1 @@
    +def new_func(), do: :ok
    """

    expected = [
      %{file: "my file with spaces.txt", line: 1, code: "First line in spaced file."},
      %{file: "my file with spaces.txt", line: 2, code: ""},
      %{file: "my file with spaces.txt", line: 3, code: "Third line after a blank one."},
      %{file: "another/path with space/file.ex", line: 6, code: "def new_func(), do: :ok"}
    ]

    assert DiffParser.parse(diff_text) == expected
  end
end
