defmodule Gate.Engine do
  @moduledoc """
  Runs parts on Sprites and judges them. Each part is staged (its tar:
  the Sprite-side job, its vars and argv, the git bundle that brings the
  Sprite to the commit) and launched detached (`Gate.Sprite.launch/4`),
  then polled every `limits.poll` seconds, one call at a time, each poll
  appending the log's new bytes to the part's log here.

  A part ends one of three ways:

    * it ran: its job wrote a status in the `run` phase, green on 0 and
      red otherwise, except a native crash (`crashed?/1`), which reruns;
    * its Sprite failed: the upload or launch failed, a phase outlasted its
      limit (it is then ended on the Sprite), the Sprite's life changed
      (it restarted), the job ended in setup or without a status, or no
      poll got through for `limits.unreachable` seconds. It reruns;
    * a restart during the `warm` phase relaunches it once on the same
      Sprite instead: a cold dialyzer PLT build runs the Sprite out of
      memory at about 15 min, and the retry finishes from what it left.

  A part reruns once, on a free Sprite: the spare while no part has taken
  it, then any Sprite whose own part has ended green or red (a Sprite that
  failed or crashed is never free again in this run). With none free it
  waits for one; when every other part has ended and none is free, it is
  `:sprite_failed`. A Sprite's memory loses a write now and then (Node's
  segfaults on soco's gate Sprites, 2026-10), so one bad Sprite costs a
  rerun, not the gate.

  A dropped keeper (the TTY session that keeps the Sprite awake) is
  relaunched while its job runs.
  """

  alias Gate.{Config, Sprite}

  defmodule Job do
    @moduledoc "A part: its name, its command, the caches it warms, and a working tree to lay over the commit (`gate run`)."
    defstruct [:name, :argv, warm: [], overlay: nil]
  end

  @enforce_keys [:config, :sha, :stamp, :run, :work]
  defstruct [
    :config,
    :sha,
    :stamp,
    :run,
    :work,
    :spare,
    stream: false,
    report: &__MODULE__.no_report/3,
    say: &__MODULE__.say/1
  ]

  def no_report(_part, _state, _message), do: :ok
  def say(line), do: IO.puts(:stderr, line)

  @doc """
  Runs each `{job, sprite}` at once and returns, in order, each part's
  `%{name, sprite, result, rc, secs, log, reran_from, why}`; `result` is
  `:green`, `:red`, `:sprite_failed` or, for `gate run`, `:overlay`.
  """
  def run(%__MODULE__{} = ctx, assigned) do
    File.mkdir_p!(ctx.config.logs)
    File.mkdir_p!(ctx.work)
    state = %{parts: %{}, free: List.wrap(ctx.spare), waiting: [], results: %{}}

    state =
      assigned
      |> Enum.with_index()
      |> Enum.reduce(state, fn {{job, sprite}, i}, state ->
        start(ctx, state, %{i: i, job: job, reran_from: nil}, sprite, "on #{sprite}")
      end)

    state = loop(ctx, state)
    for i <- 0..(length(assigned) - 1), do: state.results[i]
  end

  defp loop(ctx, state) do
    cond do
      map_size(state.parts) > 0 -> loop(ctx, poll_all(ctx, state))
      state.waiting != [] -> loop(ctx, give_up(ctx, state))
      true -> state
    end
  end

  defp poll_all(ctx, state) do
    Process.sleep(Config.limit_ms(ctx.config, "poll"))

    state.parts
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce(state, &poll(ctx, &2, &1))
  end

  # Every other part has ended and no Sprite is free: the waiting parts
  # have nowhere to rerun.
  defp give_up(ctx, %{waiting: waiting} = state) do
    Enum.reduce(waiting, %{state | waiting: []}, fn {part, rc, why}, state ->
      ctx.say.("#{part.job.name}: no Sprite was free to rerun it")
      done(ctx, state, part, :sprite_failed, rc, "#{why}; no Sprite was free to rerun it")
    end)
  end

  defp start(ctx, state, base, sprite, message) do
    %{job: job} = base
    id = "#{ctx.run}-#{job.name}-#{sprite}"
    log = Path.join(ctx.config.logs, "#{sprite}-#{ctx.run}-#{job.name}.log")
    File.write!(log, "")
    now = now()

    part =
      Map.merge(base, %{
        sprite: sprite,
        id: id,
        log: log,
        t0: now,
        offset: 0,
        life: nil,
        phase: "setup",
        phase_at: now,
        last_ok: now,
        warm_relaunched: false
      })

    ctx.report.(part, :working, message)

    with {:ok, tar} <- pack(ctx, part),
         :ok <- Sprite.stage(sprite, id, tar, ctx.config.limits["stage"]),
         {:ok, life} <- Sprite.launch(sprite, id, nil, ctx.config.limits["launch"]) do
      if file = System.get_env("GATE_PARTS_FILE"),
        do: File.write!(file, "#{sprite} #{id}\n", [:append])

      put_in(state.parts[part.i], %{part | life: life, last_ok: now()})
    else
      {:error, why} -> failed(ctx, state, part, why)
    end
  end

  # The part's tar: the Sprite-side job and keeper (and rig's image script
  # for a project that uses it), its vars and argv, the
  # bundle that brings this Sprite to the commit, and `gate run`'s overlay.
  defp pack(ctx, part) do
    dir = Path.join(ctx.work, part.id)
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    for file <- ["job.sh", "launch.sh"],
        do: File.cp!(Path.join(Sprite.root(), "sprite/#{file}"), Path.join(dir, file))

    if ctx.config.image, do: File.cp!(Gate.Stamp.image(), Path.join(dir, "image.sh"))

    File.write!(Path.join(dir, "vars"), vars(ctx, part.job))
    File.write!(Path.join(dir, "argv"), Enum.map(part.job.argv, &[&1, 0]))

    if overlay = part.job.overlay do
      for file <- ["tree.patch", "untracked.tar"],
          do: File.cp!(Path.join(overlay, file), Path.join(dir, file))
    end

    with :ok <- bundle(ctx, part.sprite, Path.join(dir, "in.bundle")) do
      tar = dir <> ".tar"

      case System.cmd("tar", ["--no-mac-metadata", "--no-xattrs", "-cf", tar, "-C", dir, "."],
             env: [{"COPYFILE_DISABLE", "1"}],
             stderr_to_stdout: true
           ) do
        {_, 0} -> {:ok, tar}
        {out, _} -> {:error, "packing the part failed: #{Sprite.last_line(out)}"}
      end
    end
  end

  defp vars(ctx, job) do
    c = ctx.config

    """
    NAME=#{q(c.name)} SHA=#{q(ctx.sha)} STAMP=#{q(ctx.stamp)} SETUP=#{q(c.setup)}
    KEEP=(#{qs(c.keep)})
    PROVISION=(#{qs(c.provision)})
    WARM_NAMES=(#{qs(Enum.map(job.warm, & &1.name))})
    WARM_KEYS=(#{qs(Enum.map(job.warm, & &1.key))})
    WARM_CMDS=(#{qs(Enum.map(job.warm, & &1.command))})
    """
  end

  defp q(value), do: "'" <> String.replace(to_string(value), "'", ~S('\'')) <> "'"
  defp qs(values), do: Enum.map_join(values, " ", &q/1)

  # Only the commits since the last tip the Sprite fetched when this
  # checkout has that commit (soco's whole history is about 300 MB), the
  # whole history otherwise, and nothing when the Sprite has the commit.
  defp bundle(ctx, sprite, path) do
    have = Sprite.tip(sprite, ctx.config.name)
    git = &System.cmd("git", &1, cd: ctx.config.top, stderr_to_stdout: true)

    args =
      cond do
        have == nil -> ["HEAD"]
        have == ctx.sha -> nil
        match?({_, 0}, git.(["merge-base", "--is-ancestor", "HEAD", have])) -> nil
        match?({_, 0}, git.(["cat-file", "-e", "#{have}^{commit}"])) -> ["HEAD", "--not", have]
        true -> ["HEAD"]
      end

    if args do
      case git.(["bundle", "create", "-q", path | args]) do
        {_, 0} -> :ok
        {out, _} -> {:error, "git bundle failed: #{Sprite.last_line(out)}"}
      end
    else
      File.write!(path, "")
    end
  end

  defp poll(ctx, state, i) do
    part = state.parts[i]
    limits = ctx.config.limits

    case Sprite.poll(part.sprite, part.id, part.offset, 30) do
      {:ok, :gone, _} ->
        failed(ctx, state, part, "the Sprite has no such part (restored or rebuilt?)")

      {:error, why} ->
        if now() - part.last_ok > limits["unreachable"] * 1000,
          do: failed(ctx, state, part, "unreachable for #{limits["unreachable"]} s: #{why}"),
          else: state

      {:ok, sprite_state, bytes} ->
        part = take_log(ctx, part, bytes, sprite_state["size"])
        judge(ctx, state, part, sprite_state)
    end
  end

  defp take_log(ctx, part, bytes, size) do
    File.write!(part.log, bytes, [:append])

    if ctx.stream do
      bytes
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(&1, "sprite-health:"))
      |> Enum.join("\n")
      |> IO.write()
    end

    %{part | offset: size, last_ok: now()}
  end

  defp judge(ctx, state, part, s) do
    phase = if s["phase"] in [nil, ""], do: part.phase, else: s["phase"]
    was_warm = part.phase == "warm" or phase == "warm"
    part = if phase != part.phase, do: %{part | phase: phase, phase_at: now()}, else: part
    limit = ctx.config.limits[phase] || ctx.config.limits["run"]

    cond do
      s["life"] not in [nil, "", part.life] and was_warm and not part.warm_relaunched ->
        note(
          part,
          "the Sprite restarted while warming (life #{part.life}, now #{s["life"]}); relaunching here"
        )

        ctx.say.("#{part.job.name}: #{part.sprite} restarted while warming; relaunching it there")
        relaunch(ctx, state, %{part | warm_relaunched: true})

      s["life"] not in [nil, "", part.life] ->
        failed(ctx, state, part, "it restarted mid-part (life #{part.life}, now #{s["life"]})")

      s["rc"] not in [nil, ""] ->
        ended(ctx, state, part, String.to_integer(s["rc"]))

      s["job"] == "down" ->
        failed(ctx, state, part, "the part ended without a status")

      now() - part.phase_at > limit * 1000 ->
        Sprite.kill(part.sprite, part.id)
        failed(ctx, state, part, "its #{phase} phase outlasted #{limit} s")

      s["keeper"] == "down" ->
        case Sprite.launch(part.sprite, part.id, "keep", ctx.config.limits["launch"]) do
          {:ok, _} -> note(part, "its keeper had gone; relaunched it")
          {:error, why} -> note(part, "its keeper had gone and would not relaunch: #{why}")
        end

        put_in(state.parts[part.i], part)

      true ->
        put_in(state.parts[part.i], part)
    end
  end

  defp relaunch(ctx, state, part) do
    case Sprite.launch(part.sprite, part.id, nil, ctx.config.limits["launch"]) do
      {:ok, life} ->
        put_in(state.parts[part.i], %{part | life: life, phase: "setup", phase_at: now()})

      {:error, why} ->
        failed(ctx, state, part, why)
    end
  end

  defp ended(ctx, state, part, rc) do
    cond do
      part.phase != "run" and rc == 125 and File.read!(part.log) =~ "cannot overlay" ->
        done(ctx, state, part, :overlay, rc, "the working tree would not lay over the commit")

      part.phase != "run" ->
        failed(ctx, state, part, "exit #{rc} in #{part.phase}: #{last_log_line(part)}")

      rc != 0 and crashed?(part.log) and part.reran_from == nil ->
        ctx.say.("#{part.job.name}: a process crashed on #{part.sprite} (log #{part.log})")
        rerun(ctx, state, part, rc, "a native crash, not a gate result")

      rc != 0 and crashed?(part.log) ->
        ctx.say.(
          "#{part.job.name}: a process crashed on #{part.sprite}, its rerun (log #{part.log})"
        )

        done(ctx, state, part, :sprite_failed, rc, "a process crashed, on its rerun too")

      true ->
        result = if rc == 0, do: :green, else: :red
        ctx.say.("#{part.job.name} #{result} in #{secs(part)} s on #{part.sprite}")
        state = done(ctx, state, part, result, rc, nil)
        free(ctx, %{state | free: state.free ++ [part.sprite]})
    end
  end

  defp failed(ctx, state, part, why) do
    note(part, "#{part.sprite} failed: #{why}")

    if part.reran_from == nil do
      ctx.say.("#{part.job.name}: #{part.sprite} failed (#{why})")
      rerun(ctx, state, part, nil, "#{part.sprite} failed")
    else
      ctx.say.("#{part.job.name}: #{part.sprite} failed: #{why}")
      done(ctx, state, part, :sprite_failed, nil, why)
    end
  end

  # A part to rerun leaves the running ones and waits for a free Sprite.
  defp rerun(ctx, state, part, rc, why) do
    state = %{
      state
      | parts: Map.delete(state.parts, part.i),
        waiting: state.waiting ++ [{part, rc, why}]
    }

    free(ctx, state)
  end

  # Starts each waiting part on a free Sprite, in turn.
  defp free(ctx, %{waiting: [{part, _rc, why} | waiting], free: [sprite | free]} = state) do
    note(part, "#{why}; reran on #{sprite}")
    ctx.say.("#{part.job.name}: rerunning on #{sprite}")
    state = %{state | waiting: waiting, free: free}

    ctx
    |> start(
      state,
      %{i: part.i, job: part.job, reran_from: part.sprite},
      sprite,
      "#{why}; rerunning on #{sprite}"
    )
    |> then(&free(ctx, &1))
  end

  defp free(_ctx, state), do: state

  defp done(ctx, state, part, result, rc, why) do
    secs = secs(part)

    message =
      case result do
        :green -> "green in #{secs} s on #{part.sprite}"
        :red -> "red in #{secs} s on #{part.sprite}"
        _ -> "#{why} (#{part.sprite}, after #{secs} s)"
      end

    ctx.report.(part, if(result == :green, do: :done, else: :error), message)

    entry = %{
      name: part.job.name,
      sprite: part.sprite,
      result: result,
      rc: rc,
      secs: secs,
      log: part.log,
      reran_from: part.reran_from,
      why: why
    }

    %{
      state
      | parts: Map.delete(state.parts, part.i),
        results: Map.put(state.results, part.i, entry)
    }
  end

  defp note(part, line), do: File.write!(part.log, "gate: #{line}\n", [:append])

  defp last_log_line(part), do: part.log |> File.read!() |> Sprite.last_line()

  defp secs(part), do: div(now() - part.t0, 1000)

  defp now, do: System.monotonic_time(:millisecond)

  @doc """
  Whether a red part's log shows a native crash: a process killed by
  SIGSEGV, SIGBUS or SIGILL (bash's report, or a mix cmd exit of 139, 135
  or 132), a vitest worker dying outright (tinypool reports it as the
  worker exiting, or as a write EPIPE when the runner next sends to it),
  or an I/O error reading a file. These leave the gate incomplete; they do
  not say whether the host, the runtime or native code is at fault.
  """
  def crashed?(log) do
    File.read!(log) =~
      ~r/Segmentation fault|Bus error|Illegal instruction|^\*\* \(exit\) (139|135|132)$|Error: Worker exited unexpectedly|ProcessWorker\.send node_modules\/tinypool|Input\/output error/m
  end
end
