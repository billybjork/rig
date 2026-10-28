defmodule Gate.Run do
  @moduledoc """
  `gate run <command...>`: the command on a dev Sprite (`$GATE_DEV_SPRITE`,
  else the project's first), on HEAD with the working tree's changes laid
  over it: the diff against HEAD, staged or not, and the untracked files
  Git does not ignore. gitleaks scans those first, and no secret goes
  aboard. The Sprite is readied as a gate's is, and created on first use.

  Its output streams here and goes to `<logs>/sprite-run-*.log`. The exit
  status is the command's, or 125 when the command could not run there:
  the Sprite failed, the working tree would not lay over the commit, the
  scan found a possible secret, or `$SPRITE_RUN_TIMEOUT` seconds (3600)
  passed. The last line says which. Rex shows it as the record
  `sprite-run`.
  """

  alias Gate.{Check, Engine, Stamp, Status}

  def main(_config, []), do: raise(Gate.Error, "usage: gate run <command...>")

  def main(config, argv) do
    sprite = dev_sprite(config)
    command = Enum.join(argv, " ")
    say = &IO.puts(:stderr, "sprite-run: #{&1}")
    t0 = System.monotonic_time(:second)

    cant_run = fn why ->
      say.("#{why} (exit 125, not the command's result)")
      Status.report(:error, "sprite-run", why, command)
      125
    end

    Status.report(:working, "sprite-run", "preparing #{sprite}", command)
    sha = Check.git!(config, ["rev-parse", "HEAD"])
    run = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S") <> "-" <> Check.short(sha)
    work = Path.join(System.tmp_dir!(), "gate-run-#{run}-#{System.unique_integer([:positive])}")
    overlay = Path.join(work, "overlay")

    try do
      with :ok <- ensure(sprite),
           {:ok, changed} <- overlay(config, overlay),
           :ok <- scan(overlay) do
        say.("#{command} on #{sprite}: #{Check.short(sha)} with #{changed} uncommitted path(s)")
        limit = String.to_integer(System.get_env("SPRITE_RUN_TIMEOUT", "3600"))
        config = %{config | limits: Map.put(config.limits, "run", limit)}

        ctx = %Engine{
          config: config,
          sha: sha,
          stamp: Stamp.stamp(config, sha),
          run: run,
          work: work,
          stream: true,
          say: &IO.puts(:stderr, &1),
          report: fn _part, state, message ->
            Status.report(state, "sprite-run", message, command)
          end
        }

        job = %Engine.Job{name: "sprite-run", argv: argv, overlay: overlay}
        [r] = Engine.run(ctx, [{job, sprite}])
        log = Path.join(config.logs, "sprite-run-#{Path.basename(r.log)}")
        File.rename!(r.log, log)
        secs = System.monotonic_time(:second) - t0

        case r.result do
          :overlay ->
            cant_run.(
              "the working tree could not be laid over #{Check.short(sha)} on #{sprite}; log #{log}"
            )

          :sprite_failed ->
            cant_run.("#{sprite} failed after #{secs} s: #{r.why}; log #{log}")

          _ ->
            say.("exit #{r.rc} in #{secs} s on #{sprite}#{if r.rc != 0, do: "; log #{log}"}")
            r.rc
        end
      else
        {:error, why} -> cant_run.(why)
      end
    after
      File.rm_rf(work)
    end
  end

  def dev_sprite(config) do
    System.get_env("GATE_DEV_SPRITE") || List.first(config.dev) ||
      raise Gate.Error, ".gate.json names no dev Sprite"
  end

  defp ensure(sprite) do
    if Gate.Sprite.exists?(sprite) do
      :ok
    else
      IO.puts(:stderr, "sprite-run: #{sprite}: creating")

      case Gate.Sprite.create(sprite) do
        {_, 0} -> :ok
        {out, _} -> {:error, "#{sprite} could not be created: #{Gate.Sprite.last_line(out)}"}
      end
    end
  end

  # tree.patch (`git diff --binary HEAD`) and untracked.tar (the untracked
  # files Git does not ignore), and how many paths they change.
  defp overlay(config, dir) do
    File.mkdir_p!(dir)
    patch = Path.join(dir, "tree.patch")
    tar = Path.join(dir, "untracked.tar")

    script = """
    git diff --binary HEAD >"$1" &&
      git ls-files -z --others --exclude-standard |
      COPYFILE_DISABLE=1 tar --null -T - --no-mac-metadata --no-xattrs -cf "$2" &&
      echo $(($(git diff --name-only HEAD | wc -l) + $(tar -tf "$2" | wc -l)))
    """

    case System.cmd("bash", ["-c", script, "overlay", patch, tar],
           cd: config.top,
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, out |> String.trim() |> String.to_integer()}
      {out, _} -> {:error, "the working tree could not be packed: #{Gate.Sprite.last_line(out)}"}
    end
  end

  defp scan(overlay) do
    if System.find_executable("gitleaks") do
      scan = Path.join(Path.dirname(overlay), "scan")
      File.mkdir_p!(scan)
      File.cp!(Path.join(overlay, "tree.patch"), Path.join(scan, "tree.patch"))
      System.cmd("tar", ["-xf", Path.join(overlay, "untracked.tar"), "-C", scan])

      case System.cmd("gitleaks", ["dir", scan, "--no-banner", "--redact"],
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          :ok

        {out, _} ->
          IO.write(:stderr, out)

          {:error,
           "gitleaks found a possible secret in the uncommitted changes; move it to Bitwarden"}
      end
    else
      IO.puts(
        :stderr,
        "sprite-run: gitleaks not installed; the uncommitted changes go unscanned (brew install gitleaks)"
      )

      :ok
    end
  end
end
