defmodule Tidy.Landed do
  @moduledoc """
  Whether a branch's work is on `main`, by the project's rule (`landed` in
  `.tidy.json`):

    * `:ancestor`: its tip is an ancestor of `origin/main` (a project that
      ships by pushing `main`, so a landed branch carries nothing more);
    * `:merged_pr`: a merged pull request's head has every commit of its
      tip, as itself or rebased (the same patch). One that merged without
      some leaves those unlanded.

  `verdict/5` returns `{:landed, why}`, `{:after, why}` (merged, but with
  commits since) or `{:ahead, why}` (work not on main, with its PR state).
  `git` runs git in the repository (`{output, status}`); `prs` looks a
  branch's pull requests up: `prs.(branch, :merged)` gives
  `{number, head_oid}` or nil, `prs.(branch, :open)` a number or nil.
  """

  def verdict(:ancestor, git, _prs, _branch, tip) do
    if elem(git.(["merge-base", "--is-ancestor", tip, "origin/main"]), 1) == 0 do
      {:landed, "landed on origin/main"}
    else
      {:ahead, "#{ahead(git, tip)} commit(s) not on origin/main"}
    end
  end

  def verdict(:merged_pr, git, prs, branch, tip) do
    case branch && prs.(branch, :merged) do
      {pr, ^tip} ->
        {:landed, "PR ##{pr} merged at its tip"}

      {pr, head} ->
        case unshipped(git, pr, head, tip) do
          0 -> {:landed, "PR ##{pr} merged, its commits rebased"}
          n -> {:after, "PR ##{pr} merged, but #{n} commit(s) never shipped"}
        end

      nil ->
        case branch && prs.(branch, :open) do
          nil -> {:ahead, "#{ahead(git, tip)} commit(s) ahead of origin/main, no PR"}
          pr -> {:ahead, "#{ahead(git, tip)} commit(s) ahead of origin/main, PR ##{pr} open"}
        end
    end
  end

  # The ship worker rebases a branch before it merges, so the PR's head is a
  # commit the branch never had (GitHub keeps it as pull/N/head after the
  # branch is deleted). A commit of the branch is shipped when the PR's head
  # has it or a commit with the same patch (`git cherry`); a rebase that
  # resolved a conflict changes the patch, and leaves the commit unshipped.
  defp unshipped(git, pr, head, tip) do
    if elem(git.(["cat-file", "-e", head <> "^{commit}"]), 1) != 0,
      do: git.(["fetch", "--quiet", "origin", "pull/#{pr}/head"])

    case git.(["cherry", head, tip]) do
      {out, 0} ->
        out |> String.split("\n", trim: true) |> Enum.count(&String.starts_with?(&1, "+"))

      _ ->
        "?"
    end
  end

  def ahead(git, tip), do: count(git, "origin/main..#{tip}")

  defp count(git, range) do
    case git.(["rev-list", "--count", range]) do
      {n, 0} -> String.trim(n)
      _ -> "?"
    end
  end

  @doc "`prs` for the repository in `dir`, from `gh`."
  def gh(dir) do
    fn branch, state ->
      fields = if state == :merged, do: "number,headRefOid", else: "number"
      args = ~w(pr list --head #{branch} --state #{state} --limit 1 --json #{fields})

      with {out, 0} <- Tidy.Cmd.run("gh", args, cd: dir, stderr: false),
           {:ok, [pr | _]} <- JSON.decode(out) do
        if state == :merged, do: {pr["number"], pr["headRefOid"]}, else: pr["number"]
      else
        _ -> nil
      end
    end
  end
end
