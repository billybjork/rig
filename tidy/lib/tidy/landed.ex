defmodule Tidy.Landed do
  @moduledoc """
  Whether a branch's work is on `main`, by the project's rule (`landed` in
  `.tidy.json`):

    * `:ancestor`: its tip is an ancestor of `origin/main` (a project that
      ships by pushing `main`, so a landed branch carries nothing more);
    * `:merged_pr`: a merged pull request's head is its tip. One that
      merged at an earlier commit leaves the later ones unlanded.

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
        {:after, "PR ##{pr} merged, but #{count(git, "#{head}..#{tip}")} commit(s) came after it"}

      nil ->
        case branch && prs.(branch, :open) do
          nil -> {:ahead, "#{ahead(git, tip)} commit(s) ahead of origin/main, no PR"}
          pr -> {:ahead, "#{ahead(git, tip)} commit(s) ahead of origin/main, PR ##{pr} open"}
        end
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
