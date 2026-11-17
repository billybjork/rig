defmodule Gate.Lease do
  @moduledoc """
  A Sprite leased from rigd's `Fleet` (`.gate.json`'s `"pool": "fleet"`),
  on its socket (`$GATE_FLEET_SOCKET`, else
  `~/Library/Caches/rigd/fleet.sock`). Each lease is a process holding
  its own connection, linked to the gate: a gate that dies closes it, and
  `Fleet` ends that part's processes on the Sprite before leasing it
  again. The process tells its owner `{:fleet_granted, key, sprite, pid}`
  once a Sprite is leased, or `{:fleet_lost, key, why}` when the
  connection went first and `Fleet` did not come back within
  `reconnect/0` (5 minutes): `bin/rigd install` drains Fleet and restarts
  rigd, and a waiter that connects again keeps its gate. A lease lost
  after its grant is not asked for again: its part ran on a Sprite that
  `Fleet` takes back.
  """

  def socket,
    do: System.get_env("GATE_FLEET_SOCKET") || Path.expand("~/Library/Caches/rigd/fleet.sock")

  @doc "Raises unless `Fleet` answers: a fleet gate without it has no verdict."
  def check! do
    case connect() do
      {:ok, sock} ->
        :gen_tcp.close(sock)

      {:error, why} ->
        raise Gate.Error,
              "rigd's Fleet does not answer on #{socket()} (#{inspect(why)}): bin/rigd status, bin/rigd fleet"
    end
  end

  @doc """
  Asks for a Sprite for `project`'s part `part`; returns the lease's pid.
  A ship worker's gate (`SHIPYARD_STATUS_ID` set) asks as `ship`, ahead of
  every session's own gate.
  """
  def request(project, part, key) do
    owner = self()
    spawn_link(fn -> hold(owner, project, part, key) end)
  end

  @doc "Gives the Sprite back with the part's `result`: green, red, restarted, failed or crashed."
  def release(pid, result) do
    ref = Process.monitor(pid)
    send(pid, {:release, result})

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      30_000 -> Process.demonitor(ref, [:flush])
    end
  end

  defp connect,
    do: :gen_tcp.connect({:local, socket()}, 0, [:binary, packet: :line, active: false], 5000)

  @doc "Milliseconds a waiter tries to reach `Fleet` again ($GATE_FLEET_RECONNECT seconds, else 300)."
  def reconnect do
    case Integer.parse(System.get_env("GATE_FLEET_RECONNECT") || "") do
      {s, ""} -> s * 1000
      _ -> 300_000
    end
  end

  defp hold(owner, project, part, key, lost \\ nil) do
    with {:ok, sock} <- connect(),
         :ok <- send_line(sock, %{lease: %{project: project, part: part, priority: priority()}}),
         {:ok, line} <- :gen_tcp.recv(sock, 0),
         %{"granted" => sprite} <- JSON.decode!(line) do
      send(owner, {:fleet_granted, key, sprite, self()})

      receive do
        {:release, result} ->
          send_line(sock, %{release: %{sprite: sprite, result: result}})
          :gen_tcp.recv(sock, 0, 30_000)
          :gen_tcp.close(sock)
      end
    else
      {:error, _} = why ->
        now = System.monotonic_time(:millisecond)
        lost = lost || now

        if now - lost < reconnect() do
          Process.sleep(1000)
          hold(owner, project, part, key, lost)
        else
          send(owner, {:fleet_lost, key, inspect(why)})
        end

      other ->
        send(owner, {:fleet_lost, key, inspect(other)})
    end
  end

  @doc false
  def priority,
    do: if(System.get_env("SHIPYARD_STATUS_ID") in [nil, ""], do: "session", else: "ship")

  defp send_line(sock, msg), do: :gen_tcp.send(sock, JSON.encode!(msg) <> "\n")
end
