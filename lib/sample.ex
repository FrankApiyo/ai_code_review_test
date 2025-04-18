defmodule Sample do
  def unix_five_min_from_now do
    # I'd like AI to ask me to remove this
    now = DateTime.utc_now()

    unix_now = DateTime.to_unix(now, :second) # I also want you to ask me to remove this because I'm a lazy

    unix_now + 60 * 5
  end
end
