defmodule Shipyard.Branch do
  @moduledoc """
  The branch of a PR that landed, deleted from GitHub as its ship ends, so
  shipped branches do not pile up there (soco had 862 by 2026-11-24).

  The branch goes only when nothing is left on it. GitHub must report the
  PR merged (a branch deleted before that closes its PR unmerged), and the
  branch must still be at the head it merged, which GitHub keeps on the PR
  and the delete carries as its lease: a session that has pushed its next
  work to the branch keeps it, and that ship's end deletes it. With
  `merge: push` that head is the landed commit, with `squash` the gated
  one. `main`, a fork's branch, and a branch that is the head or the base
  of an open PR always stay.

  It runs before the ship's result is posted, while the label still holds
  the PR in the queue, so a worker stopped anywhere after the merge leaves
  it to the next one, and a session that reads its result as its cue to
  push again finds the branch already gone. Nothing after the merge reads
  it: the roll rolls `main`, and a wait reads the PR.

  `delete/2` never raises and is bounded by `timeout_ms`; what it returns
  is only logged, never part of a ship's result.
  """

  alias Shipyard.{Cmd, GitHub}

  @timeout_ms 30_000

  @doc """
  `{:deleted, tip}`, `:gone` (already), `{:kept, why}`, or `{:failed, why}`
  for one that should have gone.
  """
  def delete(ship, pr, tries \\ 3)

  def delete(_ship, %{branch: "main"}, _tries), do: {:kept, "it is main"}

  def delete(ship, pr, tries) do
    case GitHub.head(ship, pr, @timeout_ms) do
      %{fork: true} ->
        {:kept, "it is a fork's"}

      # GitHub marks a pushed commit's PR merged a second or so after main
      # has it; a roll with nothing to roll can end sooner.
      %{state: "OPEN"} when tries > 1 ->
        Process.sleep(ship.merge_wait_ms)
        delete(ship, pr, tries - 1)

      %{state: state} when state != "MERGED" ->
        {:failed, "GitHub reports the PR #{String.downcase(state)}, not merged"}

      %{tip: nil} ->
        :gone

      %{tip: tip, merged: merged} when tip != merged ->
        {:kept, "it moved from #{merged} to #{tip} since"}

      %{open: [number | _]} ->
        {:kept, "##{number} is open on it"}

      %{tip: tip} ->
        push(ship, pr.branch, tip)
    end
  rescue
    e -> {:failed, Exception.message(e)}
  end

  # From the roll's clone: a push from the entry's checkout would touch
  # refs a running entry's fetch prunes.
  defp push(ship, branch, tip) do
    ref = "refs/heads/#{branch}"
    args = ["push", "-q", "--force-with-lease=#{ref}:#{tip}", "origin", ":#{ref}"]

    case Cmd.run(ship, ship.roll, "git", args, timeout: @timeout_ms) do
      {_, 0} -> {:deleted, tip}
      {out, status} -> {:failed, "git push exited #{status}: #{String.trim(out)}"}
    end
  end
end
