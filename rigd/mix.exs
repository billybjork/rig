defmodule Rigd.MixProject do
  use Mix.Project

  def project do
    [
      app: :rigd,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: [],
      releases: [rigd: [include_executables_for: [:unix]]],
      aliases: [
        check: [
          "compile --warnings-as-errors --force",
          "format --check-formatted",
          "test --warnings-as-errors"
        ]
      ]
    ]
  end

  def cli, do: [preferred_envs: [check: :test]]

  def application do
    [extra_applications: [:logger], mod: {Rigd.Application, []}]
  end
end
