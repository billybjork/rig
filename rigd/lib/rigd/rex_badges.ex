defmodule Rigd.RexBadges do
  @moduledoc """
  The ⚙ mark: a tab whose agent is idle while one of its background shells
  still runs gets its label prefixed with "⚙ " until the shell exits. Rex
  shows only that the agent is idle; this says it still has work going.
  Driven by Activity; it replaced the `rex do` watcher
  `com.billy.rex-bg-shells`.

  A tab Billy renames while marked keeps his name once the mark goes.
  """

  use GenServer
  require Logger

  @mark "⚙ "

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  The tabs to mark: window id to the title of its idle agent that owns a
  live background shell (the title names an unnamed tab).
  """
  def busy(agents, shell_owners) do
    for a <- agents,
        a.window_id != nil,
        a.state not in ["working", "blocked"],
        a.pid in shell_owners,
        reduce: %{} do
      acc -> Map.put_new(acc, a.window_id, a.title)
    end
  end

  @doc """
  The label changes that bring the tabs in line with `busy`, as
  `{session_id, window_id, label}`, and the marks kept afterwards
  (`window_id => %{original, set}`).
  """
  def plan(windows, busy, marked) do
    {changes, kept} =
      Enum.reduce(windows, {[], %{}}, fn w, {changes, kept} ->
        m = marked[w.window_id]

        # someone renamed the tab while it was marked: keep their name
        m =
          if m && w.label != m.set,
            do: %{m | original: String.replace_prefix(w.label, @mark, "")},
            else: m

        case {Map.fetch(busy, w.window_id), m} do
          {{:ok, title}, _} ->
            original = if m, do: m.original, else: w.label
            want = @mark <> if(default?(original), do: title || original, else: original)

            changes =
              if w.label != want, do: [{w.session_id, w.window_id, want} | changes], else: changes

            {changes, Map.put(kept, w.window_id, %{original: original, set: want})}

          {:error, nil} ->
            {changes, kept}

          {:error, m} ->
            {[
               {w.session_id, w.window_id, if(default?(m.original), do: "", else: m.original)}
               | changes
             ], kept}
        end
      end)

    {Enum.reverse(changes), kept}
  end

  defp default?(label), do: label in [nil, ""] or label =~ ~r/^Window [0-9a-f]+$/

  @impl true
  def init(nil) do
    Rigd.Bus.subscribe(:activity)
    {:ok, %{marked: nil}}
  end

  @impl true
  def handle_info({:activity, %{rex_ok: false}}, st), do: {:noreply, st}

  def handle_info({:activity, a}, st) do
    # First look: marks left by an earlier run are ours
    # to clear.
    marked =
      st.marked ||
        for w <- a.windows,
            String.starts_with?(w.label, @mark),
            into: %{},
            do: {w.window_id, %{original: "", set: w.label}}

    {changes, marked} = plan(a.windows, busy(a.agents, a.shell_owners), marked)

    for {sid, wid, label} <- changes do
      Logger.info("badges: #{wid} -> #{if label == "", do: "(default)", else: label}")
      Rigd.Rex.set_window_label(sid, wid, label)
    end

    {:noreply, %{st | marked: marked}}
  end
end
