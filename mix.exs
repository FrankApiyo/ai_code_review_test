defmodule AiCodeReviewTest.MixProject do
  use Mix.Project

  def project do
    [
      app: :ai_code_review_test,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.json": :test,
        "coveralls.github": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {AiCodeReviewTest.Application, []}
    ]
  end

  defp deps do
    [
      {:excoveralls, "~> 0.18", only: [:test]}
    ]
  end
end
