defmodule Rigd.Fleet.Socket do
  @moduledoc """
  The fleet's Unix socket (`~/Library/Caches/rigd/fleet.sock`), one JSON
  object per line each way:

      → {"lease": {"project": "soco", "part": "static-1", "prefer": ["rig-gate-3"]}}
      ← {"granted": "rig-gate-3"}                 (when one is idle; until then nothing)
      → {"release": {"sprite": "rig-gate-3", "result": "green"}}
      ← {"released": "rig-gate-3"}
      → {"status": {}}
      ← {"sprites": {...}, "stamps": {...}, "waiting": 0}

  Each connection is a process, and it holds what it leased: a gate that
  dies closes its connection, and the Sprite it held ends its parts before
  it is leased again. `result` is `green` or `red` (the part ran), `restarted`
  (its Sprite restarted or went unreachable), `failed` (the Sprite failed
  it otherwise) or `crashed` (a native crash).
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

  defp handle(_sock, %{"lease" => %{"project" => project} = lease}, nil) do
    Rigd.Fleet.lease(self(), project, Map.get(lease, "prefer", []))
    nil
  end

  defp handle(sock, %{"release" => %{"sprite" => sprite, "result" => result}}, sprite)
       when result in ~w(green red restarted failed crashed) do
    case Rigd.Fleet.release(sprite, self(), result) do
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

    reply(sock, %{sprites: sprites, stamps: st.stamps, waiting: st.waiting})
    leased
  end

  defp handle(sock, msg, leased) do
    reply(sock, %{error: "not understood: #{inspect(msg)} (holding #{leased || "nothing"})"})
    leased
  end

  defp reply(sock, msg), do: :gen_tcp.send(sock, JSON.encode!(msg) <> "\n")
end
