defmodule Gate.Golden do
  @moduledoc """
  `gate golden <sprite>`: the provision gate rigd's `Fleet` runs on a
  shared-pool Sprite it has leased to itself, before it checkpoints it as
  golden (`gate/FLEET.md`). The project's parts for the tier `check` run
  one after another on that Sprite, each with its warm caches, rather than
  as one long command: long provision gates are where Sprites restart (9 of
  15 lost their Sprite 7 to 26 min in, 2026-10-29). A part whose Sprite
  failed it runs there once more.

  Prints HEAD's stamp on stdout when every part is green. Exit 0 green, 1
  a red part, 2 the Sprite failed a part twice. It takes no lock: the
  Sprite is `Fleet`'s while this runs.
  """

  alias Gate.{Check, Engine, Stamp}

  def main(config, sprite) do
    sha = Check.git!(config, ["rev-parse", "HEAD"])
    stamp = Stamp.stamp(config, sha)
    run = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S") <> "-" <> Check.short(sha)

    work =
      Path.join(System.tmp_dir!(), "gate-golden-#{run}-#{System.unique_integer([:positive])}")

    ctx = %Engine{config: config, sha: sha, stamp: stamp, run: run, work: work, say: &say/1}
    say("#{sprite}: #{config.name} #{Check.short(sha)}, stamp #{stamp}")

    result =
      config
      |> Check.parts("check")
      |> Enum.reduce_while(:green, fn {name, command}, :green ->
        job = %Engine.Job{
          name: name,
          argv: String.split(command),
          warm: Check.warms(config, sha, stamp, name)
        }

        case attempt(ctx, job, sprite, 1) do
          :green -> {:cont, :green}
          other -> {:halt, other}
        end
      end)

    File.rm_rf(work)

    case result do
      :green ->
        IO.puts(stamp)
        0

      :red ->
        1

      :sprite_failed ->
        2
    end
  end

  defp attempt(ctx, job, sprite, try) do
    [r] = Engine.run(%{ctx | run: "#{ctx.run}-#{try}"}, [{job, sprite}])
    say("#{job.name}: #{r.result} in #{r.secs} s#{if r.why, do: " (#{r.why})"}; log #{r.log}")

    if r.result == :sprite_failed and try == 1,
      do: attempt(ctx, job, sprite, 2),
      else: r.result
  end

  defp say(line), do: IO.puts(:stderr, "gate-golden: #{line}")
end
