defmodule PhoenixKitTemplates.MixProject do
  use Mix.Project

  @source_url "https://github.com/BeamLabEU/phoenix_kit_templates"
  @version "0.2.2"

  def project do
    [
      app: :phoenix_kit_templates,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      description:
        "Locale-aware message template rendering: host overrides, {{variable}} substitution.",
      dialyzer: [plt_file: {:no_warn, "priv/plts/dialyzer.plt"}, plt_add_apps: [:ex_unit]]
    ]
  end

  # No runtime dependencies, deliberately: phoenix_kit depends on THIS package,
  # so anything pulled in here lands upstream of the entire tree.
  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      extras: [
        "README.md": [title: "Overview"],
        "CHANGELOG.md": [title: "Changelog"],
        LICENSE: [title: "License"]
      ],
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      formatters: ["html"]
    ]
  end

  defp package do
    [
      name: "phoenix_kit_templates",
      maintainers: ["BeamLab EU"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end
end
