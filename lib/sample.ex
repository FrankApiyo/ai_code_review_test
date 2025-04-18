defmodule Sample do
  def unix_five_min_from_now do
    now = DateTime.utc_now()

    unix_now = DateTime.to_unix(now, :second)

    unix_now + 60 * 5
  end
end
