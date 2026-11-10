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
  """

  use GenServer
  require Logger

  @settle 20_000
  @keep 5

  def dir, do: Path.expand("~/.local/state/rig")
  def path, do: Path.join(dir(), "open.json")
  def previous, do: Path.join(dir(), "previous")

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    Rigd.Bus.subscribe(:tabs)
    File.mkdir_p!(previous())
    {:ok, %{saved: comparable(read(path())), pending: nil}}
  end

  @impl true
  def handle_info({:tabs, tabs}, st) do
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

    if rotate?(old, snap) do
      name = (old["at"] || "unknown") |> String.replace(":", "-")
      File.rename!(path(), Path.join(previous(), "#{name}.json"))
      prune()
      Logger.info("open: kept the sessions from before Rex restarted (#{name})")
    end

    at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    tmp = path() <> ".tmp"
    File.write!(tmp, JSON.encode!(Map.put(snap, "at", at)))
    File.rename!(tmp, path())
  rescue
    e -> Logger.warning("open: could not save what is open: #{Exception.message(e)}")
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
