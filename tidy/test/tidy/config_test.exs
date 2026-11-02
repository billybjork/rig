defmodule Tidy.ConfigTest do
  use ExUnit.Case, async: true

  alias Tidy.Config

  test "defaults: landed on origin/main, no branches, no databases" do
    assert {:ok, %Config{landed: :ancestor, branches: nil, databases: []}} =
             Config.from_map(%{}, "/p", "/p")
  end

  test "merged-pr, and the regexes compile" do
    assert {:ok, %Config{landed: :merged_pr, branches: re}} =
             Config.from_map(%{"landed" => "merged-pr", "branches" => "^[a-z]+/"}, "/p", "/p")

    assert Regex.match?(re, "claude/x")
  end

  test "a field tidy does not know is refused, not ignored" do
    assert {:error, ".tidy.json: unknown field(s) landing"} =
             Config.from_map(%{"landing" => "merged-pr"}, "/p", "/p")
  end

  test "landed takes only its two rules" do
    assert {:error, ".tidy.json: landed is " <> _} =
             Config.from_map(%{"landed" => "main"}, "/p", "/p")
  end

  test "databases need the workspace file and the postgres command" do
    assert {:error, ".tidy.json: databases need workspace"} =
             Config.from_map(%{"databases" => ["x{suffix}"]}, "/p", "/p")

    assert {:error, ".tidy.json: databases need postgres"} =
             Config.from_map(%{"databases" => ["x{suffix}"], "workspace" => "w.exs"}, "/p", "/p")
  end
end
