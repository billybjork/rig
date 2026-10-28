defmodule Rigd.Notify do
  @moduledoc """
  While Billy is away (Presence), one ntfy push per finished task on one
  topic: an agent that stops working (after 20s, so a turn that resumes
  sends nothing), or one that waits on him (blocked for 15s). While he is
  present it sends nothing; Rex's own marks show it. Ships push from the ship
  worker, which reads Presence from the status file (`Rigd.Status`).

  The topic is `NTFY_TOPIC` from rigd's `fnox.toml` (deploy tier); it never
  enters rigd: each push runs curl under `fnox exec`. Without it, rigd logs
  the push it would have sent.
  """

  use GenServer
  require Logger

  # Programs that report status to Rex as agents; the ship worker reports
  # as `shipyard` and pushes its own.
  @agents ~w(claude-code codex)

  @delay %{done: :timer.seconds(20), blocked: :timer.seconds(15)}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  What a new Activity means for the pushes: `{:schedule, block, kind}` for an
  agent that just stopped working or just became blocked, `{:cancel, block}`
  for one working again. `prev` maps each agent's block to its last state.
  """
  def transitions(prev, agents) do
    agents
    |> Enum.filter(&(&1.app in @agents))
    |> Enum.flat_map(fn a ->
      was = prev[a.block]

      cond do
        a.state == "working" and was != "working" -> [{:cancel, a.block}]
        a.state == "blocked" and was != "blocked" -> [{:schedule, a.block, :blocked}]
        was == "working" and a.state != "working" -> [{:schedule, a.block, :done}]
        true -> []
      end
    end)
  end

  @doc "Whether a scheduled push still holds once its delay has passed."
  def still?(:done, state), do: state not in ["working", "blocked"]
  def still?(:blocked, state), do: state == "blocked"

  @doc """
  Whether the push scheduled as `ref` goes: still the latest for its block,
  its agent still there and in the state it was scheduled for, and Billy away.
  """
  def fire?(st, block, kind, ref) do
    agent = st.agents[block]
    st.pending[block] == ref and agent != nil and still?(kind, agent.state) and st.away
  end

  def message(:done, a), do: {"#{a.session}: #{a.app} finished", where(a)}

  def message(:blocked, a),
    do:
      {"#{a.session}: #{a.app} needs you",
       String.slice("#{where(a)}: #{a.msg || "waiting"}", 0, 200)}

  defp where(a), do: a.title || a.window_label || "a background terminal"

  @impl true
  def init(nil) do
    Rigd.Bus.subscribe(:activity)
    Rigd.Bus.subscribe(:presence)
    {:ok, %{agents: %{}, pending: %{}, away: false}}
  end

  @impl true
  def handle_info({:presence, p}, st), do: {:noreply, %{st | away: p.away}}

  def handle_info({:activity, a}, st) do
    prev = Map.new(st.agents, fn {block, agent} -> {block, agent.state} end)

    pending =
      Enum.reduce(transitions(prev, a.agents), st.pending, fn
        {:cancel, block}, pending ->
          cancel(pending, block)

        {:schedule, block, kind}, pending ->
          ref = make_ref()
          Process.send_after(self(), {:fire, block, kind, ref}, @delay[kind])
          Map.put(cancel(pending, block), block, ref)
      end)

    {:noreply, %{st | agents: Map.new(a.agents, &{&1.block, &1}), pending: pending}}
  end

  def handle_info({:fire, block, kind, ref}, st) do
    agent = st.agents[block]

    if fire?(st, block, kind, ref) do
      {title, body} = message(kind, agent)
      Task.start(fn -> push(title, body) end)
    end

    {:noreply,
     %{
       st
       | pending:
           if(st.pending[block] == ref, do: Map.delete(st.pending, block), else: st.pending)
     }}
  end

  defp cancel(pending, block), do: Map.delete(pending, block)

  defp push(title, body) do
    config = Application.fetch_env!(:rigd, :fnox_config)

    script =
      ~S(exec curl -fsS -o /dev/null -m 20 -H "Title: $1" -d "$2" "https://ntfy.sh/$NTFY_TOPIC")

    args = [
      "-c",
      config,
      "-P",
      "deploy",
      "exec",
      "--no-defaults",
      "--",
      "sh",
      "-c",
      script,
      "sh",
      title,
      body
    ]

    case Rigd.Cmd.run("fnox", args, timeout: 60) do
      {_, 0} ->
        Logger.info("notify: pushed #{title}")

      {out, status} ->
        Logger.warning("notify: push '#{title}' failed (#{status}): #{String.slice(out, 0, 200)}")
    end
  end
end
