defmodule Tidy.CLITest do
  use ExUnit.Case, async: true

  import Tidy.CLI, only: [plan: 1]

  @all ~w(worktrees branches databases processes simulators)

  test "no arguments reports every section" do
    assert plan([]) == {:ok, for(s <- @all, do: {s, :report})}
  end

  test "a mode with no section after it means every section" do
    assert plan(["prune"]) == {:ok, for(s <- @all, do: {s, :prune})}
  end

  test "sections without a mode are reported" do
    assert plan(["worktrees"]) == {:ok, [{"worktrees", :report}]}
  end

  test "a mode applies to the sections after it, and the first mention of one wins" do
    assert plan(~w(report worktrees simulators prune databases processes worktrees)) ==
             {:ok,
              [
                {"worktrees", :report},
                {"simulators", :report},
                {"databases", :prune},
                {"processes", :prune}
              ]}
  end

  test "an unknown word is a usage error" do
    assert {:usage, "unknown argument \"tidy\""} = plan(["prune", "tidy"])
  end
end
