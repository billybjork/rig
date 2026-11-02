defmodule Tidy.CLI do
  @moduledoc """
  `tidy [report|prune] [section...] [report|prune [section...]]...`, in a
  project checkout with a `.tidy.json` (`Tidy.Config`). A mode word applies
  to the sections after it; one with none after it means every section.
  With no arguments, every section is reported. Each section prints a line
  per thing it found, and nothing when there is nothing to say.

  Sections: worktrees, branches, databases, processes, simulators.
  """

  alias Tidy.{Branches, Config, Databases, Landed, Processes, Simulators, Worktrees}

  @sections %{
    "worktrees" => Worktrees,
    "branches" => Branches,
    "databases" => Databases,
    "processes" => Processes,
    "simulators" => Simulators
  }
  @order ~w(worktrees branches databases processes simulators)

  def main(argv, dir \\ File.cwd!()) do
    with {:ok, plan} <- plan(argv),
         {:ok, config} <- Config.load(dir) do
      env = env(config)
      if Enum.any?(plan, fn {s, _} -> s in ~w(worktrees branches) end), do: fetch(env)

      for {section, mode} <- plan, line <- @sections[section].run(config, mode, env) do
        IO.puts(line)
      end

      0
    else
      {:usage, why} ->
        IO.puts(:stderr, "tidy: #{why}\n\n" <> usage())
        64

      {:error, why} ->
        IO.puts(:stderr, "tidy: #{why}")
        2
    end
  end

  @doc "The `{section, mode}` pairs `argv` asks for, in order."
  def plan(argv) do
    argv =
      if match?([m | _] when m in ["report", "prune"], argv), do: argv, else: ["report" | argv]

    argv
    |> Enum.reduce_while([], fn
      mode, groups when mode in ["report", "prune"] ->
        {:cont, [{String.to_atom(mode), []} | groups]}

      section, [{mode, sections} | groups] when is_map_key(@sections, section) ->
        {:cont, [{mode, [section | sections]} | groups]}

      other, _ ->
        {:halt, {:usage, "unknown argument #{inspect(other)}"}}
    end)
    |> case do
      {:usage, _} = usage ->
        usage

      groups ->
        pairs =
          for {mode, sections} <- Enum.reverse(groups),
              section <- if(sections == [], do: @order, else: Enum.reverse(sections)),
              do: {section, mode}

        {:ok, Enum.uniq_by(pairs, &elem(&1, 0))}
    end
  end

  def usage, do: @moduledoc

  defp env(config) do
    git = fn args -> Tidy.Cmd.run("git", args, cd: config.primary) end

    %{
      git: git,
      prs:
        if(config.landed == :merged_pr, do: Landed.gh(config.primary), else: fn _, _ -> nil end),
      suffix: &Databases.suffix/2,
      procs: &Processes.list/0,
      kill: &Processes.kill/1,
      simulators: &Simulators.list/0
    }
  end

  defp fetch(env), do: env.git.(["fetch", "--prune", "--quiet", "origin"])
end
