defmodule S2.MixProject do
  use Mix.Project

  @version "1.0.0"
  @source_url "https://github.com/commoncurriculum/s2-elixir-client"

  def project do
    [
      app: :s2_client,
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
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test
      ],
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
      source_ref: "v#{@version}",
      skip_undefined_reference_warnings_on: [
        "S2.S2S.Append",
        "S2.S2S.AppendSession",
        "S2.S2S.Read",
        "S2.S2S.ReadSession",
        "S2.S2S.CheckTail",
        "S2.Patterns.Serialization"
      ],
      groups_for_modules: [
        Overview: [
          S2
        ],
        Store: [
          S2.Store
        ],
        "Control Plane": [
          S2.Client,
          S2.Config,
          S2.Basins,
          S2.Streams,
          S2.AccessTokens,
          S2.Metrics
        ],
        "Data Plane (S2S)": [
          S2.S2S.Connection,
          S2.S2S.Append,
          S2.S2S.AppendSession,
          S2.S2S.Read,
          S2.S2S.ReadSession,
          S2.S2S.CheckTail,
          S2.S2S.Framing
        ],
        Patterns: [
          S2.Patterns.Serialization
        ],
        "Schemas (Generated)":
          ~r/^S2\.(?!V1\.|S2S\.|Store|Client|Config|Error|Basins|Streams|AccessTokens|Metrics|Patterns)/,
        Errors: [
          S2.Error
        ]
      ]
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
      {:excoveralls, "~> 0.18", only: :test},
      {:toxiproxy_ex, "~> 2.0", only: :test},
      {:ecto, "~> 3.12", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:oapi_generator, "~> 0.4.0", only: :dev, runtime: false}
    ]
  end
end
