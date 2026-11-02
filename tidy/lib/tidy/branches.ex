defmodule Tidy.Branches do
  @moduledoc """
  Agent branches (`branches` in `.tidy.json`) that no worktree carries.

    * A local one is stale once landed at its tip (`Tidy.Landed`), or when
      it holds nothing beyond `origin/main`; `prune` deletes it. A session
      that removed its own worktree leaves its branch behind.
    * A remote one may be a cloud or sibling session's work with no
      checkout here: reported with its state, never deleted from here.
  """

  alias Tidy.{Landed, Worktrees}

  def run(%{branches: nil}, _mode, _env), do: []

  def run(config, mode, env) do
    {list, 0} = env.git.(["worktree", "list", "--porcelain"])
    carried = list |> Worktrees.parse() |> MapSet.new(& &1.branch)
    agent? = &(Regex.match?(config.branches, &1) and not MapSet.member?(carried, &1))
    local = refs(env, "refs/heads") |> Enum.filter(agent?)

    remote =
      refs(env, "refs/remotes/origin") |> Enum.map(&String.replace_prefix(&1, "origin/", ""))

    Enum.flat_map(local, &local(&1, remote, config, mode, env)) ++
      (remote |> Enum.filter(agent?) |> Enum.map(&remote(&1, config, env)))
  end

  defp local(branch, remote, config, mode, env) do
    {tip, 0} = env.git.(["rev-parse", branch])
    tip = String.trim(tip)

    why =
      case {Landed.verdict(config.landed, env.git, env.prs, branch, tip),
            Landed.ahead(env.git, tip)} do
        {{:landed, why}, _} -> {:stale, why}
        {_, "0"} -> {:stale, "nothing beyond origin/main"}
        {verdict, _} -> verdict
      end

    case why do
      {:stale, why} when mode == :prune ->
        env.git.(["branch", "-D", branch])
        ["branch #{branch}: #{why}; deleted"]

      {:stale, why} ->
        ["branch #{branch}: #{why}, no worktree; '#{config.as} prune' deletes it"]

      {_, why} ->
        # Pushed: the remote pass reports it with its state.
        if branch in remote,
          do: [],
          else: [
            "branch #{branch}: #{why}, no worktree, not pushed; left alone (push it or delete it deliberately)"
          ]
    end
  end

  defp remote(branch, config, env) do
    ref = "origin/" <> branch
    {tip, 0} = env.git.(["rev-parse", ref])

    case Landed.verdict(config.landed, env.git, env.prs, branch, String.trim(tip)) do
      {kind, why} when kind in [:landed, :after] ->
        "#{ref}: #{why}; a leftover remote branch (git push origin --delete #{branch})"

      {:ahead, why} ->
        "#{ref}: #{why}; another session's work. Do not duplicate it: its ship lands it, or ship it from a worktree (git worktree add .worktrees/<name> #{branch}), or ask"
    end
  end

  defp refs(env, prefix) do
    {out, 0} = env.git.(["for-each-ref", "--format=%(refname:short)", prefix])

    out
    |> String.split("\n", trim: true)
    |> Enum.reject(&(&1 in ["origin", "origin/HEAD", "origin/main"]))
  end
end
