defmodule GenswarmsObjects.MixProject do
  use Mix.Project

  def project do
    [
      app: :genswarms_objects,
      version: "0.1.4",
      elixir: "~> 1.14",
      elixirc_paths: ["packages"],
      start_permanent: Mix.env() == :prod,
      source_url: "https://github.com/genlayerlabs/genswarms-objects",
      description:
        "Utility object handlers for genswarms swarms: cron (deterministic scheduler), " <>
          "browser (allowlist- or denylist-gated web browser for agents), metrics (durable daily counters), " <>
          "tips (rotating-content dispenser)",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # genswarms is a peer/runtime dependency provided by the host app (object
  # callbacks are implemented by convention; ObjectServer delivery is runtime-only).
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"}
    ]
  end
end
