defmodule Rigd.NotifyTest do
  use ExUnit.Case, async: true
  alias Rigd.Notify

  defp agent(block, state, app \\ "claude-code"), do: %{block: block, state: state, app: app}

  test "an agent that stops working or becomes blocked is scheduled; working again cancels" do
    prev = %{
      "a" => "working",
      "b" => "working",
      "c" => "idle",
      "d" => "blocked",
      "f" => "working"
    }

    agents = [
      agent("a", "idle"),
      agent("b", "blocked"),
      agent("c", "working"),
      agent("d", "blocked"),
      agent("e", "done")
    ]

    assert Notify.transitions(prev, agents) == [
             {:schedule, "a", :done},
             {:schedule, "b", :blocked},
             {:cancel, "c"}
           ]
  end

  test "a push holds only while the state that scheduled it does" do
    assert Notify.still?(:done, "idle")
    refute Notify.still?(:done, "working")
    assert Notify.still?(:blocked, "blocked")
    refute Notify.still?(:blocked, "idle")
  end

  test "a due push goes only while it is the latest, its agent is there, and Billy is away" do
    ref = make_ref()
    st = %{agents: %{"a" => %{state: "idle"}}, pending: %{"a" => ref}, away: true}

    assert Notify.fire?(st, "a", :done, ref)
    refute Notify.fire?(st, "a", :done, make_ref())
    refute Notify.fire?(%{st | away: false}, "a", :done, ref)
    # Its pane closed before the push was due.
    refute Notify.fire?(%{st | agents: %{}}, "a", :done, ref)
  end

  test "names the session and the tab" do
    a = %{
      session: "soco",
      app: "claude-code",
      title: "Fix the gate",
      window_label: "Window 1",
      msg: "Allow Bash?"
    }

    assert Notify.message(:done, a) == {"soco: claude-code finished", "Fix the gate"}

    assert Notify.message(:blocked, a) ==
             {"soco: claude-code needs you", "Fix the gate: Allow Bash?"}
  end
end
