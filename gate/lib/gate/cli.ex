defmodule Gate.CLI do
  @moduledoc "`bin/gate`'s commands, run in the project checkout `$GATE_CWD`."

  def main(args) do
    top = System.get_env("GATE_CWD") || File.cwd!()

    status =
      try do
        config = Gate.Config.load(top)

        case args do
          ["check" | rest] ->
            Gate.Check.main(config, rest)

          ["run" | rest] ->
            Gate.Run.main(config, rest)

          ["pool" | rest] ->
            Gate.Pool.main(config, rest)

          ["times"] ->
            Gate.Times.main(config, [])

          ["stamp"] ->
            IO.puts(Gate.Stamp.stamp(config, Gate.Check.git!(config, ["rev-parse", "HEAD"]))) && 0

          ["stamp", rev] ->
            sha = Gate.Check.git!(config, ["rev-parse", "#{rev}^{commit}"])
            IO.puts(Gate.Stamp.stamp(Gate.Config.load(top, sha), sha)) && 0

          ["golden", sprite] ->
            Gate.Golden.main(config, sprite)

          _ ->
            raise Gate.Error,
                  "usage: gate check [tier] | run <cmd...> | pool ... | golden <sprite> | times | stamp [rev]"
        end
      rescue
        e in Gate.Error ->
          IO.puts(:stderr, "gate: #{e.message}")
          2
      end

    System.halt(status)
  end
end
