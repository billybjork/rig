defmodule Rigd.Heavy do
  @moduledoc """
  The laptop's heavy local work, queued (Billy, 2026-11-16). On that day
  five sessions' media jobs and an eval uploading video ran at once: load
  90 on 12 cores, swap full, the uplink saturated, and the gates' own
  `sprite` calls outlasted their limits, so ships that take 5 minutes took
  70 and gave no verdict.

  **Slots.** A job takes one with `bin/heavy cpu|net -- <command>` (or
  `bg run --heavy cpu|net`) and holds it while it runs: `cpu` for work that
  keeps cores busy (renders, ML, a local eval), 2 at once; `net` for work
  that keeps the uplink busy (uploading media), 1 at once. A job waits its
  turn, oldest first. On the socket (`~/Library/Caches/rigd/heavy.sock`),
  one JSON object per line each way:

      → {"take": {"kind": "cpu", "label": "joinround part 3", "pid": 4242, "cwd": "/…"}}
      ← {"waiting": {"ahead": 1, "holders": ["clean.py (heaters-studio)", …]}}   (only when it waits)
      ← {"granted": "cpu"}
      → {"status": {}}
      ← {"slots": {...}, "holders": [...], "waiting": [...], "demoted": [...]}

  A slot is held as long as its connection: the job ending ends it.

  **Demotion.** Every #{20} s, while the laptop is overloaded (the 5-minute
  load at or above its cores), a job agents or a terminal started (a process
  tree under Claude, Codex or Rex) that has kept 150% CPU or more for two
  samples running, without a slot, is put in the background
  (`taskpolicy -b`): macOS then runs it on what is left over, so it cannot
  starve the gates, the agents or the Mac, and it is never killed. A
  slot's job, the machine's gate (`~/.cache/dev-gate/lock`), the ship
  workers and rigd are never demoted. Once the load is back under three
  quarters of the cores, demoted jobs return to normal (`taskpolicy -B`).
  rigd's log says what it demoted and why.
  """

  use GenServer
  require Logger

  @every :timer.seconds(20)
  @threshold 150.0

  def socket, do: Path.expand("~/Library/Caches/rigd/heavy.sock")

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(opts) do
    path = opts[:socket] || socket()
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ifaddr: {:local, path}])

    File.chmod!(path, 0o600)
    me = self()
    spawn_link(fn -> accept(listen, me) end)
    if Keyword.get(opts, :demote, true), do: send(self(), :tick)

    {:ok,
     %{
       path: path,
       slots: opts[:slots] || Application.get_env(:rigd, :heavy_slots, %{"cpu" => 2, "net" => 1}),
       holders: [],
       queue: [],
       hot: MapSet.new(),
       demoted: %{},
       cores: System.schedulers_online()
     }}
  end

  @impl true
  def terminate(_why, st), do: File.rm(st.path)

  @impl true
  def handle_call(:status, _from, st), do: {:reply, summary(st), st}

  @impl true
  def handle_cast({:take, conn, req}, st) do
    ref = Process.monitor(conn)
    waiter = Map.merge(req, %{conn: conn, ref: ref, since: System.system_time(:second)})
    st = grant(%{st | queue: st.queue ++ [waiter]})

    if Enum.any?(st.queue, &(&1.conn == conn)) do
      ahead = Enum.take_while(st.queue, &(&1.conn != conn)) |> Enum.count(&(&1.kind == req.kind))

      holders =
        for h <- st.holders, h.kind == req.kind, do: h.label

      send(conn, {:heavy_waiting, %{ahead: ahead, holders: holders}})
    end

    {:noreply, st}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, st) do
    st = %{
      st
      | holders: Enum.reject(st.holders, &(&1.ref == ref)),
        queue: Enum.reject(st.queue, &(&1.ref == ref))
    }

    {:noreply, grant(st)}
  end

  def handle_info(:tick, st) do
    Process.send_after(self(), :tick, @every)
    {:noreply, demote(st, processes(), load5())}
  end

  def handle_info(_, st), do: {:noreply, st}

  # Grants each waiter, oldest first, whose kind has a free slot.
  defp grant(st) do
    {holders, queue} =
      Enum.reduce(st.queue, {st.holders, []}, fn w, {holders, kept} ->
        if Enum.count(holders, &(&1.kind == w.kind)) < Map.get(st.slots, w.kind, 1) do
          send(w.conn, {:heavy_granted, w.kind})
          Logger.info("heavy: #{w.kind} slot to #{w.label}")
          {holders ++ [w], kept}
        else
          {holders, kept ++ [w]}
        end
      end)

    %{st | holders: holders, queue: queue}
  end

  defp summary(st) do
    row = &Map.take(&1, [:kind, :label, :pid, :cwd, :since])

    %{
      slots: st.slots,
      holders: Enum.map(st.holders, row),
      waiting: Enum.map(st.queue, row),
      demoted: for({root, d} <- st.demoted, do: Map.put(d, :root, root))
    }
  end

  # ---- Demotion ----

  @doc false
  def demote(st, procs, load5) do
    busy = load5 >= st.cores
    calm = load5 < st.cores * 0.75

    cond do
      calm and st.demoted != %{} ->
        for {_root, d} <- st.demoted, pid <- d.pids, do: taskpolicy("-B", pid)

        Logger.info(
          "heavy: the load is #{load5}; #{map_size(st.demoted)} demoted job(s) back to normal"
        )

        %{st | demoted: %{}, hot: MapSet.new()}

      busy ->
        exempt = exempt_roots(st)
        {hot, demote} = demotions(procs, exempt, st.hot, @threshold)

        demoted =
          Enum.reduce(demote, st.demoted, fn {root, g}, demoted ->
            known = get_in(demoted, [root, :pids]) || []
            for pid <- g.pids -- known, do: taskpolicy("-b", pid)

            unless Map.has_key?(demoted, root) do
              Logger.warning(
                "heavy: put #{g.cmd} (pid #{root}, #{round(g.cpu)}% CPU) in the background at load #{load5}: it holds no slot (bin/heavy)"
              )
            end

            Map.put(demoted, root, %{cmd: g.cmd, cpu: g.cpu, pids: Enum.uniq(known ++ g.pids)})
          end)

        %{st | hot: hot, demoted: demoted}

      true ->
        %{st | hot: MapSet.new()}
    end
  end

  defp exempt_roots(st) do
    slots = Enum.map(st.holders, & &1.pid)

    gate =
      with {:ok, text} <- File.read(Path.expand("~/.cache/dev-gate/lock")),
           {pid, _} <- Integer.parse(text) do
        [pid]
      else
        _ -> []
      end

    ships =
      for file <- Path.wildcard(Path.expand("~/.cache/shipyard/*/worker.pid")),
          {pid, _} <- [file |> File.read!() |> String.trim() |> Integer.parse()],
          do: pid

    [System.pid() |> String.to_integer() | slots ++ gate ++ ships]
  end

  @doc """
  From the process table (`%{pid, ppid, cpu, cmd}`), the roots of the jobs
  that `exempt` (pids whose trees are never demoted) leaves: each job is
  the tree under the process right below an agent or Rex, with its CPU
  summed. Returns `{hot, demote}`: the roots at `threshold` or more now,
  and those that were hot in `hot_before` too, each `root => %{pids, cpu,
  cmd}`.
  """
  def demotions(procs, exempt, hot_before, threshold) do
    by_pid = Map.new(procs, &{&1.pid, &1})
    spared = descendants(procs, exempt)

    jobs =
      for p <- procs,
          not boundary?(p),
          p.pid not in spared,
          {:job, root} <- [job_root(p, by_pid, 0)],
          do: {root, p}

    hot =
      for {root, members} <- Enum.group_by(jobs, &elem(&1, 0), &elem(&1, 1)),
          cpu = members |> Enum.map(& &1.cpu) |> Enum.sum(),
          cpu >= threshold,
          into: %{},
          do: {root, %{pids: Enum.map(members, & &1.pid), cpu: cpu, cmd: short(by_pid[root].cmd)}}

    {MapSet.new(Map.keys(hot)), Map.filter(hot, fn {root, _} -> root in hot_before end)}
  end

  # The job a process belongs to: the ancestor whose parent is an agent or
  # Rex. A process under neither (an app, a daemon) belongs to none.
  defp job_root(_p, _by_pid, depth) when depth > 64, do: :none

  defp job_root(p, by_pid, depth) do
    case by_pid[p.ppid] do
      nil -> :none
      parent -> if boundary?(parent), do: {:job, p.pid}, else: job_root(parent, by_pid, depth + 1)
    end
  end

  @doc "An agent or Rex itself: the edge of a job, never part of one."
  def boundary?(%{cmd: cmd}) do
    exe = cmd |> String.split(" ", parts: 2) |> hd()

    Path.basename(exe) in ["claude", "codex"] or
      String.starts_with?(cmd, "claude ") or
      cmd =~ ~r{Rex Server\.app/|/Rex( Beta)?\.app/}
  end

  defp descendants(procs, roots) do
    children = Enum.group_by(procs, & &1.ppid, & &1.pid)
    walk(MapSet.new(roots), Enum.to_list(roots), children)
  end

  defp walk(seen, [], _children), do: seen

  defp walk(seen, [pid | rest], children) do
    new = Enum.reject(Map.get(children, pid, []), &(&1 in seen))
    walk(Enum.into(new, seen), new ++ rest, children)
  end

  defp short(cmd), do: cmd |> String.replace(~r{\S*/}, "", global: false) |> String.slice(0, 120)

  defp taskpolicy(flag, pid),
    do: Rigd.Cmd.run("taskpolicy", [flag, "-p", to_string(pid)], timeout: 5)

  defp processes do
    user = System.get_env("USER") || "billy"

    case Rigd.Cmd.out("ps", ["-x", "-U", user, "-o", "pid=,ppid=,pcpu=,command="]) do
      nil ->
        []

      out ->
        for line <- String.split(out, "\n", trim: true),
            [pid, ppid, cpu, cmd] <- [String.split(String.trim_leading(line), ~r/\s+/, parts: 4)],
            {cpu, _} <- [Float.parse(cpu)],
            do: %{pid: String.to_integer(pid), ppid: String.to_integer(ppid), cpu: cpu, cmd: cmd}
    end
  end

  defp load5 do
    case Rigd.Cmd.out("sysctl", ["-n", "vm.loadavg"]) do
      nil ->
        0.0

      out ->
        case out |> String.trim(" {}\n") |> String.split() |> Enum.at(1) |> Float.parse() do
          {load, _} -> load
          _ -> 0.0
        end
    end
  end

  # ---- The socket ----

  defp accept(listen, owner) do
    {:ok, sock} = :gen_tcp.accept(listen)
    pid = spawn(fn -> serve(sock, owner) end)
    :ok = :gen_tcp.controlling_process(sock, pid)
    send(pid, :go)
    accept(listen, owner)
  end

  defp serve(sock, owner) do
    receive do
      :go ->
        :inet.setopts(sock, active: :once)
        serve(sock, owner)

      {:tcp, ^sock, line} ->
        :inet.setopts(sock, active: :once)
        handle(sock, owner, JSON.decode(line))
        serve(sock, owner)

      {:heavy_waiting, w} ->
        reply(sock, %{waiting: w})
        serve(sock, owner)

      {:heavy_granted, kind} ->
        reply(sock, %{granted: kind})
        serve(sock, owner)

      {:tcp_closed, ^sock} ->
        :ok

      {:tcp_error, ^sock, _} ->
        :ok
    end
  end

  defp handle(_sock, owner, {:ok, %{"take" => %{"kind" => kind} = take}})
       when kind in ["cpu", "net"] do
    req = %{
      kind: kind,
      label: String.slice(to_string(take["label"] || "?"), 0, 120),
      pid: take["pid"],
      cwd: take["cwd"]
    }

    GenServer.cast(owner, {:take, self(), req})
  end

  defp handle(sock, owner, {:ok, %{"status" => _}}),
    do: reply(sock, GenServer.call(owner, :status))

  defp handle(sock, _owner, other), do: reply(sock, %{error: "not understood: #{inspect(other)}"})

  defp reply(sock, msg), do: :gen_tcp.send(sock, JSON.encode!(msg) <> "\n")
end
