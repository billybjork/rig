defmodule Tidy.WorktreesTest do
  use ExUnit.Case, async: true

  alias Tidy.{Branches, Config, Worktrees}

  # A primary checkout cloned from a bare origin, worktrees under
  # .worktrees/ in every state, and agent branches without a worktree.
  setup do
    tmp = Path.join(System.tmp_dir!(), "tidy-wt-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    # git reports real paths (/private/var, not /var), as Config.load sees them.
    tmp = String.trim(elem(System.cmd("pwd", ["-P"], cd: tmp), 0))
    origin = Path.join(tmp, "origin.git")
    primary = Path.join(tmp, "proj")

    git(tmp, ~w(init -q --bare -b main #{origin}))
    git(tmp, ~w(clone -q #{origin} #{primary}))
    commit(primary, "one")
    git(primary, ~w(push -q origin main))

    wt = fn name, branch ->
      git(primary, ~w(worktree add -q -b #{branch} .worktrees/#{name} origin/main))
    end

    path = &Path.join([primary, ".worktrees", &1])

    # landed: its branch's commit pushed to main
    wt.("landed", "claude/landed")
    commit(path.("landed"), "landed work")
    git(path.("landed"), ~w(push -q origin HEAD:main))
    # ahead: a commit main lacks; dirty: an uncommitted change; locked: landed but in use
    wt.("ahead", "claude/ahead")
    commit(path.("ahead"), "unshipped")
    wt.("dirty", "claude/dirty")
    File.write!(Path.join(path.("dirty"), "new.txt"), "x")
    wt.("locked", "claude/locked")
    git(primary, ~w(worktree lock .worktrees/locked))
    # here: landed, but the checkout tidy runs in
    wt.("here", "claude/here")
    # gone: its directory deleted by hand
    wt.("gone", "claude/gone")
    File.rm_rf!(path.("gone"))

    # Branches without a worktree: landed, unpushed work, and pushed work.
    git(primary, ~w(branch claude/stale origin/main))
    git(primary, ~w(branch claude/mine claude/ahead))
    git(primary, ~w(push -q origin claude/ahead:claude/theirs))
    git(primary, ~w(fetch -q origin))
    git(primary, ~w(branch claude/theirs origin/claude/theirs))
    git(primary, ~w(branch scratch origin/main))

    %{primary: primary, path: path}
  end

  defp env(primary, prs \\ fn _, _ -> nil end),
    do: %{git: &System.cmd("git", &1, cd: primary, stderr_to_stdout: true), prs: prs}

  defp config(primary, here, json \\ %{}) do
    {:ok, c} = Config.from_map(Map.put(json, "branches", "^claude/"), primary, here)
    c
  end

  test "report says what each worktree is and changes nothing", %{primary: p, path: path} do
    lines = Worktrees.run(config(p, path.("here")), :report, env(p))

    # git lists worktrees by path.
    assert lines == [
             ".worktrees/ahead [claude/ahead]: 1 commit(s) not on origin/main; left alone (ship it or remove it deliberately)",
             ".worktrees/dirty [claude/dirty]: 1 uncommitted change(s); left alone. Ship from it, or remove it deliberately",
             ".worktrees/gone: directory missing (git worktree prune clears the entry)",
             ".worktrees/here [claude/here]: landed on origin/main; this session's own checkout, left alone",
             ".worktrees/landed [claude/landed]: landed on origin/main; 'tidy prune' removes it",
             ".worktrees/locked [claude/locked]: landed on origin/main, its session still live; the first prune after it ends removes it"
           ]

    assert File.dir?(path.("landed"))
  end

  test "prune removes only the landed, clean, unlocked worktree, and its branch", %{
    primary: p,
    path: path
  } do
    assert ".worktrees/landed [claude/landed]: landed on origin/main; removed" in Worktrees.run(
             config(p, path.("here")),
             :prune,
             env(p)
           )

    refute File.exists?(path.("landed"))
    branches = git(p, ["branch", "--format=%(refname:short)"])
    refute branches =~ "claude/landed"
    for kept <- ~w(ahead dirty locked here), do: assert(File.dir?(path.(kept)))
    refute git(p, ~w(worktree list)) =~ "gone"
  end

  test "merged-pr: landed only when a merged PR's head is the HEAD", %{primary: p, path: path} do
    head = &String.trim(git(path.(&1), ~w(rev-parse HEAD)))
    base = String.trim(git(p, ~w(rev-parse origin/main)))

    prs = fn
      "claude/landed", :merged -> {7, head.("landed")}
      "claude/ahead", :merged -> {8, base}
      "claude/here", :open -> 9
      _, _ -> nil
    end

    c = config(p, p, %{"landed" => "merged-pr"})
    lines = Worktrees.run(c, :report, env(p, prs))

    assert ".worktrees/landed [claude/landed]: PR #7 merged at its tip; 'tidy prune' removes it" in lines

    assert ".worktrees/ahead [claude/ahead]: PR #8 merged, but 1 commit(s) came after it; left alone" in lines

    assert ".worktrees/here [claude/here]: 0 commit(s) ahead of origin/main, PR #9 open; left alone (ship it or remove it deliberately)" in lines
  end

  test "branches: stale local ones go in prune; pushed work is reported, never deleted", %{
    primary: p,
    path: path
  } do
    c = config(p, path.("here"))

    assert Branches.run(c, :report, env(p)) == [
             "branch claude/mine: 1 commit(s) not on origin/main, no worktree, not pushed; left alone (push it or delete it deliberately)",
             "branch claude/stale: landed on origin/main, no worktree; 'tidy prune' deletes it",
             "origin/claude/theirs: 1 commit(s) not on origin/main; another session's work. Do not duplicate it: its ship lands it, or ship it from a worktree (git worktree add .worktrees/<name> claude/theirs), or ask"
           ]

    assert "branch claude/stale: landed on origin/main; deleted" in Branches.run(
             c,
             :prune,
             env(p)
           )

    branches = git(p, ["branch", "--format=%(refname:short)"])
    refute branches =~ "claude/stale"
    assert branches =~ "claude/mine"
    assert branches =~ "claude/theirs"
    assert branches =~ "scratch"
  end

  test "a checkout without .tidy.json reads the primary's", %{primary: p, path: path} do
    assert {:error, "no .tidy.json in this repository"} = Config.load(path.("ahead"))
    File.write!(Path.join(p, ".tidy.json"), ~s({"landed": "merged-pr"}))

    assert {:ok, %Config{primary: ^p, here: here, landed: :merged_pr}} =
             Config.load(path.("ahead"))

    assert here == path.("ahead")
  end

  test "no branches field, no branch section", %{primary: p} do
    {:ok, c} = Config.from_map(%{}, p, p)
    assert Branches.run(c, :prune, env(p)) == []
  end

  defp commit(dir, msg) do
    File.write!(Path.join(dir, "f.txt"), msg)
    git(dir, ~w(add f.txt))
    git(dir, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", msg])
  end

  defp git(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end
end
