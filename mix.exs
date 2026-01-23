defmodule Chosen.MixProject do
  use Mix.Project

  def project do
    [
      app: :chosen,
      version: "0.1.1",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      start_permanent: Mix.env() == :prod,
      docs: docs(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:postgrex, "~> 0.18.0 or ~> 0.19.0 or ~> 0.20.0 or ~> 0.21.0"},

      ## DEV / TEST
      {:ecto_sql, "~> 3.0", optional: true},
      {:ecto, "~> 3.0", optional: true},
      {:ex_doc, "~> 0.25", only: :dev, runtime: false}
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp docs() do
    [main: "Chosen"]
  end

  defp package() do
    [
      description:
        "Distributed singleton supervisor backed by PostgreSQL advisory locks. Ensures a process runs exactly once across your entire cluster—no BEAM clustering required.",
      licenses: ["MIT"],
      maintainers: ["Roman Heinrich"],
      links: %{
        "GitHub" => "https://github.com/mindreframer/chosen",
        "Changelog" => "https://github.com/mindreframer/chosen/blob/main/CHANGELOG.md"
      },
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end
end
