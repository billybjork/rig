defmodule Gate.Pool do
  @moduledoc """
  `gate pool`: the project's gate Sprites.

      gate pool status                each Sprite's stamp and gate checkpoint
      gate pool provision <sprite>    create if missing, build, gate, checkpoint
      gate pool rebuild <sprite>      destroy, then provision from nothing
      gate pool exec <sprite> <cmd>   run a command on HEAD there
      gate pool warm [sprite...]      build HEAD's warm caches (all: the pool)

  A Sprite is ready when its provision stamp matches HEAD's and it has a
  checkpoint taken after its `provision_gate` passed under that stamp, so
  a broken Sprite restores in about 30 s (`sprite checkpoint restore <id>
  -s <name>`). Provision is idempotent: a ready Sprite stays as it is. The
  laptop's `sprite` login is the only credential; a Sprite never gets a
  secret, and the code goes in as a git bundle.
  """

  alias Gate.{Check, Engine, Sprite, Stamp}

  def main(%{pool: "fleet"}, _args),
    do:
      raise(
        Gate.Error,
        "this project gates on the shared pool, which rigd's Fleet keeps (bin/rigd fleet; rig's gate/FLEET.md)"
      )

  def main(config, ["status"]), do: status(config)
  def main(config, []), do: status(config)

  def main(config, ["provision", sprite]), do: provision(config, in_pool!(config, sprite))

  def main(config, ["rebuild", sprite]) do
    in_pool!(config, sprite)

    if Sprite.exists?(sprite) do
      say("#{sprite}: destroying")
      {_, 0} = Sprite.call(["destroy", "--force", "-s", sprite], 300)
    end

    provision(config, sprite)
  end

  def main(config, ["exec", sprite | argv]) when argv != [] do
    in_pool!(config, sprite)
    r = run_one(config, sprite, Enum.join(argv, " "), argv, [], true)
    if r.result == :sprite_failed, do: 125, else: r.rc
  end

  def main(config, ["warm" | sprites]) do
    sprites = if sprites == [], do: config.pool, else: Enum.map(sprites, &in_pool!(config, &1))
    {sha, stamp, ctx} = context(config, false)
    warm = all_warms(config, sha, stamp)
    jobs = for s <- sprites, do: {%Engine.Job{name: "warm", argv: ["true"], warm: warm}, s}
    results = Engine.run(ctx, jobs)
    File.rm_rf(ctx.work)

    for r <- results,
        do: say("#{r.sprite}: #{if r.result == :green, do: "warm", else: "failed: #{r.why}"}")

    if Enum.all?(results, &(&1.result == :green)), do: 0, else: 1
  end

  def main(_config, _args),
    do:
      raise(
        Gate.Error,
        "usage: gate pool status|provision <sprite>|rebuild <sprite>|exec <sprite> <cmd...>|warm [sprite...]"
      )

  defp status(config) do
    sha = Check.git!(config, ["rev-parse", "HEAD"])
    want = Stamp.stamp(config, sha)
    say("HEAD's stamp: #{want}")

    for s <- config.pool do
      line =
        cond do
          not Sprite.exists?(s) ->
            "missing (gate pool provision #{s})"

          (have = stamp_of(config, s)) != want ->
            "stale stamp #{have} (its next part refreshes it; gate pool provision #{s} checkpoints it)"

          cp = checkpoint(s, want) ->
            "ready, checkpoint #{cp}"

          true ->
            "stamped, no gate checkpoint (gate pool provision #{s})"
        end

      IO.puts("#{s}  #{line}")
    end

    0
  end

  defp provision(config, sprite) do
    sha = Check.git!(config, ["rev-parse", "HEAD"])
    want = Stamp.stamp(config, sha)

    unless Sprite.exists?(sprite) do
      say("#{sprite}: creating")
      {_, 0} = Sprite.create(sprite)
    end

    if cp = stamp_of(config, sprite) == want && checkpoint(sprite, want) do
      say("#{sprite}: ready (stamp #{want}, checkpoint #{cp})")
      0
    else
      warm = all_warms(config, sha, want)

      # The first command builds the warm caches (a cold PLT alone, as a
      # Sprite has about 8 GB) and refreshes the tools; each must pass.
      green =
        config.provision_gate
        |> Enum.with_index()
        |> Enum.all?(fn {command, i} ->
          r =
            run_one(
              config,
              sprite,
              command,
              String.split(command),
              if(i == 0, do: warm, else: []),
              false
            )

          r.result == :green
        end)

      if green do
        comment = "green gate #{Check.short(sha)} stamp #{want}"
        {_, 0} = Sprite.call(["checkpoint", "create", "-s", sprite, "-comment", comment], 600)
        say("#{sprite}: ready (stamp #{want}, checkpoint #{checkpoint(sprite, want)})")
        0
      else
        say("#{sprite}: not checkpointed; a provision gate failed")
        1
      end
    end
  end

  # One command on one Sprite, its log's tail printed when it is not green.
  defp run_one(config, sprite, label, argv, warm, stream) do
    {_sha, _stamp, ctx} = context(config, stream)
    say("#{sprite}: #{label}")
    [r] = Engine.run(ctx, [{%Engine.Job{name: "exec", argv: argv, warm: warm}, sprite}])
    File.rm_rf(ctx.work)

    if r.result != :green and not stream do
      r.log
      |> File.read!()
      |> String.split("\n")
      |> Enum.take(-30)
      |> Enum.each(&IO.puts(:stderr, &1))
    end

    say("#{sprite}: #{r.result} in #{r.secs} s (exit #{r.rc || "none"}); log #{r.log}")
    r
  end

  defp context(config, stream) do
    sha = Check.git!(config, ["rev-parse", "HEAD"])
    stamp = Stamp.stamp(config, sha)
    run = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S") <> "-" <> Check.short(sha)
    work = Path.join(System.tmp_dir!(), "gate-pool-#{run}-#{System.unique_integer([:positive])}")

    {sha, stamp,
     %Engine{
       config: config,
       sha: sha,
       stamp: stamp,
       run: run,
       work: work,
       stream: stream,
       say: &say/1
     }}
  end

  defp all_warms(config, sha, stamp) do
    for warm <- config.warm,
        do: %{
          name: warm["name"],
          key: Stamp.warm_key(config, sha, stamp, warm),
          command: warm["command"]
        }
  end

  defp stamp_of(config, sprite) do
    case Sprite.call(
           ["-s", sprite, "exec", "--", "bash", "-c", ~S|cat ~/"$1-stamp"|, "stamp", config.name],
           60
         ) do
      {out, 0} -> String.trim(out)
      _ -> "none"
    end
  end

  # The newest checkpoint taken after a green provision gate under `stamp`.
  defp checkpoint(sprite, stamp) do
    case Sprite.call(["checkpoint", "list", "-s", sprite], 60) do
      {out, 0} ->
        out
        |> String.split("\n")
        |> Enum.find_value(fn line ->
          if String.contains?(line, "stamp #{stamp}"), do: line |> String.split() |> List.first()
        end)

      _ ->
        nil
    end
  end

  defp in_pool!(config, sprite) do
    if sprite in config.pool,
      do: sprite,
      else: raise(Gate.Error, "#{sprite} is not a gate Sprite (#{Enum.join(config.pool, " ")})")
  end

  defp say(line), do: IO.puts(:stderr, "gate-pool: #{line}")
end
