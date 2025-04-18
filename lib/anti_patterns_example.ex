# (Line 1) Module definition for demonstrating bad practices
defmodule AntiPatternExample do
  # (Line 3) Define a simple struct for user data
  defstruct name: nil, age: nil, email: nil, city: nil, country: nil, internal_id: nil

  # (Line 6) Function with a long parameter list - hard to manage
  # (Line 7) Processes user details and attempts an operation based on status
  def handle_user_request(
        name,
        age,
        email,
        city,
        country,
        internal_id,
        status_code_string,
        maybe_boolean_flag
      ) do
    # (Line 9) Create a user map - could use a struct but map here
    user_data = %{
      name: name,
      age: age,
      # This field might be nil
      email: email,
      city: city,
      country: country,
      internal_id: internal_id
    }

    # (Line 19) --- Dynamic Atom Creation ---
    # (Line 20) Convert incoming string status code to an atom unsafely
    # Potential atom leak!
    status_atom = String.to_atom(status_code_string)

    # (Line 23) --- Non-Assertive Truthiness & Map Access ---
    # (Line 24) Check status and flag using && (truthy check) instead of 'and' (boolean check)
    # (Line 25) Also uses map[:key] syntax where map.key might be better if email was guaranteed
    if status_atom == :active && maybe_boolean_flag do
      # (Line 27) Get the email using non-assertive access
      # Returns nil if email key is missing or value is nil
      user_email = user_data[:email]
      # (Line 29) Print a message
      IO.puts("Processing active user: #{user_email}")
      # (Line 31) Return success tuple
      {:ok, user_data}
    else
      # (Line 34) Handle the non-active or flagged case
      IO.puts("User not processed or inactive.")
      # (Line 36) Return an error tuple
      {:error, :not_processed}
    end
  end

  # (Line 41) --- Complex `else` in `with` ---
  # (Line 42) Tries to fetch config, then validate it
  def load_and_validate_config(source) do
    # (Line 44) Chain operations using with
    # Step 1: Fetch
    with {:ok, raw_config} <- fetch_config(source),
         # Step 2: Parse
         {:ok, parsed_config} <- parse_config(raw_config),
         # Step 3: Validate
         :ok <- validate_config_structure(parsed_config) do
      # (Line 49) This is the success path
      {:ok, parsed_config}
    else
      # (Line 52) --- Complex/Confusing Else Block ---
      # (Line 53) Handles errors from all steps above in one place
      # Error from fetch_config
      {:error, :not_found} -> {:error, :source_unavailable}
      # Error from parse_config
      {:error, :bad_format} -> {:error, :parsing_failed}
      # Error from validate
      {:error, {:invalid_structure, reason}} -> {:error, :validation_error, reason}
      # (Line 57) Catch-all for other {:error, _} tuples from any step
      {:error, _} -> {:error, :unknown_fetch_or_parse_error}
      # (Line 59) Catch :error atom from any step (less common but possible)
      :error -> {:error, :generic_internal_error}
      # (Line 61) Catch other unexpected return values
      other -> {:error, :unexpected_result, other}
    end
  end

  # (Line 66) --- Complex Extractions in Clauses ---
  # (Line 67) Checks permissions based on user struct fields
  # (Line 68) Extracts name, age, email in head. Name/email used in body, age in guard.
  def check_permission(%{name: name, age: age, email: email} = _user) when age >= 18 do
    # (Line 70) Log the user's name
    IO.puts("Checking permission for adult #{name} (#{email})")
    # (Line 72) Return full permissions
    :full
  end

  # (Line 76) Another clause, similar complex extraction
  def check_permission(%{name: name, age: age, email: email}) when age < 18 do
    # (Line 78) Log the user's name again
    IO.puts("Checking permission for minor #{name} (#{email})")
    # (Line 80) Return limited permissions
    :limited
  end

  # (Line 84) --- Non-Assertive Pattern Matching ---
  # (Line 85) Parses "key=value" string, but doesn't enforce the format robustly
  def sloppy_parse(input_string) do
    # (Line 87) Split the string
    # Limit parts, but still weak
    parts = String.split(input_string, "=", parts: 2)
    # (Line 89) Get first element (key) - could be nil or the whole string
    key = Enum.at(parts, 0)
    # (Line 91) Get second element (value) - could be nil
    value = Enum.at(parts, 1)
    # (Line 93) Does not crash on "keyonly" or "key=val=extra" or ""
    # (Line 94) Just returns potentially incorrect data instead of matching [k, v]
    {key, value}
  end

  # (Line 98) --- Helper functions for `load_and_validate_config` ---
  # (Line 99) Pretends to fetch config
  defp fetch_config(:valid_source), do: {:ok, "key=value\nvalid=true"}
  defp fetch_config(:bad_format_source), do: {:ok, "this is not key value"}
  defp fetch_config(:missing_source), do: {:error, :not_found}
  defp fetch_config(_), do: {:error, :unknown_source}

  # (Line 105) Pretends to parse config
  defp parse_config("key=value\nvalid=true"), do: {:ok, %{"key" => "value", "valid" => "true"}}
  defp parse_config("this is not key value"), do: {:error, :bad_format}
  # Generic error atom
  defp parse_config(_), do: :error

  # (Line 110) Pretends to validate config structure
  defp validate_config_structure(%{"key" => _, "valid" => "true"}), do: :ok

  defp validate_config_structure(%{"key" => _}),
    do: {:error, {:invalid_structure, "missing valid field"}}

  defp validate_config_structure(_), do: {:error, {:invalid_structure, "missing key field"}}
end

# (Line 115) End of module definition
