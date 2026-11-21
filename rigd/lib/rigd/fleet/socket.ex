defmodule Rigd.Fleet.Socket do
  @moduledoc """
  The fleet's Unix socket (`~/Library/Caches/rigd/fleet.sock`), one JSON
  object per line each way:

      → {"lease": {"project": "soco", "part": "static-1", "prefer": ["rig-gate-3"], "priority": "ship"}}
      ← {"granted": "rig-gate-3"}                 (when one is idle; until then nothing)
      → {"release": {"sprite": "rig-gate-3", "result": "green"}}
      ← {"released": "rig-gate-3"}
      → {"lease": {"project": "heaters", "part": "test-1", "pool": "exe", "warm": ["ae71…"]}}
      ← {"granted": "rig-part-1120-2301-a1b2c3.exe.xyz"}   (`Rigd.Fleet.Exe`)
      → {"status": {}}
      ← {"sprites": {...}, "stamps": {...}, "waiting": 0, "exe": {...}}
      → {"drain": {}}
      ← {"draining": {"leased": ["rig-gate-3"], "waiting": 2}}

  Each connection is a process, and it holds what it leased: a gate that
  dies closes its connection, and the Sprite it held ends its parts before
  it is leased again. `result` is `green` or `red` (the part ran), `restarted`
  (its Sprite restarted or went unreachable), `failed` (the Sprite failed
  it otherwise) or `crashed` (a native crash). `priority` `ship` (a ship
  worker's gate) waits ahead of every other lease; anything else is a
  session's.

  `drain` stops granting for a minute, renewed by each `drain`
  (`Rigd.Fleet.drain/0`); `bin/rigd install` sends it every few seconds
  until nothing is leased, then restarts rigd.
  """

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    path = opts[:socket]
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ifaddr: {:local, path}])

    File.chmod!(path, 0o600)
    me = self()
    spawn_link(fn -> accept(listen, me) end)
    {:ok, %{listen: listen, path: path}}
  end

  @impl true
  def terminate(_why, st), do: File.rm(st.path)

  defp accept(listen, owner) do
    {:ok, sock} = :gen_tcp.accept(listen)
    {:ok, pid} = Task.Supervisor.start_child(Rigd.Fleet.Conns, fn -> serve(sock, nil) end)
    :ok = :gen_tcp.controlling_process(sock, pid)
    send(pid, :go)
    accept(listen, owner)
  end

  defp serve(sock, leased) do
    receive do
      :go ->
        :inet.setopts(sock, active: :once)
        serve(sock, leased)

      {:tcp, ^sock, line} ->
        :inet.setopts(sock, active: :once)
        serve(sock, handle(sock, decode(line), leased))

      {:fleet_granted, sprite} ->
        reply(sock, %{granted: sprite})
        serve(sock, sprite)

      {:tcp_closed, ^sock} ->
        :ok

      {:tcp_error, ^sock, _} ->
        :ok
    end
  end

  defp decode(line) do
    case JSON.decode(line) do
      {:ok, %{} = msg} -> msg
      _ -> :bad
    end
  end

  defp handle(sock, %{"lease" => %{"project" => project, "pool" => "exe"} = lease}, nil) do
    priority = if lease["priority"] == "ship", do: :ship, else: :session

    if Process.whereis(Rigd.Fleet.Exe),
      do: Rigd.Fleet.Exe.lease(self(), project, Map.get(lease, "warm", []), priority),
      else: reply(sock, %{error: "rigd's Fleet has no exe.dev pool (gate/fleet.json \"exe\")"})

    nil
  end

  defp handle(_sock, %{"lease" => %{"project" => project} = lease}, nil) do
    priority = if lease["priority"] == "ship", do: :ship, else: :session
    Rigd.Fleet.lease(self(), project, Map.get(lease, "prefer", []), priority)
    nil
  end

  defp handle(sock, %{"release" => %{"sprite" => sprite, "result" => result}}, sprite)
       when result in ~w(green red restarted failed crashed) do
    release =
      if Rigd.Fleet.Exe.host?(sprite),
        do: &Rigd.Fleet.Exe.release/3,
        else: &Rigd.Fleet.release/3

    case release.(sprite, self(), result) do
      :ok -> reply(sock, %{released: sprite})
      {:error, why} -> reply(sock, %{error: "#{why}"})
    end

    nil
  end

  defp handle(sock, %{"status" => _}, leased) do
    st = Rigd.Fleet.status()

    sprites =
      Map.new(st.sprites, fn {name, s} ->
        {name, Map.update(s, :status, nil, &to_string/1)}
      end)

    exe =
      if Process.whereis(Rigd.Fleet.Exe) do
        e = Rigd.Fleet.Exe.status()
        leases = Map.new(e.leases, fn {n, l} -> {n, Map.update!(l, :status, &to_string/1)} end)
        %{e | leases: leases}
      end

    reply(sock, %{sprites: sprites, stamps: st.stamps, waiting: st.waiting, exe: exe})
    leased
  end

  defp handle(sock, %{"drain" => _}, leased) do
    d = Rigd.Fleet.drain()

    d =
      if Process.whereis(Rigd.Fleet.Exe) do
        e = Rigd.Fleet.Exe.drain()
        %{leased: d.leased ++ e.leased, waiting: d.waiting + e.waiting}
      else
        d
      end

    reply(sock, %{draining: d})
    leased
  end

  defp handle(sock, msg, leased) do
    reply(sock, %{error: "not understood: #{inspect(msg)} (holding #{leased || "nothing"})"})
    leased
  end

  defp reply(sock, msg), do: :gen_tcp.send(sock, JSON.encode!(msg) <> "\n")
end
