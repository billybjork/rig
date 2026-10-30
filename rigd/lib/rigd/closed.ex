defmodule Rigd.Closed do
  @moduledoc """
  The palette's "Recently Closed" (`rex/closed.lua`, `bin/closed`): each
  Activity's tabs are compared with the last, and a tab or pane that is gone
  is appended to `~/.local/state/rig/closed.jsonl`, one JSON line each,
  newest last. A line holds what reopening it needs: its session, its tab's
  label, and each pane's directory, title, and Claude Code session (with
  whether it skipped permissions), read from `~/.claude/sessions/<pid>.json`
  while the agent still runs.

  A pane that leaves its tab without closing (Background: Hide, a move to
  another tab) is not closed. A tick on which Rex could not be read is
  skipped, so an outage does not read as every tab closing.
  """

  use GenServer
  require Logger

  @keep 200

  def path, do: Path.expand("~/.local/state/rig/closed.jsonl")

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    Rigd.Bus.subscribe(:activity)
    File.mkdir_p!(Path.dirname(path()))
    {:ok, %{tabs: nil, claude: %{}}}
  end

  @impl true
  def handle_info({:activity, %{rex_ok: false}}, st), do: {:noreply, st}

  def handle_info({:activity, a}, st) do
    claude = claude_sessions(a.tabs, st.claude)
    tabs = for t <- a.tabs, do: %{t | panes: Enum.map(t.panes, &with_claude(&1, claude))}

    if st.tabs do
      case closed(st.tabs, tabs, a.blocks) do
        [] -> :ok
        gone -> write(gone, DateTime.utc_now() |> DateTime.truncate(:second))
      end
    end

    {:noreply, %{st | tabs: tabs, claude: claude}}
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
