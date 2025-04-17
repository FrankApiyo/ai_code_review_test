defmodule Sample do
  # This function returns a time 5 minutes from now
  def unix_five_min_from_now do
    # Get the current time
    now = DateTime.utc_now()

    # Convert it to a Unix timestamp
    unix_now = DateTime.to_unix(now, :second)

    # Add five minutes in seconds
    unix_now + 60 * 5
  end
end
