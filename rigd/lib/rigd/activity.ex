defmodule Rigd.Activity do
  @moduledoc """
  The one registry of what is running, rebuilt every few seconds and
  published as `{:activity, state}`:

    * agents working (Claude Code, Codex), from the status each reports to Rex;
    * an agent's background shells (Claude's Bash children), working or not;
    * Rex background terminals whose command still runs (`bin/bg`, a ship's wait);
    * ship workers (a live `~/.cache/shipyard/<project>/worker.pid`).

  `state.items` maps a key to `%{kind, label}`; `state.agents` lists every
  agent Rex shows, whatever its state, with its tab, and `state.windows`
  every tab, for Notify and RexBadges; `state.tabs` each tab with its panes
  (directory, title, agent) and `state.blocks` every block Rex has, tab or
  background, for Closed; `state.rex_ok` is false when Rex could not be read
  this tick.
  """

  use GenServer
  require Logger

  @every :timer.seconds(4)
  @shell_marker "/.claude/shell-snapshots/"

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    send(self(), :tick)
    {:ok, %{rex_error: nil}}
  end

  @impl true
  def handle_info(:tick, st) do
    {sessions, st} =
      case Rigd.Rex.snapshot() do
        {:ok, sessions} ->
          if st.rex_error, do: Logger.info("rex: reachable again")
          {sessions, %{st | rex_error: nil}}

        {:error, why} ->
          # Logged once per outage, not every tick.
          if st.rex_error == nil, do: Logger.warning("rex: #{why}")
          {[], %{st | rex_error: why}}
      end

    state = build(sessions, processes(), ship_pids())
    Rigd.Bus.publish(:activity, Map.put(state, :rex_ok, st.rex_error == nil))
    Process.send_after(self(), :tick, @every)
    {:noreply, st}
  end

  @doc """
  The activity state from a Rex snapshot, the process table as
  `{pid, ppid, command}`, and the live ship workers as `{project, pid}`.
  """
  def build(sessions, procs, ships) do
    agents = agents(sessions)
    live = MapSet.new(procs, fn {pid, _, _} -> pid end)

    shells =
      for {pid, ppid, cmd} <- procs, String.contains?(cmd, @shell_marker), do: {pid, ppid}

    by_pid = Map.new(agents, &{&1.pid, &1})

    items =
      Enum.concat([
        for(
          a <- agents,
          a.state == "working",
          do: {{:agent, a.block}, %{kind: :agent, label: "#{a.session}: #{a.app} working"}}
        ),
        for {pid, ppid} <- shells do
          owner = by_pid[ppid]

          {{:shell, pid},
           %{
             kind: :shell,
             label: "#{(owner && owner.session) || "?"}: an agent's background shell"
           }}
        end,
        for s <- sessions, d <- s["detached"], d["running"], d["agent"] == nil do
          {{:bg, d["id"]},
           %{kind: :bg, label: "#{s["label"]}: background terminal #{d["label"]}"}}
        end,
        for(
          {project, pid} <- ships,
          pid in live,
          do: {{:ship, project}, %{kind: :ship, label: "#{project}: ship worker"}}
        )
      ])
      |> Map.new()

    windows =
      for s <- sessions,
          w <- s["windows"],
          do: %{session_id: s["id"], window_id: w["id"], label: w["label"]}

    %{
      items: items,
      agents: agents,
      windows: windows,
      tabs: tabs(sessions),
      blocks: blocks(sessions),
      shell_owners: MapSet.new(shells, &elem(&1, 1))
    }
  end

  @doc """
  Each tab with its tiled panes (directory, title, agent), for Closed.
  """
  def tabs(sessions) do
    for s <- sessions, w <- s["windows"] do
      panes =
        for b <- w["blocks"], !b["floating"] do
          a = b["agent"] || %{}
          %{block: b["id"], cwd: b["cwd"], title: b["title"], app: a["app"], pid: a["pid"]}
        end

      %{
        session_id: s["id"],
        session: s["label"],
        window_id: w["id"],
        label: w["label"],
        panes: panes
      }
    end
  end

  @doc "Every block Rex has, in a tab or in the background."
  def blocks(sessions) do
    for s <- sessions,
        b <- Enum.flat_map(s["windows"], & &1["blocks"]) ++ s["detached"],
        into: MapSet.new(),
        do: b["id"]
  end

  defp agents(sessions) do
    for s <- sessions,
        {window, blocks} <- Enum.map(s["windows"], &{&1, &1["blocks"]}) ++ [{nil, s["detached"]}],
        b <- blocks,
        a = b["agent"] do
      %{
        block: b["id"],
        session_id: s["id"],
        session: s["label"],
        window_id: window && window["id"],
        window_label: window && window["label"],
        title: b["title"],
        app: a["app"],
        state: a["state"],
        pid: a["pid"],
        msg: a["msg"]
      }
    end
  end

  defp processes do
    case Rigd.Cmd.out("ps", ["-axo", "pid=,ppid=,command="]) do
      nil ->
        []

      out ->
        for line <- String.split(out, "\n", trim: true),
            [pid, ppid, cmd] <- [String.split(String.trim_leading(line), ~r/\s+/, parts: 3)],
            do: {String.to_integer(pid), String.to_integer(ppid), cmd}
    end
  end

  defp ship_pids do
    for file <- Path.wildcard(Path.expand("~/.cache/shipyard/*/worker.pid")),
        {pid, _} <- [file |> File.read!() |> String.trim() |> Integer.parse()],
        do: {file |> Path.dirname() |> Path.basename(), pid}
  end
end
