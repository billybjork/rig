defmodule Tidy.MixProject do
  use Mix.Project

  def project do
    [
      app: :tidy,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: [],
      aliases: [
        # The whole gate (`bin/tidy self-check`).
        check: [
          "compile --warnings-as-errors --force",
          "format --check-formatted",
          "test --warnings-as-errors"
        ]
      ]
    ]
  end

  def cli, do: [preferred_envs: [check: :test]]

  def application, do: [extra_applications: [:logger]]
end
