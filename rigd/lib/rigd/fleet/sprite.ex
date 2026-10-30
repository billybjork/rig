defmodule Rigd.Fleet.Sprite do
  @moduledoc """
  One shared-pool Sprite (`rig-gate-N`): its state, its golden checkpoint,
  its lease holder and its strikes. It does its own lifecycle work (each
  `sprite` call through `Rigd.Fleet.CLI`) in a task and tells `Rigd.Fleet`
  each time its state changes.

    * `checking`: at start, whether it exists and has a golden checkpoint.
    * `idle`: golden; `Fleet` may lease it.
    * `leased`: a gate holds it for as long as its connection lives. A
      holder that goes without releasing it leaves parts running, which
      are ended before it is idle again.
    * `restoring`: back to its golden checkpoint (about 30 s), after a
      part it failed or crashed, and nightly.
    * `waiting`, then `provisioning`: made golden: created when missing, then every
      project's provision gate (`gate golden`, `Rigd.Fleet.Golden`) and a
      checkpoint whose comment names each project's stamp (`golden soco
      13545dd5… heaters 7d1c…`). It waits for its turn (`Rigd.Fleet.turn/2`):
      three Sprites provision at a time. A provision the Sprite fails is tried
      once more, then the Sprite is rebuilt (destroyed and created again).

  A part it failed or crashed is a strike; three in a day retire it: it is
  destroyed and built again under the same name (Billy: Sprites are
  disposable, never investigated). A restore that never reached the Sprite
  (the laptop offline, the API down) is tried again each minute: a rebuild
  then would throw away a good golden checkpoint, as an outage did to the
  whole pool (2026-10-30). One the Sprite refused rebuilds it.
  """

  use GenServer, restart: :permanent
  require Logger

  alias Rigd.Fleet.CLI

  @strikes 3
  @day 24 * 3600

  # A `sprite` call that never reached the Sprite: no network, or no API.
  @unreached ~r/exited 142:|no such host|failed to make request|dial tcp|connection (closed|refused|reset)|deadline exceeded|timed? ?out/i

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: via(opts[:name]))

  def child_spec(opts), do: %{id: opts[:name], start: {__MODULE__, :start_link, [opts]}}

  defp via(name), do: {:via, Registry, {Rigd.Fleet.Registry, name}}

  @doc "Leases it to `holder` (a pid) for `project` when idle: `:ok` or `{:error, status}`."
  def lease(name, holder, project), do: GenServer.call(via(name), {:lease, holder, project})

  @doc "The holder's verdict: `green`, `red`, `failed` (the Sprite failed the part), `crashed`."
  def release(name, holder, result), do: GenServer.call(via(name), {:release, holder, result})

  @doc "Back to its golden checkpoint, when idle (nightly)."
  def restore(name), do: GenServer.cast(via(name), :restore)

  @doc "Golden again under the current stamps, when idle."
  def regolden(name), do: GenServer.cast(via(name), :regolden)

  @doc "Tells `Rigd.Fleet` its state again."
  def retell(name), do: GenServer.cast(via(name), :tell)

  @doc "The golden comment's stamps from a `checkpoint list` line, or nil."
  def golden_stamps(line) do
    case Regex.run(~r/golden((?: [\w.-]+ [0-9a-f]{16})+)/, line) do
      [_, pairs] ->
        pairs |> String.split() |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {k, v} end)

      nil ->
        nil
    end
  end

  def golden_comment(stamps),
    do: "golden " <> Enum.map_join(Enum.sort(stamps), " ", fn {k, v} -> "#{k} #{v}" end)

  @doc "The newest golden checkpoint in a `checkpoint list`: `%{id, stamps}` or nil."
  def newest_golden(checkpoints) do
    checkpoints
    |> Enum.flat_map(fn {id, line} ->
      if stamps = golden_stamps(line), do: [%{id: id, stamps: stamps}], else: []
    end)
    |> Enum.max_by(&version/1, fn -> nil end)
  end

  defp version(%{id: id}) do
    case Regex.run(~r/(\d+)\D*$/, id) do
      [_, n] -> String.to_integer(n)
      nil -> 0
    end
  end

  @doc "Strikes within the last day, `now` included."
  def strike(strikes, now), do: [now | Enum.filter(strikes, &(now - &1 < @day))]

  def retire?(strikes), do: length(strikes) >= @strikes

  # --- the process

  @impl true
  def init(opts) do
    st = %{
      name: opts[:name],
      fleet: opts[:fleet],
      opts: opts,
      status: :checking,
      golden: nil,
      holder: nil,
      served: [],
      strikes: [],
      failures: 0,
      task: nil,
      # The provision waiting for its turn: {:provision, create?}.
      waiting: nil,
      why: nil
    }

    {:ok, work(st, :checking, :check)}
  end

  @impl true
  def handle_call({:lease, holder, project}, _from, %{status: :idle} = st) do
    ref = Process.monitor(holder)
    served = [project | List.delete(st.served, project)]
    {:reply, :ok, tell(%{st | status: :leased, holder: {holder, ref}, served: served})}
  end

  def handle_call({:lease, _, _}, _from, st), do: {:reply, {:error, st.status}, st}

  def handle_call({:release, holder, result}, _from, %{holder: {holder, ref}} = st) do
    Process.demonitor(ref, [:flush])
    st = %{st | holder: nil}

    st =
      if result in ["failed", "crashed"] do
        Logger.warning("fleet: #{st.name} #{result} a part; a strike")
        struck(st)
      else
        tell(%{st | status: :idle})
      end

    {:reply, :ok, st}
  end

  def handle_call({:release, _, _}, _from, st), do: {:reply, {:error, :not_holder}, st}

  @impl true
  def handle_cast(:restore, %{status: :idle} = st), do: {:noreply, work(st, :restoring, :restore)}
  def handle_cast(:regolden, %{status: :idle} = st), do: {:noreply, provision(st, false)}

  def handle_cast(:tell, st) do
    # `Fleet` restarted: it learns the turn again.
    case st do
      %{waiting: {:provision, _}} -> Rigd.Fleet.turn(st.fleet, self())
      %{task: {_, {:provision, _}}} -> Rigd.Fleet.holding(st.fleet, self())
      _ -> :ok
    end

    {:noreply, tell(st)}
  end

  def handle_cast(_, st), do: {:noreply, st}

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{holder: {_, ref}} = st) do
    # The holder went without a release: its parts may still run there.
    Logger.warning("fleet: #{st.name}'s holder went without releasing it; ending its parts")
    {:noreply, work(%{st | holder: nil}, :leased, :end_parts)}
  end

  def handle_info(:fleet_turn, %{waiting: {:provision, _} = step} = st),
    do: {:noreply, work(%{st | waiting: nil}, :provisioning, step)}

  def handle_info(:fleet_turn, st) do
    Rigd.Fleet.turn_done(st.fleet, self())
    {:noreply, st}
  end

  def handle_info({ref, result}, %{task: {ref, step}} = st) do
    Process.demonitor(ref, [:flush])
    {:noreply, finished(st, step, result)}
  end

  def handle_info({:DOWN, ref, :process, _, why}, %{task: {ref, step}} = st),
    do: {:noreply, finished(st, step, {:error, "the task died: #{inspect(why)}"})}

  def handle_info({:again, step}, %{task: nil} = st), do: {:noreply, again(st, step)}
  def handle_info(_, st), do: {:noreply, st}

  defp finished(st, step, result) do
    if match?({:provision, _}, step), do: Rigd.Fleet.turn_done(st.fleet, self())
    done(%{st | task: nil}, step, result)
  end

  defp again(st, {:provision, create?}), do: provision(st, create?)
  defp again(st, step), do: work(st, st.status, step)

  # Runs `step` in a task, in `status`.
  defp work(st, status, step) do
    name = st.name
    opts = st.opts
    golden = st.golden
    task = Task.async(fn -> run(step, name, golden, opts) end)
    tell(%{st | status: status, task: {task.ref, step}})
  end

  defp provision(st, create?) do
    Rigd.Fleet.turn(st.fleet, self())
    tell(%{st | status: :provisioning, waiting: {:provision, create?}})
  end

  defp run(:check, name, _golden, _opts) do
    with {:ok, sprites} <- CLI.list() do
      if name in sprites do
        with {:ok, cps} <- CLI.checkpoints(name), do: {:ok, newest_golden(cps)}
      else
        {:ok, :missing}
      end
    end
  end

  defp run(:restore, name, golden, _opts),
    do: CLI.ok(["checkpoint", "restore", golden.id, "-s", name], 600)

  defp run(:end_parts, name, _golden, _opts) do
    script = ~S"""
    for f in ~/parts/*/job.pid ~/parts/*/keeper.pid; do
      p=$(cat "$f" 2>/dev/null) && kill -KILL -- "-$p" 2>/dev/null
    done
    true
    """

    CLI.ok(["-s", name, "exec", "--", "bash", "-c", script], 60)
  end

  defp run(:rebuild, name, _golden, _opts) do
    with :ok <- destroy(name), do: create(name)
  end

  defp run({:provision, create?}, name, _golden, opts) do
    with :ok <- if(create?, do: create(name), else: :ok),
         {:ok, stamps} <- gates(opts, name),
         :ok <-
           CLI.ok(["checkpoint", "create", "-s", name, "-comment", golden_comment(stamps)], 600),
         {:ok, cps} <- CLI.checkpoints(name) do
      case newest_golden(cps) do
        %{stamps: ^stamps} = golden -> {:golden, golden}
        _ -> {:error, "the golden checkpoint is not in its list"}
      end
    end
  end

  # A call that outlasted its deadline may still have done its work, so the
  # retry finds the Sprite already gone, or already there: done either way.
  defp destroy(name),
    do: CLI.ok(["destroy", "--force", "-s", name], 300, ~r/sprite not found/i)

  defp create(name),
    do: CLI.ok(["create", "--skip-console", name], 300, ~r/already exists/i)

  # Every project's provision gate, in turn: `{:ok, stamps}`, or the first
  # that did not pass.
  defp gates(opts, name) do
    Enum.reduce_while(opts[:projects], {:ok, %{}}, fn dir, {:ok, stamps} ->
      case opts[:golden].run(opts[:gate], dir, name) do
        {:green, project, stamp} -> {:cont, {:ok, Map.put(stamps, project, stamp)}}
        other -> {:halt, other}
      end
    end)
  end

  # A check that went through clears the last call's failure from the status.
  defp done(st, :check, {:ok, %{} = golden}),
    do: tell(%{st | status: :idle, golden: golden, why: nil})

  defp done(st, :check, {:ok, :missing}), do: provision(%{st | why: nil}, true)
  defp done(st, :check, {:ok, nil}), do: provision(%{st | why: nil}, false)

  defp done(st, step, {:error, why}) when step in [:check, :end_parts, :rebuild] do
    Logger.warning("fleet: #{st.name} #{step}: #{why}; again in a minute")
    later(%{st | why: why}, step, 60)
  end

  defp done(st, :end_parts, :ok), do: tell(%{st | status: :idle})

  defp done(st, :restore, :ok), do: tell(%{st | status: :idle, served: [], why: nil})

  defp done(st, :restore, {:error, why}) do
    if why =~ @unreached do
      Logger.warning("fleet: #{st.name} restore did not reach it (#{why}); again in a minute")
      later(%{st | why: why}, :restore, 60)
    else
      Logger.warning("fleet: #{st.name} would not restore (#{why}); rebuilding it")
      work(%{st | why: why}, :provisioning, :rebuild)
    end
  end

  defp done(st, :rebuild, :ok), do: provision(%{st | golden: nil, served: [], why: nil}, false)

  defp done(st, {:provision, _}, {:golden, golden}) do
    Logger.info("fleet: #{st.name} golden (#{golden.id}: #{golden_comment(golden.stamps)})")
    tell(%{st | status: :idle, golden: golden, failures: 0, why: nil, served: []})
  end

  # A project's main is red: not the Sprite's doing. A Sprite with a golden
  # checkpoint goes back to work on it; one without tries again later.
  defp done(st, {:provision, _} = step, {:red, why}) do
    Logger.warning("fleet: #{st.name}: #{why}")
    st = %{st | why: why}
    if st.golden, do: work(st, :restoring, :restore), else: later(st, step, 1800)
  end

  defp done(st, {:provision, create?} = step, {kind, why})
       when kind in [:sprite_failed, :error] do
    failures = st.failures + 1
    Logger.warning("fleet: #{st.name} provision failed (#{failures}): #{why}")
    st = %{st | failures: failures, why: why}

    cond do
      kind == :error and not create? -> later(st, step, 300)
      failures == 1 -> provision(st, create?)
      failures < 4 -> work(%{st | failures: failures}, :provisioning, :rebuild)
      true -> later(%{st | failures: 0}, :rebuild, 3600)
    end
  end

  defp struck(st) do
    strikes = strike(st.strikes, System.os_time(:second))
    st = %{st | strikes: strikes}

    if retire?(strikes) do
      Logger.warning("fleet: #{st.name} has #{length(strikes)} strikes in a day; replacing it")
      work(%{st | strikes: [], golden: nil}, :provisioning, :rebuild)
    else
      work(st, :restoring, :restore)
    end
  end

  defp later(st, step, secs) do
    Process.send_after(self(), {:again, step}, secs * 1000)
    tell(st)
  end

  defp tell(st) do
    send(
      st.fleet,
      {:sprite, st.name,
       %{
         status: if(st.waiting, do: :waiting, else: st.status),
         stamps: st.golden && st.golden.stamps,
         served: st.served,
         strikes: length(st.strikes),
         why: st.why
       }}
    )

    st
  end
end
