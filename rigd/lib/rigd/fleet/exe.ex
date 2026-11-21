defmodule Rigd.Fleet.Exe do
  @moduledoc """
  The gate's VMs on exe.dev (rig's EXE.md, step 3): no standing pool. A
  lease is a fresh copy of the golden VM (`ssh exe.dev cp <golden> <name>
  --standalone`, about a second, warm), granted as `<name>.exe.xyz` once
  it answers SSH, and a release removes it (`rm`), whatever the part's
  result: a bad VM is never leased again, so a strike is just the next
  lease's fresh copy. A holder that goes without releasing has its VM
  removed the same way, which ends its parts.

  A lease is 4 vCPU / 8 GB (`exe.cpu`, `exe.memory` in `gate/fleet.json`;
  the suites do not scale past 4, check 0d), and 8 / 16 (`exe.big`) for a
  part that needs a warm cache whose key the golden lacks: soco's cold
  dialyzer PLT was OOM-killed at 8 GB. At most `exe.max` leases at once;
  the rest wait, a ship's gate ahead of every session's (as on the Sprite
  pool, `Rigd.Fleet`). A copy that fails is tried again for the same
  waiter after a pause that grows to 5 minutes.

  The golden is the newest paused VM named `<exe.golden>*` whose comment
  reads `golden <name> <hex> ...`: each project's stamp and warm keys on
  `origin/main` when it was made (`gate keys`, `Rigd.Fleet.Golden.keys/2`).
  Every 10 minutes it reads those keys again; when they differ, it copies
  the golden to `<exe.golden>-<time>` at the big size (the cold PLT), runs
  each project's `gate golden` there, pauses it and writes its comment,
  which makes it the golden. The old one is removed once no copy of it
  is under way. Until then leases go on from the old golden (each part
  installs what it lacks). With no golden comment anywhere, the VM named
  `exe.golden` is the seed (keys unknown, so it is refreshed first).

  Every 10 minutes, and at start, it removes what nothing holds: part VMs
  (`rig-part-*`) not leased, and golden-named VMs that are neither the
  golden nor the one being made (a refresh that rigd's restart cut off).

  `drain/0` stops leasing and refreshing for a minute, as `Rigd.Fleet`'s.
  """

  use GenServer
  require Logger

  alias Rigd.Fleet.Sprite

  @every 10 * 60 * 1000
  @drain_ms 60_000
  @part "rig-part-"
  @suffix ".exe.xyz"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether `host` is an exe.dev VM's SSH name."
  def host?(host), do: is_binary(host) and String.ends_with?(host, @suffix)

  @doc """
  Queues `holder` for a VM for `project`; it gets `{:fleet_granted, host}`.
  `warm`: the keys of the warm caches its part needs.
  """
  def lease(holder, project, warm, priority \\ :session),
    do: GenServer.cast(__MODULE__, {:lease, holder, project, warm, priority})

  def release(host, holder, result),
    do: GenServer.call(__MODULE__, {:release, host, holder, result})

  def drain, do: GenServer.call(__MODULE__, :drain)
  def status, do: GenServer.call(__MODULE__, :status)

  @doc """
  The golden among `vms` (`ls --json`'s list): the newest paused VM named
  `prefix*` with a golden comment, as `%{name, keys}`, or nil.
  """
  def golden(vms, prefix) do
    vms
    |> Enum.filter(&(String.starts_with?(&1["vm_name"], prefix) and &1["status"] == "paused"))
    |> Enum.flat_map(fn vm ->
      if keys = Sprite.golden_stamps(vm["comment"] || ""),
        do: [{vm["created_at"] || "", %{name: vm["vm_name"], keys: keys}}],
        else: []
    end)
    |> Enum.max_by(&elem(&1, 0), fn -> nil end)
    |> then(&(&1 && elem(&1, 1)))
  end

  @doc "Whether a part needing the warm keys `warm` needs the big size on a golden holding `keys`."
  def big?(keys, warm), do: Enum.any?(warm, &(&1 not in Map.values(keys || %{})))

  @doc """
  The VMs among `vms` that nothing holds: part VMs not in `held`, and
  `prefix*` VMs that are neither in `held` (the golden, the refresh) nor
  paused with a golden comment (those are old goldens: `old` below).
  """
  def strays(vms, prefix, held) do
    for vm <- vms,
        name = vm["vm_name"],
        name not in held,
        String.starts_with?(name, @part) or
          (String.starts_with?(name, prefix) and not golden_vm?(vm)),
        do: name
  end

  @doc "The old goldens among `vms`: golden VMs other than `current`."
  def old(vms, prefix, current) do
    for vm <- vms,
        name = vm["vm_name"],
        name != current,
        String.starts_with?(name, prefix),
        golden_vm?(vm),
        do: name
  end

  defp golden_vm?(vm),
    do: vm["status"] == "paused" and Sprite.golden_stamps(vm["comment"] || "") != nil

  @doc "The queue with `waiter` behind every waiter of its priority or higher."
  def enqueue(queue, waiter), do: Rigd.Fleet.enqueue(queue, waiter)

  # --- the process

  @impl true
  def init(opts) do
    exe = opts[:exe]

    st = %{
      opts: opts,
      prefix: exe["golden"],
      max: exe["max"] || 15,
      size: {exe["cpu"] || 4, exe["memory"] || "8GB"},
      big: {get_in(exe, ["big", "cpu"]) || 8, get_in(exe, ["big", "memory"]) || "16GB"},
      golden: nil,
      # Whether a listing has come back since start.
      listed: false,
      # The projects' keys on origin/main: what the golden should hold.
      target: %{},
      reading: nil,
      queue: [],
      # name => %{holder, ref, project, big, status: :creating | :leased}
      leases: %{},
      # Task refs => what they do.
      tasks: %{},
      refresh: nil,
      refresh_after: nil,
      refresh_failures: 0,
      # Old goldens to remove once no copy is under way.
      retired: [],
      failures: 0,
      backoff_until: nil,
      draining: nil,
      why: nil
    }

    send(self(), :tick)
    send(self(), :keys)
    {:ok, st}
  end

  @impl true
  def handle_cast({:lease, holder, project, warm, priority}, st) do
    ref = Process.monitor(holder)
    w = %{holder: holder, ref: ref, project: project, warm: warm, priority: priority}
    {:noreply, grant(%{st | queue: enqueue(st.queue, w)})}
  end

  @impl true
  def handle_call({:release, host, holder, result}, _from, st) do
    name = String.replace_suffix(host, @suffix, "")

    case st.leases[name] do
      %{holder: ^holder, ref: ref, status: :leased} ->
        Process.demonitor(ref, [:flush])
        if result != "green", do: Logger.info("fleet: #{name} ended #{result}; removing it")
        {:reply, :ok, st |> remove(name) |> grant()}

      _ ->
        {:reply, {:error, :not_holder}, st}
    end
  end

  def handle_call(:drain, _from, st) do
    ms = Keyword.get(st.opts, :drain_ms, @drain_ms)
    Process.send_after(self(), :drain_over, ms + 1)
    held = st.leases |> Map.keys() |> Enum.sort()
    held = if st.refresh, do: held ++ ["#{st.refresh} (golden refresh)"], else: held

    {:reply, %{leased: held, waiting: length(st.queue)},
     %{st | draining: System.monotonic_time(:millisecond) + ms}}
  end

  def handle_call(:status, _from, st) do
    leases =
      Map.new(st.leases, fn {n, l} -> {n, %{project: l.project, status: l.status, big: l.big}} end)

    {:reply,
     %{
       golden: st.golden && st.golden.name,
       keys: (st.golden && st.golden.keys) || %{},
       target: st.target,
       refresh: st.refresh,
       leases: leases,
       waiting: length(st.queue),
       why: st.why
     }, st}
  end

  @impl true
  def handle_info(:tick, st) do
    Process.send_after(self(), :tick, @every)
    send(self(), :list)
    {:noreply, st}
  end

  def handle_info(:list, st) do
    opts = st.opts
    {:noreply, task(st, :list, fn -> list(opts) end)}
  end

  def handle_info(:keys, %{reading: nil} = st) do
    Process.send_after(self(), :keys, @every)
    %{golden: golden, gate: gate, projects: projects} = Map.new(st.opts)

    t =
      Task.async(fn ->
        Enum.reduce_while(projects, %{}, fn dir, acc ->
          case golden.keys(gate, dir) do
            {:ok, keys} ->
              {:cont, Map.merge(acc, keys)}

            {:error, why} ->
              Logger.warning("fleet: exe: no keys for #{dir}: #{why}")
              {:halt, nil}
          end
        end)
      end)

    {:noreply, %{st | reading: t.ref}}
  end

  def handle_info(:keys, st), do: {:noreply, st}

  def handle_info({ref, keys}, %{reading: ref} = st) do
    Process.demonitor(ref, [:flush])
    {:noreply, refresh(%{st | target: keys || st.target, reading: nil})}
  end

  def handle_info({ref, result}, st) when is_map_key(st.tasks, ref) do
    Process.demonitor(ref, [:flush])
    {what, tasks} = Map.pop(st.tasks, ref)
    {:noreply, done(%{st | tasks: tasks}, what, result)}
  end

  def handle_info({:DOWN, ref, :process, _, why}, st) when is_map_key(st.tasks, ref) do
    {what, tasks} = Map.pop(st.tasks, ref)
    {:noreply, done(%{st | tasks: tasks}, what, {:error, "the task died: #{inspect(why)}"})}
  end

  def handle_info({:DOWN, ref, :process, _, _}, st) do
    cond do
      Enum.any?(st.queue, &(&1.ref == ref)) ->
        {:noreply, %{st | queue: Enum.reject(st.queue, &(&1.ref == ref))}}

      name = Enum.find_value(st.leases, fn {n, l} -> if l.ref == ref, do: n end) ->
        case st.leases[name] do
          %{status: :leased} ->
            Logger.warning("fleet: #{name}'s holder went without releasing it; removing it")
            {:noreply, st |> remove(name) |> grant()}

          # Its copy is under way: removed when it is made.
          %{status: :creating} ->
            {:noreply, put_in(st.leases[name].holder, nil)}
        end

      true ->
        {:noreply, st}
    end
  end

  def handle_info(:grant, st), do: {:noreply, grant(st)}
  def handle_info(:refresh, st), do: {:noreply, refresh(st)}

  def handle_info(:drain_over, st) do
    if st.draining && System.monotonic_time(:millisecond) >= st.draining,
      do: {:noreply, %{st | draining: nil} |> grant() |> refresh()},
      else: {:noreply, st}
  end

  def handle_info(_, st), do: {:noreply, st}

  # --- what the tasks' results do

  defp done(st, :list, {:ok, vms}) do
    golden =
      st.golden ||
        golden(vms, st.prefix) ||
        Enum.find_value(vms, fn vm ->
          if vm["vm_name"] == st.prefix, do: %{name: st.prefix, keys: %{}}
        end)

    if golden == nil, do: Logger.warning("fleet: exe: no golden VM (#{st.prefix}*)")
    held = Map.keys(st.leases) ++ List.wrap(st.refresh) ++ List.wrap(golden && golden.name)

    st = %{st | golden: golden, listed: true, why: if(golden, do: st.why, else: "no golden VM")}
    st = Enum.reduce(strays(vms, st.prefix, held), st, &remove(&2, &1))
    st = %{st | retired: Enum.uniq(st.retired ++ old(vms, st.prefix, golden && golden.name))}
    st |> prune() |> grant() |> refresh()
  end

  defp done(st, :list, {:error, why}) do
    Logger.warning("fleet: exe: ls: #{why}")
    Process.send_after(self(), :list, 60_000)
    %{st | why: why}
  end

  defp done(st, {:create, name}, :ok) do
    case st.leases[name] do
      %{holder: nil} ->
        st |> remove(name) |> prune() |> grant()

      %{holder: holder} ->
        send(holder, {:fleet_granted, name <> @suffix})
        st = put_in(st.leases[name].status, :leased)
        prune(%{st | failures: 0, why: nil})
    end
  end

  defp done(st, {:create, name}, {:error, why}) do
    {lease, leases} = Map.pop(st.leases, name)
    failures = st.failures + 1
    secs = min(5 * 2 ** (failures - 1), 300)
    Logger.warning("fleet: exe: copying the golden to #{name}: #{why}; again in #{secs} s")
    st = remove(%{st | leases: leases}, name)

    # Its waiter goes back to the front of its kind, unless it went.
    queue =
      if lease.holder,
        do: requeue(st.queue, Map.take(lease, [:holder, :ref, :project, :warm, :priority])),
        else: st.queue

    Process.send_after(self(), :grant, secs * 1000)

    prune(%{
      st
      | queue: queue,
        failures: failures,
        why: why,
        backoff_until: System.monotonic_time(:millisecond) + secs * 1000
    })
  end

  defp done(st, {:remove, _name}, :ok), do: st

  defp done(st, {:remove, name}, {:error, why}) do
    Logger.warning("fleet: exe: rm #{name}: #{why}; the next sweep tries again")
    st
  end

  defp done(st, {:refresh, name}, {:golden, golden}) do
    Logger.info("fleet: exe: #{name} is the golden (#{Sprite.golden_comment(golden.keys)})")
    old = if st.golden && st.golden.name != name, do: [st.golden.name], else: []

    %{
      st
      | golden: golden,
        refresh: nil,
        refresh_failures: 0,
        retired: st.retired ++ old,
        why: nil
    }
    |> prune()
    |> refresh()
  end

  defp done(st, {:refresh, name}, result) do
    {kind, why} =
      case result do
        {kind, why} when kind in [:red, :laptop, :sprite_failed, :error] -> {kind, why}
        other -> {:error, inspect(other)}
      end

    n = st.refresh_failures + 1

    secs =
      case kind do
        :red -> 1800
        :laptop -> min(60 * 2 ** (n - 1), 1800)
        _ -> min(300 * 2 ** (n - 1), 3600)
      end

    Logger.warning("fleet: exe: refreshing the golden on #{name}: #{why}; again in #{secs} s")
    Process.send_after(self(), :refresh, secs * 1000)

    remove(
      %{
        st
        | refresh: nil,
          refresh_failures: n,
          refresh_after: System.monotonic_time(:millisecond) + secs * 1000,
          why: why
      },
      name
    )
  end

  # --- leasing

  defp grant(%{queue: []} = st), do: st
  defp grant(%{draining: d} = st) when d != nil, do: st
  defp grant(%{golden: nil} = st), do: st

  defp grant(st) do
    now = System.monotonic_time(:millisecond)

    cond do
      st.backoff_until && now < st.backoff_until ->
        st

      map_size(st.leases) >= st.max ->
        st

      true ->
        [w | queue] = st.queue
        big = big?(st.golden.keys, w.warm)
        name = @part <> suffix()
        {cpu, memory} = if big, do: st.big, else: st.size

        if big,
          do:
            Logger.info("fleet: exe: #{name} for #{w.project} at #{cpu} vCPU: a cold warm cache")

        source = st.golden.name
        opts = st.opts

        lease = Map.merge(w, %{big: big, status: :creating})

        %{st | queue: queue, leases: Map.put(st.leases, name, lease), backoff_until: nil}
        |> task({:create, name}, fn -> create(opts, source, name, cpu, memory) end)
        |> grant()
    end
  end

  defp requeue(queue, w) do
    {ahead, rest} = Enum.split_with(queue, &(&1.priority == :ship and w.priority != :ship))
    ahead ++ [w | rest]
  end

  defp remove(st, name) do
    opts = st.opts
    st = %{st | leases: Map.delete(st.leases, name)}
    task(st, {:remove, name}, fn -> api(opts, ["rm", name], 120) end)
  end

  # Old goldens go once no copy is under way (one may be copying them).
  defp prune(st) do
    retired = List.delete(st.retired, st.golden && st.golden.name)

    if retired == [] or Enum.any?(st.leases, fn {_, l} -> l.status == :creating end),
      do: %{st | retired: retired},
      else: Enum.reduce(retired, %{st | retired: []}, &remove(&2, &1))
  end

  # --- the golden

  defp refresh(st) do
    now = System.monotonic_time(:millisecond)

    cond do
      not st.listed or st.target == %{} or st.refresh != nil or st.draining != nil -> st
      st.refresh_after && now < st.refresh_after -> st
      st.golden == nil -> st
      st.golden.keys == st.target -> st
      true -> start_refresh(st)
    end
  end

  defp start_refresh(st) do
    name = "#{st.prefix}-#{suffix()}"
    source = st.golden.name
    {cpu, memory} = st.big
    opts = st.opts

    Logger.info(
      "fleet: exe: the golden #{source} holds other keys than origin/main; making #{name}"
    )

    %{st | refresh: name, refresh_after: nil}
    |> task({:refresh, name}, fn -> make_golden(opts, source, name, cpu, memory) end)
  end

  defp make_golden(opts, source, name, cpu, memory) do
    host = name <> @suffix

    with :ok <- copy(opts, source, name, cpu, memory),
         :ok <- api(opts, ["comment", name, "refreshing"], 60),
         :ok <- answers(opts, host),
         {:ok, keys} <- setups(opts, host),
         :ok <- api(opts, ["pause", name], 300),
         :ok <- api(opts, ["comment", name, Sprite.golden_comment(keys)], 60) do
      {:golden, %{name: name, keys: keys}}
    end
  end

  # Every project's `gate golden` on `host`, in turn.
  defp setups(opts, host) do
    Enum.reduce_while(opts[:projects], {:ok, %{}}, fn dir, {:ok, acc} ->
      case opts[:golden].run(opts[:gate], dir, host, :keys) do
        {:green, _project, keys} -> {:cont, {:ok, Map.merge(acc, keys)}}
        other -> {:halt, other}
      end
    end)
  end

  # --- calls to exe.dev

  defp create(opts, source, name, cpu, memory) do
    with :ok <- copy(opts, source, name, cpu, memory), do: answers(opts, name <> @suffix)
  end

  defp copy(opts, source, name, cpu, memory),
    do: api(opts, ["cp", source, name, "--standalone", "--cpu=#{cpu}", "--memory=#{memory}"], 120)

  defp list(opts) do
    case call(opts, ["exe.dev", "ls", "--json"], 60) do
      {out, 0} ->
        case JSON.decode(out) do
          {:ok, %{"vms" => vms}} -> {:ok, vms}
          _ -> {:error, "ls: #{Rigd.Fleet.CLI.last_line(out)}"}
        end

      {out, status} ->
        {:error, "ls exited #{status}: #{Rigd.Fleet.CLI.last_line(out)}"}
    end
  end

  @doc false
  def api(opts, args, secs) do
    case call(opts, ["exe.dev" | args], secs) do
      {out, 0} ->
        if out =~ ~r/^(error|Error)\b/m,
          do: {:error, "#{hd(args)}: #{Rigd.Fleet.CLI.last_line(out)}"},
          else: :ok

      {out, status} ->
        {:error, "#{hd(args)} exited #{status}: #{Rigd.Fleet.CLI.last_line(out)}"}
    end
  end

  # A fresh copy is `starting` for a moment: wait (a minute at most) until
  # its SSH answers, so the part's first stage does not fail on it. Every
  # VM presents exe's one host key, pinned in `gate/exe/known_hosts`.
  defp answers(opts, host, tries \\ 30) do
    known = Path.join(Path.dirname(Path.dirname(opts[:gate])), "exe/known_hosts")
    pin = ["-o", "UserKnownHostsFile=#{known}", "-o", "StrictHostKeyChecking=yes"]

    case call(opts, pin ++ [host, "true"], 20) do
      {_, 0} ->
        :ok

      {out, status} when tries <= 1 ->
        {:error, "#{host} does not answer SSH (#{status}: #{Rigd.Fleet.CLI.last_line(out)})"}

      _ ->
        Process.sleep(Keyword.get(opts, :answer_ms, 2000))
        answers(opts, host, tries - 1)
    end
  end

  # `ssh <args>` under rig's deadline.
  defp call(opts, args, secs) do
    try do
      System.cmd(
        opts[:deadline],
        [to_string(secs), opts[:ssh] | ~w(-o BatchMode=yes -o ConnectTimeout=20) ++ args],
        stderr_to_stdout: true
      )
    rescue
      e in ErlangError -> {"cannot run #{opts[:ssh]}: #{inspect(e.original)}", 127}
    end
  end

  defp task(st, what, fun) do
    t = Task.async(fun)
    %{st | tasks: Map.put(st.tasks, t.ref, what)}
  end

  # A short name part: time, then a random tail, lowercase.
  defp suffix do
    time = Calendar.strftime(DateTime.utc_now(), "%m%d-%H%M%S")
    # Not :crypto: rigd's release does not carry it.
    tail =
      (0x1000000 + :rand.uniform(0xFFFFFF) - 1)
      |> Integer.to_string(16)
      |> String.slice(1, 6)
      |> String.downcase()

    "#{time}-#{tail}"
  end
end
