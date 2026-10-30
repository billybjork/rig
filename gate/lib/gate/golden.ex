defmodule Gate.Golden do
  @moduledoc """
  `gate golden <sprite>`: the setup rigd's `Fleet` runs on a shared-pool
  Sprite it has leased to itself, before it checkpoints it as golden
  (`gate/FLEET.md`). It sets the Sprite up and runs no part: the tools
  (rig's image, the project's pins), the project's setup (deps), then each
  warm cache (soco's dialyzer PLT), one short step at a time. Ship gates
  are the verification, so a red `main` keeps no Sprite out of the pool
  (soco's Hex advisory did, 2026-10-30), and a golden no longer runs the
  25-minute suite where Sprites restart (Amp's Orbs build their snapshots
  the same way: setup and warm caches, never the tests).

  A step whose Sprite failed it (a restart, mostly) runs again on the same
  Sprite, up to three times: the disk survives a restart, so it resumes from
  what the last try left. A warm cache with a seed on the laptop
  (`Gate.Engine.seed/2`) starts from it whenever its key is not the one
  built there: a cold soco PLT took the Sprite down mid-build on every try
  for a day (2026-10-30). A warm step is green when the cache's key is
  written; one that stays red (its build fails on `main`) passes, its
  cache left to the parts that need it.

  Prints HEAD's stamp on stdout when every step came to a verdict. Exit 0
  then, 2 when the Sprite failed a step every try. It takes no lock: the
  Sprite is `Fleet`'s while this runs.
  """

  alias Gate.{Check, Engine, Stamp}

  @tries 3

  def main(config, sprite) do
    sha = Check.git!(config, ["rev-parse", "HEAD"])
    stamp = Stamp.stamp(config, sha)
    run = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S") <> "-" <> Check.short(sha)

    work =
      Path.join(System.tmp_dir!(), "gate-golden-#{run}-#{System.unique_integer([:positive])}")

    ctx = %Engine{
      config: config,
      sha: sha,
      stamp: stamp,
      run: run,
      work: work,
      seed: true,
      say: &say/1
    }

    say("#{sprite}: #{config.name} #{Check.short(sha)}, stamp #{stamp}")

    result =
      config
      |> steps(sha, stamp)
      |> Enum.reduce_while(:green, fn job, :green ->
        case attempt(ctx, job, sprite, 1) do
          :sprite_failed -> {:halt, :sprite_failed}
          _ -> {:cont, :green}
        end
      end)

    File.rm_rf(work)

    case result do
      :green ->
        IO.puts(stamp)
        0

      :sprite_failed ->
        2
    end
  end

  # The setup (tools, checkout, the project's setup script), then a step
  # per warm cache whose command checks that its key was written.
  defp steps(config, sha, stamp) do
    setup = %Engine.Job{name: "setup", argv: ["true"]}

    warms =
      for warm <- config.warm do
        key = Stamp.warm_key(config, sha, stamp, warm)

        %Engine.Job{
          name: "warm-#{warm["name"]}",
          argv: [
            "bash",
            "-c",
            ~S|test "$(cat ~/.gate-warm/"$0" 2>/dev/null)" = "$1"|,
            "#{config.name}-#{warm["name"]}",
            key
          ],
          warm: [%{name: warm["name"], key: key, command: warm["command"]}]
        }
      end

    [setup | warms]
  end

  defp attempt(ctx, job, sprite, try) do
    [r] = Engine.run(%{ctx | run: "#{ctx.run}-#{try}"}, [{job, sprite}])
    say("#{job.name}: #{r.result} in #{r.secs} s#{if r.why, do: " (#{r.why})"}; log #{r.log}")

    cond do
      r.result == :green -> :green
      try < @tries and r.result in [:sprite_failed, :red] -> attempt(ctx, job, sprite, try + 1)
      true -> r.result
    end
  end

  defp say(line), do: IO.puts(:stderr, "gate-golden: #{line}")
end
