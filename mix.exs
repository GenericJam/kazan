defmodule Kazan.Mixfile do
  use Mix.Project

  def project do
    [
      app: :kazan,
      version: "0.11.0",
      elixir: "~> 1.4",
      elixirc_paths: elixirc_paths(Mix.env()),
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Hex.pm stuff
      package: package(),
      description: description(),

      # Docs
      name: "Kazan",
      source_url: "https://github.com/obmarg/kazan",
      homepage_url: "https://github.com/obmarg/kazan",
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"]]
    ]
  end

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    [applications: [:logger]]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Dependencies can be Hex packages:
  #
  #   {:mydep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:mydep, git: "https://github.com/elixir-lang/mydep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options
  defp deps do
    [
      # {:poison, "~> 2.0 or ~> 3.0 or ~> 4.0"},
      # # Earlier versions of httpoison will cause a process leak when using watchers
      # {:httpoison, ">= 1.6.1"},
      {:yaml_elixir, "~> 2.11"},

      # Dev dependencies
      {:ex_doc, "~> 0.14", only: :dev},

      # Test dependencies
      {:plug_cowboy, "~> 2.0", only: :test},
      {:bypass, "~> 2.1", only: :test},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"}
    ]
  end

  defp package do
    [
      name: :kazan,
      licenses: ["MIT"],
      maintainers: ["Graeme Coupar"],
      links: %{"GitHub" => "https://github.com/obmarg/kazan"},
      files: ["lib", "priv", "mix.exs", "README*", "LICENSE*", "kube_specs"]
    ]
  end

  def description do
    "Kubernetes API client for Elixir"
  end
end
