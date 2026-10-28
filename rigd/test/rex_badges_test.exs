defmodule Rigd.RexBadgesTest do
  use ExUnit.Case, async: true
  alias Rigd.RexBadges

  defp win(id, label), do: %{session_id: "s", window_id: id, label: label}

  test "marks a tab whose idle agent owns a live shell" do
    agents = [
      %{window_id: "w1", state: "idle", pid: 1, title: "Gate"},
      %{window_id: "w2", state: "working", pid: 2, title: "Busy"},
      %{window_id: "w3", state: "idle", pid: 3, title: "Quiet"}
    ]

    assert RexBadges.busy(agents, MapSet.new([1, 2])) == %{"w1" => "Gate"}
  end

  test "an unnamed tab takes the agent's title, a named one keeps its name" do
    {changes, marked} =
      RexBadges.plan(
        [win("w1", "Window 0a1b"), win("w2", "soco")],
        %{"w1" => "Gate", "w2" => "Gate"},
        %{}
      )

    assert changes == [{"s", "w1", "⚙ Gate"}, {"s", "w2", "⚙ soco"}]
    assert marked["w1"] == %{original: "Window 0a1b", set: "⚙ Gate"}
  end

  test "unmarks back to the default or to Billy's name, kept if he renamed it meanwhile" do
    marked = %{
      "w1" => %{original: "Window 0a1b", set: "⚙ Gate"},
      "w2" => %{original: "soco", set: "⚙ soco"}
    }

    {changes, kept} = RexBadges.plan([win("w1", "⚙ Gate"), win("w2", "mine")], %{}, marked)
    assert changes == [{"s", "w1", ""}, {"s", "w2", "mine"}]
    assert kept == %{}
  end

  test "a marked tab that is still busy is left alone; closed tabs are forgotten" do
    marked = %{"w1" => %{original: "soco", set: "⚙ soco"}, "gone" => %{original: "", set: "⚙ x"}}

    assert {[], %{"w1" => _} = kept} =
             RexBadges.plan([win("w1", "⚙ soco")], %{"w1" => "T"}, marked)

    refute Map.has_key?(kept, "gone")
  end
end
