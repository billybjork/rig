defmodule Tidy.DatabasesTest do
  use ExUnit.Case, async: true

  alias Tidy.Databases

  defp names(rows), do: Enum.map(rows, &elem(&1, 0))
  defp rows(names), do: Enum.map(names, &{&1, 8_388_608})

  test "soco: the partition before the suffix" do
    templates = ["soco_test{partition}{suffix}"]
    live = ["", "_claude_live"]

    all =
      rows(~w(soco_test soco_test2 soco_test_claude_live soco_test3_claude_live
              soco_test_claude_gone soco_test12_claude_gone soco_dev soco_dev_claude_gone
              soco_testcollections soco_test_Upper social_objects_test))

    assert names(Databases.orphans(all, templates, live)) ==
             ~w(soco_test_claude_gone soco_test12_claude_gone)
  end

  test "heaters: dev and test, the partition after the suffix, the outbox's too" do
    templates = [
      "heaters_dev{suffix}",
      "heaters_test{suffix}{partition}",
      "heaters_outbox_test{suffix}{partition}"
    ]

    live = ["", "_claude_live"]

    all =
      rows(
        ~w(heaters_dev heaters_test heaters_test4 heaters_dev_claude_live heaters_test_claude_live2
              heaters_outbox_test_claude_live heaters_dev_claude_gone heaters_test_claude_gone3
              heaters_outbox_test_claude_gone heaters_template_20261101t2226z heaters_dev2)
      )

    assert names(Databases.orphans(all, templates, live)) ==
             ~w(heaters_dev_claude_gone heaters_test_claude_gone3 heaters_outbox_test_claude_gone)
  end

  test "a template's literal parts are not regex" do
    assert Databases.orphans(rows(["aXb_x"]), ["a.b{suffix}"], [""]) == []
    assert names(Databases.orphans(rows(["a.b_x"]), ["a.b{suffix}"], [""])) == ["a.b_x"]
  end

  describe "a checkout's suffix" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "tidy-db-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(tmp) end)
      %{tmp: tmp}
    end

    # soco's rule: a `.git` file is a linked worktree; `root:` is bound.
    @by_root ~S"""
    root = Keyword.get(binding(), :root) || File.cwd!()
    if File.regular?(Path.join(root, ".git")), do: {"_" <> Path.basename(root), 1}, else: {"", 0}
    """

    # heaters' rule: the directory's name, read from the cwd.
    @by_cwd ~S"""
    case Path.basename(File.cwd!()) do
      "proj" -> {"", 0}
      name -> {"_" <> String.downcase(name), 7}
    end
    """

    test "is the workspace file evaluated in the checkout, bound to root or by its cwd", %{
      tmp: tmp
    } do
      for {rule, expect} <- [{@by_root, "_wt"}, {@by_cwd, "_wt"}] do
        primary = Path.join(tmp, "proj")
        linked = Path.join(tmp, "wt")
        File.mkdir_p!(Path.join(primary, "config"))
        File.mkdir_p!(Path.join(primary, ".git"))
        File.mkdir_p!(linked)
        File.write!(Path.join(linked, ".git"), "gitdir: x\n")
        File.write!(Path.join(primary, "config/workspace.exs"), rule)
        config = %Tidy.Config{primary: primary, workspace: "config/workspace.exs"}

        # The linked checkout has no workspace file of its own: the primary's.
        assert Databases.suffix(config, primary) == {:ok, ""}
        assert Databases.suffix(config, linked) == {:ok, expect}
        File.rm_rf!(tmp)
      end
    end

    test "a checkout's own workspace file wins, and one that fails stops the sweep", %{tmp: tmp} do
      primary = Path.join(tmp, "proj")
      linked = Path.join(tmp, "wt")
      File.mkdir_p!(Path.join(primary, "config"))
      File.mkdir_p!(Path.join(linked, "config"))
      File.write!(Path.join(primary, "config/workspace.exs"), ~S|{"", 0}|)
      File.write!(Path.join(linked, "config/workspace.exs"), ~S|raise "broken"|)

      config = %Tidy.Config{
        primary: primary,
        workspace: "config/workspace.exs",
        databases: ["x{suffix}"]
      }

      assert {:error, "config/workspace.exs failed in " <> _} = Databases.suffix(config, linked)

      porcelain = "worktree #{primary}\nHEAD a\n\nworktree #{linked}\nHEAD b\n"
      env = %{git: fn _ -> {porcelain, 0} end, suffix: &Databases.suffix/2}

      assert ["databases left alone: config/workspace.exs failed in " <> _] =
               Databases.run(config, :prune, env)
    end
  end
end
