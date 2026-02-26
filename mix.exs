defmodule S2.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/commoncurriculum/s2-elixir-client"

  def project do
    [
      app: :s2,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() != :test,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "S2",
      description: "Elixir client for the S2 durable stream API",
      source_url: @source_url,
      homepage_url: "https://s2.dev",
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}"
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ["lib", "mix.exs", "README.md", "LICENSE"],
      links: %{
        "GitHub" => @source_url,
        "S2" => "https://s2.dev"
      }
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:protox, "~> 2.0"},
      {:mint, "~> 1.6"},
      {:telemetry, "~> 1.0"},
      {:ezstd, "~> 1.1", optional: true},
      {:ecto, "~> 3.12", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:oapi_generator, "~> 0.4.0", only: :dev, runtime: false}
    ]
  end
end
