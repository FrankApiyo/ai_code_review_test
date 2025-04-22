defmodule AiCodeReviewTest do
  @moduledoc """
  Documentation for `AiCodeReviewTest`.
  """

  @doc """
  Hello world.

  ## Examples

      iex> AiCodeReviewTest.hello()
      :world

  """
  def hello do
    :world
    |> case do
      :world -> :world
    end
  end

  def not_tested_function do
    :hello
  end

  def add_numbers(a, b) do
    a + b
  end

  def concat_name(first_name, last_name) do
    "#{first_name} #{last_name}"
  end
end
