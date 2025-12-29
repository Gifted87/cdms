defmodule AcnCms.MixProject do
  use Mix.Project

  def project do
    [
      app: :acn_cms,
      version: "1.0.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      xref: [exclude: [:mnesia]]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {CMS.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Distributed PubSub
      {:phoenix_pubsub, "~> 2.1"},

      # Broadway for Pipelines
      {:broadway, "~> 1.0"},

      # JSON
      {:jason, "~> 1.4"},

      # Numerical Elixir - PINNED to 0.6.4 for Elixir 1.14 compatibility
      {:nx, "0.5.3", override: true},
      {:complex, "0.5.0", override: true},

      # HNSW Vector Lib
      {:hnswlib, "~> 0.1.0"},

      # UUID
      {:elixir_uuid, "~> 1.2"},

      # Telemetry
      {:telemetry, "~> 1.0"},

      # HTTP Client
      {:req, "~> 0.4.0"},

      {:plug_cowboy, "~> 2.6"}

    ]

  end
end
