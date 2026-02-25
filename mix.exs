defmodule S2.MixProject do
  use Mix.Project

  def project do
    [
      app: :s2,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {S2.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:protox, "~> 2.0"},
      {:mint, "~> 1.6"},
      {:oapi_generator, "~> 0.4.0", only: :dev, runtime: false}
    ]
  end
end
