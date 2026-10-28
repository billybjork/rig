defmodule Rigd.Status do
  @moduledoc """
  What rigd knows, written to `~/Library/Caches/rigd/status.json` as it
  changes, for `bin/rigd status`.
  """

  use GenServer

  def path, do: Path.expand("~/Library/Caches/rigd/status.json")

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    for topic <- [:activity, :presence, :awake], do: Rigd.Bus.subscribe(topic)
    File.mkdir_p!(Path.dirname(path()))
    {:ok, %{written: nil, activity: nil, presence: nil, awake: nil}}
  end

  @impl true
  def handle_info({:activity, a}, st) do
    running = for {_, item} <- Enum.sort(a.items), do: item.label

    agents =
      for x <- a.agents, do: "#{x.session}: #{x.app} #{x.state} (#{x.title || x.window_label})"

    write(%{st | activity: %{running: running, agents: agents, rex_ok: a.rex_ok}})
  end

  def handle_info({:presence, p}, st),
    do: write(%{st | presence: Map.drop(p, [:lid_closed_since, :idle_s])})

  def handle_info({:awake, w}, st), do: write(%{st | awake: w})

  defp write(st) do
    doc = Map.take(st, [:activity, :presence, :awake])

    if doc != st.written do
      json = JSON.encode!(Map.put(doc, :pid, System.pid()))
      File.write!(path() <> ".tmp", json)
      File.rename!(path() <> ".tmp", path())
    end

    {:noreply, %{st | written: doc}}
  end
end
