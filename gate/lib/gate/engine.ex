defmodule Gate.Engine do
  @moduledoc """
  Runs parts on exe.dev VMs (`Gate.Exe`) and judges them. Each part is
  staged (its tar: the host-side job, its vars and argv, the git bundle
  that brings the VM to the commit) and launched detached, then polled
  every `limits.poll` seconds, one call at a time, each poll appending the
  log's new bytes to the part's log here.

  A gate's or a run's part (a job assigned `:lease`) waits for a VM leased
  from rigd's `Fleet` (`Gate.Lease`), a fresh copy of the golden, and gives
  it back as it ends, saying how: `green`, `red`, `restarted` (its VM
  restarted or went unreachable, or the upload outlasted its limit),
  `failed` (the VM failed it otherwise) or `crashed`. `Fleet` going
  mid-gate leaves no verdict. `gate golden` names its VM instead.

  A part ends one of three ways:

    * it ran: its job wrote a status in the `run` phase, green on 0 and
      red otherwise, except a native crash (`crashed?/1`), which reruns;
    * its VM failed: the upload or launch failed, a phase outlasted its
      limit (it is then ended on the VM), the VM's life changed (it
      restarted), the job ended in setup or without a status, or no poll
      got through for `limits.unreachable` seconds. It reruns once, on the
      next VM `Fleet` leases; failing there too, it is `:vm_failed`.
      A named VM's part (`gate golden`) does not rerun: it is
      `:vm_failed` at once, and the golden tries the step again;
    * a restart during the `warm` phase relaunches it once on the same VM
      instead, where the cache was half built.

  A part whose VM restarted is relaunched there once, where its caches
  are warm: restarts are platform events, so another VM is no safer
  (Billy, 2026-10-30). A second restart reruns it.
  """

  alias Gate.{Config, Exe}

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
    stream: false,
    # A golden run stages each warm cache's seed (`Gate.Golden`).
    seed: false,
    report: &__MODULE__.no_report/3,
    say: &__MODULE__.say/1
  ]

  def no_report(_part, _state, _message), do: :ok
  def say(line), do: IO.puts(:stderr, line)

  @doc """
  Runs each `{job, host}` at once (`host` a VM's name, or `:lease`) and
  returns, in order, each part's
  `%{name, host, result, rc, secs, log, reran_from, why}`; `result` is
  `:green`, `:red`, `:vm_failed` or, for `gate run`, `:overlay`.
  """
  def run(%__MODULE__{} = ctx, assigned) do
    File.mkdir_p!(ctx.config.logs)
    File.mkdir_p!(ctx.work)
    state = %{parts: %{}, results: %{}, pending: %{}}

    state =
      assigned
      |> Enum.with_index()
      |> Enum.reduce(state, fn
        {{job, :lease}, i}, state ->
          lease(ctx, state, %{i: i, job: job, reran_from: nil}, nil)

        {{job, host}, i}, state ->
          start(ctx, state, %{i: i, job: job, reran_from: nil}, host, "on #{host}")
      end)

    state = loop(ctx, state)
    for i <- 0..(length(assigned) - 1), do: state.results[i]
  end

  defp loop(ctx, state) do
    if map_size(state.parts) > 0 or map_size(state.pending) > 0,
      do: loop(ctx, poll_all(ctx, state)),
      else: state
  end

  defp poll_all(ctx, state) do
    Process.sleep(Config.limit_ms(ctx.config, "poll"))
    state = granted(ctx, state)

    state.parts
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce(state, &poll(ctx, &2, &1))
  end

  # A part waits for a VM from `Fleet`.
  defp lease(ctx, state, base, why) do
    pid =
      Gate.Lease.request(ctx.config.name, base.job.name, base.i,
        warm: Enum.map(base.job.warm, & &1.key)
      )

    ctx.report.(
      base,
      :working,
      if(why, do: "#{why}; waiting for a VM", else: "waiting for a VM")
    )

    put_in(state.pending[base.i], Map.merge(base, %{lease: pid, why: why}))
  end

  # Starts each part whose VM `Fleet` has leased.
  defp granted(ctx, state) do
    receive do
      {:fleet_granted, i, host, _pid} ->
        {base, pending} = Map.pop!(state.pending, i)
        message = if base.why, do: "#{base.why}; rerunning on #{host}", else: "on #{host}"
        if base.why, do: ctx.say.("#{base.job.name}: rerunning on #{host}")
        state = start(ctx, %{state | pending: pending}, Map.delete(base, :why), host, message)
        granted(ctx, state)

      {:fleet_lost, _i, why} ->
        raise Gate.Error, "rigd's Fleet went mid-gate (#{why}); no verdict"
    after
      0 -> state
    end
  end

  defp start(ctx, state, base, host, message) do
    %{job: job} = base
    id = "#{ctx.run}-#{job.name}-#{host}"
    log = Path.join(ctx.config.logs, "#{host}-#{ctx.run}-#{job.name}.log")
    File.write!(log, "")
    now = now()

    part =
      Map.merge(base, %{
        host: host,
        id: id,
        log: log,
        t0: now,
        offset: 0,
        life: nil,
        phase: "setup",
        phase_at: now,
        last_ok: now,
        warm_relaunched: false,
        relaunched: false,
        lease: base[:lease]
      })

    ctx.report.(part, :working, message)

    with {:ok, tar} <- pack(ctx, part),
         :ok <- stage(ctx, part, tar),
         {:ok, life} <- Exe.launch(host, id, ctx.config.limits["launch"]) do
      if file = System.get_env("GATE_PARTS_FILE"),
        do: File.write!(file, "#{host} #{id}\n", [:append])

      put_in(state.parts[part.i], %{part | life: life, last_ok: now()})
    else
      {:error, why, how} -> failed(ctx, state, part, why, how)
      {:error, why} -> failed(ctx, state, part, why)
    end
  end

  # Uploads the part's tar, its size and lap in the part's log (and the
  # gate's output once it is big enough to matter). An upload that outlasts
  # its limit is the laptop's link, not the VM: a big one tries once more
  # with twice the time, and one that still does not arrive reruns as
  # `restarted`, which `Fleet` holds against no VM.
  @big_upload 20_000_000
  defp stage(ctx, part, tar) do
    limit = ctx.config.limits["stage"]
    size = File.stat!(tar).size
    mb = Float.round(size / 1_000_000, 1)
    t0 = now()

    result =
      case Exe.stage(part.host, part.id, tar, limit) do
        {:error, {:timeout, why}} when size >= @big_upload ->
          note(part, "#{why}; uploading #{mb} MB again with #{limit * 2} s")

          ctx.say.(
            "#{part.job.name}: the #{mb} MB upload to #{part.host} outlasted #{limit} s; again with #{limit * 2} s"
          )

          Exe.stage(part.host, part.id, tar, limit * 2)

        other ->
          other
      end

    secs = div(now() - t0, 1000)
    note(part, "uploaded #{mb} MB in #{secs} s")

    if size >= @big_upload,
      do: ctx.say.("#{part.job.name}: uploaded #{mb} MB to #{part.host} in #{secs} s")

    case result do
      {:error, {:timeout, why}} -> {:error, why, "restarted"}
      other -> other
    end
  end

  # The part's tar: the host-side job and its launch (and rig's image script
  # for a project that uses it), its vars and argv, the bundle that brings
  # the VM to the commit, and `gate run`'s overlay.
  defp pack(ctx, part) do
    dir = Path.join(ctx.work, part.id)
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    for {source, file} <- Exe.files(),
        do: File.cp!(Path.join(Gate.root(), source), Path.join(dir, file))

    if ctx.config.image, do: File.cp!(Gate.Stamp.image(), Path.join(dir, "image.sh"))

    for warm <- part.job.warm,
        ctx.seed,
        seed = seed(ctx.config, warm.name),
        File.exists?(seed),
        do: File.cp!(seed, Path.join(dir, "seed-#{warm.name}.tar"))

    File.write!(Path.join(dir, "vars"), vars(ctx, part.job))
    File.write!(Path.join(dir, "argv"), Enum.map(part.job.argv, &[&1, 0]))

    if overlay = part.job.overlay do
      for file <- ["tree.patch", "untracked.tar"],
          do: File.cp!(Path.join(overlay, file), Path.join(dir, file))
    end

    with :ok <- bundle(ctx, part.host, Path.join(dir, "in.bundle")) do
      tar = dir <> ".tar"

      case System.cmd("tar", ["--no-mac-metadata", "--no-xattrs", "-cf", tar, "-C", dir, "."],
             env: [{"COPYFILE_DISABLE", "1"}],
             stderr_to_stdout: true
           ) do
        {_, 0} -> {:ok, tar}
        {out, _} -> {:error, "packing the part failed: #{Gate.last_line(out)}"}
      end
    end
  end

  @doc """
  The laptop's seed for a project's warm cache: a tar of what the cache
  builds, from the VM's home (`soco/priv/plts/…`, `.mix/…`), which a
  golden run unpacks before building it. Under
  `$GATE_SEED`, else `~/.cache/gate-seed`, as `<project>/<warm>.tar`.
  """
  def seed(config, warm) do
    dir = System.get_env("GATE_SEED") || Path.expand("~/.cache/gate-seed")
    Path.join([dir, config.name, warm <> ".tar"])
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
    WARM_FORCE=#{if ctx.seed, do: "1", else: "''"}
    """
  end

  defp q(value), do: "'" <> String.replace(to_string(value), "'", ~S('\'')) <> "'"
  defp qs(values), do: Enum.map_join(values, " ", &q/1)

  # Nothing when the VM has the commit; else only the commits it lacks:
  # those since the last tip it fetched when this checkout has that commit,
  # and since the newest of HEAD's first parents it holds (`Exe.holds/3`).
  # The whole history (soco's is about 300 MB) goes only to a VM holding
  # none of them. A VM that cannot be asked takes nothing: a full bundle
  # sent to a host that was merely slow to answer is what outlasted the
  # upload's limit.
  @candidates 64
  defp bundle(ctx, host, path) do
    git = &System.cmd("git", &1, cd: ctx.config.top, stderr_to_stdout: true)

    candidates =
      case git.(["rev-list", "--first-parent", "-n", to_string(@candidates), "HEAD"]) do
        {out, 0} -> String.split(out)
        _ -> []
      end

    with {:ok, tip, have} <- holds(host, ctx.config.name, candidates) do
      known_tip = tip != nil and match?({_, 0}, git.(["cat-file", "-e", "#{tip}^{commit}"]))

      args =
        cond do
          have != nil and have == List.first(candidates) -> nil
          known_tip and match?({_, 0}, git.(["merge-base", "--is-ancestor", "HEAD", tip])) -> nil
          known_tip -> ["HEAD", "--not", tip] ++ List.wrap(have)
          have -> ["HEAD", "--not", have]
          true -> ["HEAD"]
        end

      write_bundle(git, path, args)
    end
  end

  defp holds(host, name, candidates, tries \\ 2) do
    case Exe.holds(host, name, candidates) do
      {:error, _} when tries > 1 ->
        Process.sleep(2000)
        holds(host, name, candidates, tries - 1)

      {:error, why} ->
        {:error, "could not ask #{host} what it holds (#{why})", "restarted"}

      ok ->
        ok
    end
  end

  defp write_bundle(git, path, args) do
    if args do
      case git.(["bundle", "create", "-q", path | args]) do
        {_, 0} -> :ok
        {out, _} -> {:error, "git bundle failed: #{Gate.last_line(out)}"}
      end
    else
      File.write!(path, "")
    end
  end

  defp poll(ctx, state, i) do
    part = state.parts[i]
    limits = ctx.config.limits

    case Exe.poll(part.host, part.id, part.offset, 30) do
      {:ok, :gone, _} ->
        failed(ctx, state, part, "the VM has no such part")

      {:error, why} ->
        if now() - part.last_ok > limits["unreachable"] * 1000,
          do:
            failed(
              ctx,
              state,
              part,
              "unreachable for #{limits["unreachable"]} s: #{why}",
              "restarted"
            ),
          else: state

      {:ok, host_state, bytes} ->
        part = take_log(ctx, part, bytes, host_state["size"])
        judge(ctx, state, part, host_state)
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
          "the VM restarted while warming (life #{part.life}, now #{s["life"]}); relaunching here"
        )

        ctx.say.("#{part.job.name}: #{part.host} restarted while warming; relaunching it there")
        relaunch(ctx, state, %{part | warm_relaunched: true})

      # Restarts are platform events, no likelier on this VM than on
      # another, and here its caches are warm: its rerun is here.
      s["life"] not in [nil, "", part.life] and not part.relaunched ->
        note(
          part,
          "it restarted mid-part (life #{part.life}, now #{s["life"]}); rerunning it here"
        )

        ctx.say.("#{part.job.name}: #{part.host} restarted; rerunning it there")
        ctx.report.(part, :working, "#{part.host} restarted; rerunning it there")
        relaunch(ctx, state, %{part | relaunched: true})

      s["life"] not in [nil, "", part.life] ->
        failed(
          ctx,
          state,
          part,
          "it restarted mid-part (life #{part.life}, now #{s["life"]})",
          "restarted"
        )

      s["rc"] not in [nil, ""] ->
        ended(ctx, state, part, String.to_integer(s["rc"]))

      s["job"] == "down" ->
        failed(ctx, state, part, "the part ended without a status")

      now() - part.phase_at > limit * 1000 ->
        Exe.kill(part.host, part.id)
        failed(ctx, state, part, "its #{phase} phase outlasted #{limit} s")

      true ->
        put_in(state.parts[part.i], part)
    end
  end

  defp relaunch(ctx, state, part) do
    case Exe.launch(part.host, part.id, ctx.config.limits["launch"]) do
      {:ok, life} ->
        put_in(state.parts[part.i], %{part | life: life, phase: "setup", phase_at: now()})

      {:error, why} ->
        failed(ctx, state, part, why)
    end
  end

  defp ended(ctx, state, part, rc) do
    cond do
      part.phase != "run" and rc == 125 and File.read!(part.log) =~ "cannot overlay" ->
        give_back(part, "red")
        done(ctx, state, part, :overlay, rc, "the working tree would not lay over the commit")

      part.phase != "run" ->
        failed(ctx, state, part, "exit #{rc} in #{part.phase}: #{last_log_line(part)}")

      rc != 0 and crashed?(part.log) and reruns?(part) ->
        ctx.say.("#{part.job.name}: a process crashed on #{part.host} (log #{part.log})")
        rerun(ctx, state, part, "a native crash, not a gate result", "crashed")

      rc != 0 and crashed?(part.log) ->
        again = if part.reran_from, do: ", on its rerun too"
        ctx.say.("#{part.job.name}: a process crashed on #{part.host}#{again} (log #{part.log})")
        give_back(part, "crashed")
        done(ctx, state, part, :vm_failed, rc, "a process crashed#{again}")

      true ->
        result = if rc == 0, do: :green, else: :red
        ctx.say.("#{part.job.name} #{result} in #{secs(part)} s on #{part.host}")
        give_back(part, to_string(result))
        done(ctx, state, part, result, rc, nil)
    end
  end

  # `how` is what `Fleet` hears: `restarted` (the VM restarted or went
  # unreachable, a platform event that says nothing of the VM) or
  # `failed`.
  defp failed(ctx, state, part, why, how \\ "failed") do
    note(part, "#{part.host} failed: #{why}")

    if reruns?(part) do
      ctx.say.("#{part.job.name}: #{part.host} failed (#{why})")
      rerun(ctx, state, part, "#{part.host} failed", how)
    else
      ctx.say.("#{part.job.name}: #{part.host} failed: #{why}")
      give_back(part, how)
      done(ctx, state, part, :vm_failed, nil, why)
    end
  end

  # A leased part reruns once; a named VM's (`gate golden`'s) does not.
  defp reruns?(part), do: part.lease != nil and part.reran_from == nil

  # A part to rerun gives its VM back and waits for the next `Fleet` leases.
  defp rerun(ctx, state, part, why, how) do
    give_back(part, how)
    note(part, "#{why}; rerunning on the next VM the fleet leases")
    state = %{state | parts: Map.delete(state.parts, part.i)}
    lease(ctx, state, %{i: part.i, job: part.job, reran_from: part.host}, why)
  end

  defp give_back(%{lease: nil}, _result), do: :ok
  defp give_back(%{lease: pid}, result), do: Gate.Lease.release(pid, result)

  defp done(ctx, state, part, result, rc, why) do
    secs = secs(part)

    message =
      case result do
        :green -> "green in #{secs} s on #{part.host}"
        :red -> "red in #{secs} s on #{part.host}"
        _ -> "#{why} (#{part.host}, after #{secs} s)"
      end

    ctx.report.(part, if(result == :green, do: :done, else: :error), message)

    entry = %{
      name: part.job.name,
      host: part.host,
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

  defp last_log_line(part), do: part.log |> File.read!() |> Gate.last_line()

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
