defmodule Rigd.ActivityTest do
  use ExUnit.Case, async: true
  alias Rigd.Activity

  @sessions [
    %{
      "id" => "s1",
      "label" => "soco",
      "windows" => [
        %{
          "id" => "w1",
          "label" => "Window 1",
          "blocks" => [
            %{
              "id" => "b1",
              "title" => "Gate",
              "agent" => %{"app" => "claude-code", "state" => "idle", "pid" => 100}
            },
            %{
              "id" => "b2",
              "title" => "Docs",
              "agent" => %{"app" => "claude-code", "state" => "working", "pid" => 200}
            },
            %{"id" => "b3"}
          ]
        }
      ],
      "detached" => [
        %{"id" => "d1", "label" => "dev server", "running" => true},
        %{"id" => "d2", "label" => "ship #371", "running" => false}
      ]
    }
  ]

  @procs [
    {100, 1, "claude"},
    {101, 100, "/bin/zsh -c source /Users/b/.claude/shell-snapshots/snapshot-zsh.sh && mix test"},
    {300, 1, "beam.smp shipyard"}
  ]

  test "what runs: working agents, agents' shells, running background terminals, live ship workers" do
    a = Activity.build(@sessions, @procs, [{"soco", 300}, {"heaters", 999}])

    assert Map.keys(a.items) |> Enum.sort() ==
             Enum.sort([{:agent, "b2"}, {:shell, 101}, {:bg, "d1"}, {:ship, "soco"}])

    assert a.items[{:shell, 101}].label == "soco: an agent's background shell"
    assert a.shell_owners == MapSet.new([100])
    assert [%{block: "b1", state: "idle", window_id: "w1"}, %{block: "b2"}] = a.agents
    assert a.windows == [%{session_id: "s1", window_id: "w1", label: "Window 1"}]
  end
end
