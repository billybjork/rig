defmodule Rigd.Closed do
  @moduledoc """
  The palette's "Recently Closed" (`rex/closed.lua`, `bin/closed`): Rex's
  tabs are compared with the last look at them, and a tab or pane that is
  gone is appended to `~/.local/state/rig/closed.jsonl`, one JSON line each,
  newest last. A line holds what reopening it needs: its session, its tab's
  label, and each pane's directory, title, and Claude Code session (with
  whether it skipped permissions), read from `~/.claude/sessions/<pid>.json`
  while the agent still runs.

  A pane that leaves its tab without closing (Background: Hide, a move to
  another tab) is not closed. A look on which Rex could not be read is
  skipped, so an outage does not read as every tab closing.

  Rex is looked at on each Activity tick and also as soon as a tab or pane
  opens or closes (`priv/events.lua`, run with `rex do --all`), since a tab
  open for less than a tick falls between two ticks. Two looks can arrive
  out of order, so a pane once recorded is never recorded again.
  """

  use GenServer
  require Logger

  @keep 200
  # Events come in bursts (a tab closing closes its panes): one look each.
  @settle 150

  def path, do: Path.expand("~/.local/state/rig/closed.jsonl")

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    Rigd.Bus.subscribe(:activity)
    File.mkdir_p!(Path.dirname(path()))
    send(self(), :listen)
    {:ok, %{tabs: nil, claude: %{}, written: MapSet.new(), events: nil, look: nil}}
  end

  @impl true
  def handle_info({:activity, %{rex_ok: false}}, st), do: {:noreply, st}
  def handle_info({:activity, a}, st), do: {:noreply, look(a.tabs, a.blocks, st)}

  def handle_info(:listen, st) do
    script = Path.join(:code.priv_dir(:rigd), "events.lua")

    case System.find_executable("rex") do
      nil ->
        Process.send_after(self(), :listen, :timer.seconds(30))
        {:noreply, st}

      rex ->
        port =
          Port.open({:spawn_executable, rex}, [
            :binary,
            :exit_status,
            {:line, 1024},
            args: ["--autostart=false", "do", "--all", script]
          ])

        {:noreply, %{st | events: port}}
    end
  end

  def handle_info({port, {:data, _}}, %{events: port} = st) do
    {:noreply, %{st | look: st.look || Process.send_after(self(), :look, @settle)}}
  end

  # Rex restarted or went away: listen again shortly, and meanwhile ticks.
  def handle_info({port, {:exit_status, status}}, %{events: port} = st) do
    Logger.info("closed: event listener exited #{status}; again in 10 s")
    Process.send_after(self(), :listen, :timer.seconds(10))
    {:noreply, %{st | events: nil}}
  end

  def handle_info(:look, st) do
    st = %{st | look: nil}

    case Rigd.Rex.snapshot() do
      {:ok, sessions} ->
        {:noreply, look(Rigd.Activity.tabs(sessions), Rigd.Activity.blocks(sessions), st)}

      {:error, _} ->
        {:noreply, st}
    end
  end

  def handle_info(_, st), do: {:noreply, st}

  defp look(tabs, blocks, st) do
    claude = claude_sessions(tabs, st.claude)
    tabs = for t <- tabs, do: %{t | panes: Enum.map(t.panes, &with_claude(&1, claude))}

    gone = if st.tabs, do: st.tabs |> closed(tabs, blocks) |> unseen(st.written), else: []
    if gone != [], do: write(gone, DateTime.utc_now() |> DateTime.truncate(:second))

    written =
      gone
      |> Enum.flat_map(fn g -> Enum.map(g.panes, & &1.block) end)
      |> Enum.into(st.written)
      |> forget_old()

    %{st | tabs: tabs, claude: claude, written: written}
  end

  # Block IDs are never reused, so any old ones may go; enough are kept to
  # outlast a look that arrives late.
  defp forget_old(written) do
    if MapSet.size(written) > 1000, do: MapSet.new(Enum.take(written, -500)), else: written
  end

  @doc """
  What closed between two lists of tabs, given every block Rex still has: a
  tab that is gone (`kind: "tab"`, its panes that closed with it), and for a
  tab still open, the panes that closed in it (`kind: "pane"`).
  """
  def closed(prev, tabs, blocks) do
    open = MapSet.new(tabs, & &1.window_id)

    for t <- prev,
        panes = Enum.reject(t.panes, &MapSet.member?(blocks, &1.block)),
        panes != [] do
      kind = if MapSet.member?(open, t.window_id), do: "pane", else: "tab"
      t |> Map.put(:kind, kind) |> Map.put(:panes, panes)
    end
  end

  @doc "`closed/3`'s records without the panes already recorded."
  def unseen(gone, written) do
    for g <- gone,
        panes = Enum.reject(g.panes, &MapSet.member?(written, &1.block)),
        panes != [],
        do: %{g | panes: panes}
  end

  # pid => %{id, skip_permissions} for every Claude Code agent in a tab. The
  # session file is read every tick, since /clear starts a new session in
  # the same process; whether it skips permissions is read once per pid.
  defp claude_sessions(tabs, known) do
    for t <- tabs,
        p <- t.panes,
        p.app == "claude-code",
        p.pid,
        id = session_id(p.pid),
        into: %{} do
      skip =
        case known[p.pid] do
          %{skip_permissions: skip} -> skip
          nil -> skips_permissions?(p.pid)
        end

      {p.pid, %{id: id, skip_permissions: skip}}
    end
  end

  defp session_id(pid) do
    with {:ok, body} <- File.read(Path.expand("~/.claude/sessions/#{pid}.json")),
         {:ok, %{"sessionId" => id}} <- JSON.decode(body),
         do: id,
         else: (_ -> nil)
  end

  defp skips_permissions?(pid) do
    args = Rigd.Cmd.out("ps", ["-o", "args=", "-p", to_string(pid)]) || ""
    String.contains?(args, "--dangerously-skip-permissions")
  end

  defp with_claude(pane, claude) do
    case pane.pid && claude[pane.pid] do
      nil -> pane
      c -> Map.merge(pane, %{claude_session: c.id, skip_permissions: c.skip_permissions})
    end
  end

  defp write(gone, at) do
    lines =
      for g <- gone do
        id = if g.kind == "tab", do: g.window_id, else: hd(g.panes).block

        %{
          id: id,
          at: DateTime.to_iso8601(at),
          kind: g.kind,
          session_id: g.session_id,
          session: g.session,
          label: g.label,
          panes: for(p <- g.panes, do: Map.drop(p, [:block, :pid]))
        }
        |> JSON.encode!()
      end

    old =
      case File.read(path()) do
        {:ok, body} -> String.split(body, "\n", trim: true)
        _ -> []
      end

    # Appending keeps a line bin/closed writes meanwhile; the file is
    # rewritten only to drop old lines, once it holds twice what it keeps.
    if length(old) + length(lines) > 2 * @keep do
      kept = Enum.take(old ++ lines, -@keep)
      File.write!(path(), Enum.map(kept, &[&1, "\n"]))
    else
      File.write!(path(), Enum.map(lines, &[&1, "\n"]), [:append])
    end

    for g <- gone, do: Logger.info("closed: #{g.session}: #{g.kind} #{describe(g)}")
  rescue
    e -> Logger.warning("closed: could not record #{inspect(gone)}: #{Exception.message(e)}")
  end

  defp describe(g), do: Enum.find_value(g.panes, g.label, & &1.title)
end
