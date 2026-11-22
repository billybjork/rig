defmodule Rigd.Open do
  @moduledoc """
  What is open in Rex, kept on disk so it can be restored once Rex restarts
  (a reboot, a crash), for the palette's "Restore Sessions" (`rex/restore.lua`,
  `bin/restore`).

  Closed publishes each look at Rex's tabs as `{:tabs, tabs}`, with each
  Claude pane's session. They are written to `~/.local/state/rig/open.json`:
  every session by label, its tabs in order, and each tab's split layout
  with each pane's directory, title, and Claude session (with whether it
  skipped permissions). The file is rewritten only when that changes, and
  only once the change has held for 20 s, so the tabs
  closing while the Mac shuts down are never written over what was open.

  When the file was written under another Rex server instance (Rex
  restarted since), it moves to `~/.local/state/rig/previous/` before the
  first write under this one; the last 5 are kept, and those are what
  "Restore Sessions" offers. A look at a Rex with no tabs writes nothing.

  Rex restarting brings the set back by itself (`restore?/4`): on the first
  look at a new server instance, when that server started within the last
  5 minutes and is still as Rex opens it (one tab, no agent in it), the file
  moves aside at once and `bin/restore open` runs on it. Moving it is what
  keeps a set from being restored twice. A Rex that already shows more (its
  own restore, tabs Billy opened) is left alone, and "Restore Sessions"
  offers the set instead. Two minutes on, the Claude panes that did not
  come back (`bin/restore check`) are logged and raised in a notification.
  """

  use GenServer
  require Logger

  @settle 20_000
  @keep 5
  # How new a server must be for its first look to restore by itself, and how
  # long resumed agents get to start before the check.
  @fresh_for 300
  @check_after :timer.minutes(2)

  def dir, do: Path.expand("~/.local/state/rig")
  def path, do: Path.join(dir(), "open.json")
  def previous, do: Path.join(dir(), "previous")
  def restore_bin, do: Path.expand("~/dev/rig/bin/restore")

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    Rigd.Bus.subscribe(:tabs)
    File.mkdir_p!(previous())
    {:ok, %{saved: comparable(read(path())), pending: nil, instance: nil}}
  end

  @impl true
  def handle_info({:tabs, tabs}, st) do
    st = first_look(tabs, st)
    {:noreply, consider(snapshot(tabs), System.monotonic_time(:millisecond), st)}
  end

  def handle_info(_, st), do: {:noreply, st}

  @doc """
  The next state given a fresh snapshot at monotonic time `now` (ms): a
  snapshot is written once it is different from what was saved and has been
  seen unchanged for the settle time.
  """
  def consider(snap, now, st) do
    case st.pending do
      _ when snap == st.saved or snap == nil ->
        %{st | pending: nil}

      {^snap, since} when now - since >= @settle ->
        write(snap)
        %{st | saved: snap, pending: nil}

      {^snap, _} ->
        st

      _ ->
        %{st | pending: {snap, now}}
    end
  end

  # Once per server instance: restore what was open under the last one, when
  # restore?/4 says so.
  defp first_look([%{server: %{"instance_id" => id} = server} | _] = tabs, st)
       when is_binary(id) and id != st.instance do
    st = %{st | instance: id}
    saved = read(path())

    if restore?(saved, tabs, server, DateTime.utc_now()) do
      file = keep_aside(saved)
      Task.start(fn -> restore(file) end)
      %{st | saved: nil, pending: nil}
    else
      st
    end
  rescue
    e ->
      Logger.warning("open: could not restore after Rex restarted: #{Exception.message(e)}")
      %{st | instance: id}
  end

  defp first_look(_tabs, st), do: st

  @doc """
  Whether the first look at a server restores the set saved under the last
  one by itself: the saved set holds tabs from another instance, this
  server started within #{@fresh_for} s of `now`, and it shows what Rex
  opens on a fresh start (at most one tab, no agent in it).
  """
  def restore?(saved, tabs, server, now) do
    rotate?(saved, %{"server" => server["instance_id"]}) and
      fresh_start?(server["started_at"], now) and
      length(tabs) <= 1 and
      Enum.all?(tabs, fn t -> Enum.all?(t.panes, &(&1.app == nil)) end)
  end

  defp fresh_start?(started, now) when is_binary(started) do
    case DateTime.from_iso8601(started) do
      {:ok, at, _} -> DateTime.diff(now, at) in -60..@fresh_for
      _ -> false
    end
  end

  defp fresh_start?(_, _), do: false

  defp restore(file) do
    Logger.info("open: Rex restarted; restoring #{Path.basename(file)}")
    {out, status} = Rigd.Cmd.run(restore_bin(), ["open", file], timeout: 180)
    Logger.info("open: restore exited #{status}: #{String.trim(out)}")

    Process.sleep(@check_after)

    case Rigd.Cmd.run(restore_bin(), ["check", file], timeout: 30) do
      {"", 0} ->
        Logger.info("open: every restored Claude session is running")

      {out, 0} ->
        missing = String.split(out, "\n", trim: true)

        Logger.warning(
          "open: Claude sessions that did not come back: #{Enum.join(missing, "; ")}"
        )

        notify("#{length(missing)} Claude session(s) did not come back", Enum.join(missing, ", "))

      {out, status} ->
        Logger.warning("open: restore check exited #{status}: #{String.slice(out, 0, 300)}")
    end
  end

  # A macOS notification: Billy is at the Mac when Rex comes back.
  defp notify(title, body) do
    script = "display notification (item 2 of argv) with title (item 1 of argv)"
    Rigd.Cmd.run("osascript", ["-e", "on run argv", "-e", script, "-e", "end run", title, body])
  end

  @doc """
  What to save from Closed's tabs, with string keys as it reads back from
  the file, or nil when Rex has no tabs: sessions in Rex's order, each with
  its tabs, each tab's layout a tree of `%{"split" => ...}` and pane maps.
  """
  def snapshot([]), do: nil

  def snapshot(tabs) do
    server = hd(tabs).server || %{}

    sessions =
      tabs
      |> Enum.chunk_by(& &1.session_id)
      |> Enum.map(fn [t | _] = ts ->
        %{"session" => t.session, "tabs" => Enum.flat_map(ts, &tab/1)}
      end)

    %{
      "server" => server["instance_id"],
      "server_started" => server["started_at"],
      "sessions" => sessions
    }
  end

  defp tab(t) do
    panes = Map.new(t.panes, &{&1.block, pane(&1)})

    case layout(t.layout, panes) || row(Enum.map(t.panes, &pane/1)) do
      nil -> []
      layout -> [%{"label" => t.label, "layout" => layout}]
    end
  end

  # A layout node that names a block not among the tab's terminals (another
  # kind of block) is dropped, and a split left with one side becomes it.
  defp layout(%{"split" => s}, panes) do
    case {layout(s["before"], panes), layout(s["after"], panes)} do
      {nil, other} ->
        other

      {other, nil} ->
        other

      {b, a} ->
        %{
          "split" => %{
            "direction" => s["direction"],
            "ratio" => s["ratio"],
            "before" => b,
            "after" => a
          }
        }
    end
  end

  defp layout(%{"block" => id}, panes), do: panes[id]
  defp layout(_, _), do: nil

  # A tab whose layout Rex did not give: its panes side by side.
  defp row([]), do: nil
  defp row([p]), do: p

  defp row([p | rest] = all),
    do: %{
      "split" => %{
        "direction" => "horizontal",
        "ratio" => 1 / length(all),
        "before" => p,
        "after" => row(rest)
      }
    }

  defp pane(p) do
    for {k, v} <- Map.take(p, [:cwd, :title, :app, :claude_session, :skip_permissions]),
        v != nil,
        into: %{},
        do: {Atom.to_string(k), v}
  end

  @doc "Whether the saved file `old` must move aside before `new` is written."
  def rotate?(nil, _new), do: false

  def rotate?(old, new),
    do: old["server"] != new["server"] and Enum.any?(old["sessions"] || [], &(&1["tabs"] != []))

  defp write(snap) do
    old = read(path())

    if rotate?(old, snap), do: keep_aside(old)

    at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    tmp = path() <> ".tmp"
    File.write!(tmp, JSON.encode!(Map.put(snap, "at", at)))
    File.rename!(tmp, path())
  rescue
    e -> Logger.warning("open: could not save what is open: #{Exception.message(e)}")
  end

  # The saved file moved to previous/, named for when it was written; its new
  # path.
  defp keep_aside(old) do
    name = (old["at"] || "unknown") |> String.replace(":", "-")
    file = Path.join(previous(), "#{name}.json")
    File.rename!(path(), file)
    prune()
    Logger.info("open: kept the sessions from before Rex restarted (#{name})")
    file
  end

  defp prune do
    previous()
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.sort(:desc)
    |> Enum.drop(@keep)
    |> Enum.each(&File.rm(Path.join(previous(), &1)))
  end

  defp read(file) do
    with {:ok, body} <- File.read(file),
         {:ok, %{} = m} <- JSON.decode(body),
         do: m,
         else: (_ -> nil)
  end

  defp comparable(nil), do: nil
  defp comparable(m), do: Map.delete(m, "at")
end
