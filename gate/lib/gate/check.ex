defmodule Gate.Check do
  @moduledoc """
  `gate check [tier]`: the split gate on HEAD. Its parts (the project's
  `parts` command) run at once, one Sprite each from the pool, and the
  pool's last Sprite is the spare (`Gate.Engine` says when a part reruns,
  there or on a Sprite whose own part has ended). On the shared pool
  (`"pool": "fleet"`), each part runs on a Sprite leased from rigd's
  `Fleet` as one frees, and reruns on the next. The gate is green when
  every part is.

  The contract the ship worker reads (rig's shipyard/README.md, "A
  project"): exit 0 green, 1 red with a digest of 30 lines or fewer on
  stdout, 2 no verdict (a part's Sprite failed and no Sprite could rerun
  it); one row per run in `<logs>/check-remote.tsv`: when, sha,
  tier, verdict, wall seconds, then each part as
  `name:seconds:sprite:result`, with `:reran-from-<sprite>` on a part that
  reran. Progress goes to stderr, and each part reports to
  Rex's program status as `${SHIPYARD_STATUS_ID:-gate}/<part>`.
  """

  alias Gate.{Config, Digest, Engine, Stamp, Status}

  @digest_lines 30

  def main(config, args) do
    tier = List.first(args) || "check"
    sha = git!(config, ["rev-parse", "HEAD"])
    say = &IO.puts(:stderr, "check-remote: #{&1}")

    if git!(config, ["status", "--porcelain", "--untracked-files=no"]) != "",
      do: say.("the tree has uncommitted changes; the gate runs on the commit, #{short(sha)}")

    parts = parts(config, tier)
    n = length(parts)
    pool = config.pool
    fleet = pool == "fleet"

    if n == 0, do: raise(Gate.Error, "the parts command named no part for #{tier}")
    if fleet, do: Gate.Lease.check!()

    if not fleet and n >= length(pool),
      do:
        raise(
          Gate.Error,
          "#{n} parts need #{n + 1} Sprites with the spare; the pool has #{length(pool)}"
        )

    stamp = Stamp.stamp(config, sha)
    spare = if not fleet, do: List.last(pool)
    run = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S") <> "-" <> short(sha)
    root = System.get_env("SHIPYARD_STATUS_ID", "gate")
    work = Path.join(System.tmp_dir!(), "gate-#{run}-#{System.unique_integer([:positive])}")

    ctx = %Engine{
      config: config,
      sha: sha,
      stamp: stamp,
      run: run,
      work: work,
      spare: spare,
      say: say,
      report: fn part, state, message ->
        Status.report(state, "#{root}/#{part.job.name}", message, part.job.name)
      end
    }

    subject = git!(config, ["log", "-1", "--format=%s", "HEAD"])
    used = if fleet, do: List.duplicate(:lease, n), else: Enum.take(pool, n)

    say.(
      "#{short(sha)} (#{subject}): #{tier} as #{n} parts " <>
        if(fleet,
          do: "on the shared pool",
          else: "on #{Enum.join(used, " ")}, spare #{spare}"
        )
    )

    jobs =
      for {{name, command}, sprite} <- Enum.zip(parts, used) do
        {%Engine.Job{
           name: name,
           argv: String.split(command),
           warm: warms(config, sha, stamp, name)
         }, sprite}
      end

    t0 = System.monotonic_time(:second)
    results = Engine.run(ctx, jobs)
    File.rm_rf(work)
    wall = System.monotonic_time(:second) - t0

    verdict =
      cond do
        Enum.any?(results, &(&1.result == :red)) -> "red"
        Enum.any?(results, &(&1.result == :sprite_failed)) -> "none"
        true -> "green"
      end

    row =
      Enum.join(
        [
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          sha,
          tier,
          verdict,
          wall
        ] ++
          Enum.map(results, &row_part/1),
        "\t"
      )

    File.write!(Path.join(config.logs, "check-remote.tsv"), row <> "\n", [:append])

    reds = Enum.filter(results, &(&1.result == :red))

    if reds != [] do
      per = div(@digest_lines - length(reds), length(reds))

      for r <- reds do
        IO.puts("== #{r.name} on #{r.sprite} (exit #{r.rc}): #{r.log}")
        Enum.each(Digest.lines(r.log, per), &IO.puts/1)
      end
    end

    spent =
      case for(r <- results, r.reran_from, do: "#{r.name} on #{r.sprite}") do
        [] -> ""
        reruns -> " (reran #{Enum.join(reruns, ", ")})"
      end

    case verdict do
      "green" ->
        say.("green in #{wall} s#{spent}")
        0

      "red" ->
        say.("red in #{wall} s#{spent}; full logs: #{config.logs}/*-#{run}-*.log")
        1

      "none" ->
        say.(
          "no verdict after #{wall} s: a part's Sprite failed and no Sprite could rerun it (gate pool status)"
        )

        2
    end
  end

  defp row_part(r) do
    result = if r.result == :sprite_failed, do: "sprite-failed", else: to_string(r.result)
    reran = if r.reran_from, do: ":reran-from-#{r.reran_from}", else: ""
    "#{r.name}:#{r.secs}:#{r.sprite}:#{result}#{reran}"
  end

  @doc "The project's parts for `tier`, `[{name, command}]`."
  def parts(%Config{parts: [cmd | args]} = config, tier) do
    case System.cmd(cmd, args ++ [tier], cd: config.top, stderr_to_stdout: true) do
      {out, 0} ->
        for line <- String.split(out, "\n", trim: true),
            [name, command] <- [String.split(line, "\t", parts: 2)],
            do: {name, command}

      {out, status} ->
        raise Gate.Error, "the parts command exited #{status}: #{Gate.Sprite.last_line(out)}"
    end
  end

  @doc "The warm caches part `name` needs, with their keys at `sha`."
  def warms(config, sha, stamp, name) do
    for warm <- config.warm, Enum.any?(warm["parts"], &glob?(&1, name)) do
      %{
        name: warm["name"],
        key: Stamp.warm_key(config, sha, stamp, warm),
        command: warm["command"]
      }
    end
  end

  defp glob?(pattern, name) do
    regex = pattern |> Regex.escape() |> String.replace("\\*", ".*")
    name =~ Regex.compile!("\\A#{regex}\\z")
  end

  def git!(config, args) do
    case System.cmd("git", args, cd: config.top, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, _} -> raise Gate.Error, "git #{Enum.join(args, " ")}: #{String.trim(out)}"
    end
  end

  def short(sha), do: String.slice(sha, 0, 8)
end
