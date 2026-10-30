defmodule Rigd.ClosedTest do
  use ExUnit.Case, async: true
  alias Rigd.Closed

  defp pane(id), do: %{block: id, cwd: "/dev/rig", title: "Pane #{id}", app: nil, pid: nil}

  defp tab(id, panes),
    do: %{session_id: "s", session: "dev", window_id: id, label: "", panes: panes}

  test "a tab that is gone is closed with its panes" do
    prev = [tab("w1", [pane("b1"), pane("b2")]), tab("w2", [pane("b3")])]
    now = [tab("w2", [pane("b3")])]

    assert [%{kind: "tab", window_id: "w1", panes: [%{block: "b1"}, %{block: "b2"}]}] =
             Closed.closed(prev, now, MapSet.new(["b3"]))
  end

  test "a pane closed in a tab still open is closed alone" do
    prev = [tab("w1", [pane("b1"), pane("b2")])]
    now = [tab("w1", [pane("b1")])]

    assert [%{kind: "pane", window_id: "w1", panes: [%{block: "b2"}]}] =
             Closed.closed(prev, now, MapSet.new(["b1"]))
  end

  test "a pane hidden in the background or moved to another tab has not closed" do
    prev = [tab("w1", [pane("b1"), pane("b2")]), tab("w2", [pane("b3")])]
    now = [tab("w1", [pane("b1")])]

    assert Closed.closed(prev, now, MapSet.new(["b1", "b2", "b3"])) == []
  end

  test "nothing changed, nothing closed" do
    tabs = [tab("w1", [pane("b1")])]
    assert Closed.closed(tabs, tabs, MapSet.new(["b1"])) == []
  end
end
