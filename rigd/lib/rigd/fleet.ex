defmodule Rigd.Fleet do
  @moduledoc """
  The shared pool of gate Sprites (`gate/FLEET.md`): one
  `Rigd.Fleet.Sprite` per Sprite named in `gate/fleet.json`, the lease
  queue, rolling a stamp change across the pool, and the nightly restore.
  Gates reach it on a Unix socket (`Rigd.Fleet.Socket`).

  A lease goes to the first waiter, oldest first, as soon as a Sprite is
  idle and golden: one the waiter's `prefer` names, else one that served
  its project since its last restore (its tree and build caches are
  there), else any. A waiter that goes leaves the queue.

  One Sprite provisions at a time, in turn (`turn/2`): a fresh Sprite
  takes each project's whole history as a git bundle (soco's is 320 MiB),
  and nine at once from the laptop outlasted the upload's limit on every
  try, together (2026-10-29).

  Every 10 minutes it reads each project's stamp on `origin/main`. An idle
  Sprite whose golden checkpoint was taken under other stamps is made
  golden again, one at a time and only while no gate waits: its gates
  would still pass (each part installs what it lacks), but a restore would
  bring back the old tools. At 04:00 every idle Sprite restores its golden
  checkpoint, dropping what the day left.
  """

  use GenServer
  require Logger

  alias Rigd.Fleet.Sprite

  @stamps_every 10 * 60 * 1000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Queues `holder` for a Sprite; it gets `{:fleet_granted, sprite}` when one is leased to it."
  def lease(holder, project, prefer \\ []),
    do: GenServer.cast(__MODULE__, {:lease, holder, project, prefer})

  def release(sprite, holder, result), do: Sprite.release(sprite, holder, result)

  @doc "Asks for the turn to provision; `pid` gets `:fleet_turn` when it has it."
  def turn(fleet, pid), do: GenServer.cast(fleet, {:turn, pid})

  @doc "Says `pid` holds the turn (a Sprite provisioning when `Fleet` restarted)."
  def holding(fleet, pid), do: GenServer.cast(fleet, {:holding, pid})

  @doc "Gives the turn back."
  def turn_done(fleet, pid), do: GenServer.cast(fleet, {:turn_done, pid})

  @doc "Each Sprite's state, the current stamps, and the queue's length."
  def status, do: GenServer.call(__MODULE__, :status)

  @doc """
  The Sprite to lease to a waiter for `project` among `sprites` (name =>
  summary), or nil: idle and golden, preferring `prefer`, then one that
  served the project.
  """
  def pick(sprites, project, prefer) do
    idle =
      for {name, s} <- Enum.sort(sprites), s.status == :idle, s.stamps != nil, do: {name, s}

    Enum.find_value(idle, fn {name, _} -> if name in prefer, do: name end) ||
      Enum.find_value(idle, fn {name, s} -> if project in s.served, do: name end) ||
      Enum.find_value(idle, fn {name, _} -> name end)
  end

  @doc "The idle Sprite to make golden again under `stamps`, or nil."
  def stale(sprites, stamps) when map_size(stamps) > 0 do
    busy = Enum.any?(sprites, fn {_, s} -> s.status in [:waiting, :provisioning] end)

    unless busy do
      Enum.find_value(Enum.sort(sprites), fn {name, s} ->
        if s.status == :idle and s.stamps != nil and s.stamps != stamps, do: name
      end)
    end
  end

  def stale(_sprites, _stamps), do: nil

  @doc "Milliseconds from `now` (a NaiveDateTime, local) to the next 04:00."
  def until_nightly(now) do
    today = NaiveDateTime.new!(NaiveDateTime.to_date(now), ~T[04:00:00])

    next =
      if NaiveDateTime.compare(now, today) == :lt,
        do: today,
        else: NaiveDateTime.add(today, 1, :day)

    NaiveDateTime.diff(next, now, :millisecond)
  end

  # --- the process

  @impl true
  def init(opts) do
    for name <- opts[:sprites] do
      spec = {Sprite, Keyword.merge(opts, name: name, fleet: __MODULE__)}

      # A Sprite that outlived a restart of this process says where it is.
      case DynamicSupervisor.start_child(Rigd.Fleet.Sprites, spec) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> Sprite.retell(name)
      end
    end

    send(self(), :stamps)
    Process.send_after(self(), :nightly, until_nightly(NaiveDateTime.local_now()))

    {:ok,
     %{
       opts: opts,
       sprites: Map.new(opts[:sprites], &{&1, %{status: :checking, stamps: nil, served: []}}),
       queue: [],
       turn: nil,
       turns: [],
       stamps: %{},
       reading: nil
     }}
  end

  @impl true
  def handle_cast({:lease, holder, project, prefer}, st) do
    ref = Process.monitor(holder)
    waiter = %{holder: holder, ref: ref, project: project, prefer: prefer}
    {:noreply, grant(%{st | queue: st.queue ++ [waiter]})}
  end

  def handle_cast({:turn, pid}, st) do
    if Enum.any?([st.turn | st.turns], &match?({^pid, _}, &1)) do
      {:noreply, st}
    else
      {:noreply, next_turn(%{st | turns: st.turns ++ [{pid, Process.monitor(pid)}]})}
    end
  end

  def handle_cast({:holding, pid}, %{turn: nil} = st),
    do: {:noreply, %{st | turn: {pid, Process.monitor(pid)}}}

  def handle_cast({:holding, _pid}, st), do: {:noreply, st}

  def handle_cast({:turn_done, pid}, %{turn: {pid, ref}} = st) do
    Process.demonitor(ref, [:flush])
    {:noreply, next_turn(%{st | turn: nil})}
  end

  def handle_cast({:turn_done, _pid}, st), do: {:noreply, st}

  @impl true
  def handle_call(:status, _from, st) do
    {:reply, %{sprites: st.sprites, stamps: st.stamps, waiting: length(st.queue)}, st}
  end

  @impl true
  def handle_info({:sprite, name, summary}, st) do
    st = put_in(st.sprites[name], summary)
    {:noreply, st |> grant() |> roll()}
  end

  def handle_info({:DOWN, ref, :process, _, _}, st) do
    st = %{
      st
      | queue: Enum.reject(st.queue, &(&1.ref == ref)),
        turns: Enum.reject(st.turns, &match?({_, ^ref}, &1)),
        turn: if(match?({_, ^ref}, st.turn), do: nil, else: st.turn)
    }

    {:noreply, next_turn(st)}
  end

  def handle_info(:stamps, %{reading: nil} = st) do
    Process.send_after(self(), :stamps, @stamps_every)
    %{golden: golden, gate: gate, projects: projects} = Map.new(st.opts)

    task =
      Task.async(fn ->
        Enum.reduce_while(projects, %{}, fn dir, acc ->
          case golden.stamp(gate, dir) do
            {:ok, name, stamp} ->
              {:cont, Map.put(acc, name, stamp)}

            {:error, why} ->
              Logger.warning("fleet: no stamp for #{dir}: #{why}")
              {:halt, nil}
          end
        end)
      end)

    {:noreply, %{st | reading: task.ref}}
  end

  def handle_info(:stamps, st), do: {:noreply, st}

  def handle_info({ref, stamps}, %{reading: ref} = st) do
    Process.demonitor(ref, [:flush])
    {:noreply, roll(%{st | stamps: stamps || st.stamps, reading: nil})}
  end

  def handle_info(:nightly, st) do
    Process.send_after(self(), :nightly, until_nightly(NaiveDateTime.local_now()) + 1000)
    for {name, %{status: :idle}} <- st.sprites, do: Sprite.restore(name)
    {:noreply, st}
  end

  def handle_info(_, st), do: {:noreply, st}

  # Leases idle Sprites to the waiters, oldest first.
  defp grant(%{queue: []} = st), do: st

  defp grant(st) do
    {queue, sprites} =
      Enum.reduce(st.queue, {[], st.sprites}, fn w, {kept, sprites} ->
        with name when name != nil <- pick(sprites, w.project, w.prefer),
             :ok <- Sprite.lease(name, w.holder, w.project) do
          Process.demonitor(w.ref, [:flush])
          send(w.holder, {:fleet_granted, name})
          {kept, put_in(sprites[name].status, :leased)}
        else
          _ -> {kept ++ [w], sprites}
        end
      end)

    %{st | queue: queue, sprites: sprites}
  end

  # The turn to provision goes to the next Sprite asking for it.
  defp next_turn(%{turn: nil, turns: [{pid, _} = next | turns]} = st) do
    send(pid, :fleet_turn)
    %{st | turn: next, turns: turns}
  end

  defp next_turn(st), do: st

  defp roll(%{queue: []} = st) do
    if name = stale(st.sprites, st.stamps) do
      Logger.info("fleet: #{name} is golden under old stamps; making it golden again")
      Sprite.regolden(name)
      put_in(st.sprites[name].status, :provisioning)
    else
      st
    end
  end

  defp roll(st), do: st
end
