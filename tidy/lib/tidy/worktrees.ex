defmodule Tidy.Worktrees do
  @moduledoc """
  Linked worktrees: one line for each with its state, and in `prune` the
  removal of each one whose work landed (`Tidy.Landed`), its branch with
  it. Nothing with uncommitted changes, commits that have not landed, or a
  lock (a session is inside) is touched, nor the checkout tidy runs in.
  """

  alias Tidy.Landed

  defmodule Entry do
    @moduledoc false
    defstruct [:path, :head, :branch, locked: false]
  end

  @doc "`git worktree list --porcelain`, the primary checkout first."
  def parse(porcelain) do
    porcelain
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn block ->
      block
      |> String.split("\n", trim: true)
      |> Enum.reduce(%Entry{}, fn
        "worktree " <> path, e -> %{e | path: path}
        "HEAD " <> head, e -> %{e | head: head}
        "branch refs/heads/" <> b, e -> %{e | branch: b}
        "locked" <> _, e -> %{e | locked: true}
        _, e -> e
      end)
    end)
    |> Enum.filter(& &1.path)
  end

  def run(config, mode, env) do
    {list, 0} = env.git.(["worktree", "list", "--porcelain"])
    [_primary | linked] = parse(list)
    lines = Enum.map(linked, &line(&1, config, mode, env))
    env.git.(["worktree", "prune"])
    lines
  end

  defp line(e, config, mode, env) do
    name = Path.relative_to(e.path, config.primary)
    label = "#{name} [#{e.branch || "(detached)"}]"

    cond do
      not File.dir?(e.path) ->
        "#{name}: directory missing (git worktree prune clears the entry)"

      e.locked ->
        case Landed.verdict(config.landed, env.git, env.prs, e.branch, e.head) do
          {:landed, why} ->
            "#{label}: #{why}, its session still live; the first prune after it ends removes it"

          _ ->
            "#{label}: in use (locked by its session); left alone"
        end

      (n = changes(e.path)) > 0 ->
        "#{label}: #{n} uncommitted change(s); left alone. Ship from it, or remove it deliberately"

      true ->
        case Landed.verdict(config.landed, env.git, env.prs, e.branch, e.head) do
          {:landed, why} when e.path == config.here ->
            "#{label}: #{why}; this session's own checkout, left alone"

          {:landed, why} when mode == :prune ->
            remove(e, label, why, env)

          {:landed, why} ->
            "#{label}: #{why}; '#{config.as} prune' removes it"

          {:after, why} ->
            "#{label}: #{why}; left alone"

          {:ahead, why} ->
            "#{label}: #{why}; left alone (ship it or remove it deliberately)"
        end
    end
  end

  defp remove(e, label, why, env) do
    case env.git.(["worktree", "remove", e.path]) do
      {_, 0} ->
        if e.branch, do: env.git.(["branch", "-D", e.branch])
        "#{label}: #{why}; removed"

      {out, _} ->
        "#{label}: #{why}, but the removal failed (#{String.trim(out)}); left alone"
    end
  end

  defp changes(path) do
    case Tidy.Cmd.run("git", ["status", "--porcelain"], cd: path) do
      {out, 0} -> out |> String.split("\n", trim: true) |> length()
      _ -> 1
    end
  end
end
