defmodule Rigd.Fleet.Golden do
  @moduledoc """
  What makes a Sprite golden, run through rig's `gate`: each project's
  stamp on `origin/main` (`gate stamp origin/main` in its primary
  checkout, after a fetch), and its provision gate on a Sprite (`gate
  golden <sprite>`, the parts of its tier `check` in turn) from a detached
  worktree of `origin/main` that is removed after. The primary checkout's
  branch and tree are never touched. Each run's output goes to
  `~/Library/Logs/rigd-fleet/`.
  """

  @doc "The project's name and its stamp on `origin/main`."
  def stamp(gate, dir) do
    with :ok <- fetch(dir),
         {:ok, json} <- git(dir, ["show", "origin/main:.gate.json"]),
         {stamp, 0} <- cmd(gate, ["stamp", "origin/main"], dir, 120) do
      {:ok, JSON.decode!(json)["name"], last_line(stamp)}
    else
      {:error, why} -> {:error, why}
      {out, status} -> {:error, "gate stamp exited #{status}: #{last_line(out)}"}
    end
  end

  @doc """
  The project's provision gate on `sprite`: `{:green, name, stamp}`,
  `{:red, why}` (a part failed on `main`: not the Sprite's doing), or
  `{:sprite_failed, why}`.
  """
  def run(gate, dir, sprite) do
    tmp =
      Path.join(System.tmp_dir!(), "rigd-golden-#{sprite}-#{System.unique_integer([:positive])}")

    with :ok <- fetch(dir),
         {:ok, json} <- git(dir, ["show", "origin/main:.gate.json"]),
         {:ok, _} <- git(dir, ["worktree", "add", "-q", "--detach", tmp, "origin/main"]) do
      name = JSON.decode!(json)["name"]
      log = log_path(sprite, name)
      {out, status} = cmd(gate, ["golden", sprite], tmp, 4 * 3600)
      File.write!(log, out)
      {stamp, _} = cmd(gate, ["stamp"], tmp, 120)
      git(dir, ["worktree", "remove", "--force", tmp])

      case status do
        0 -> {:green, name, last_line(stamp)}
        1 -> {:red, "#{name}'s provision gate went red on main (#{log})"}
        _ -> {:sprite_failed, "#{name}'s provision gate: exit #{status} (#{log})"}
      end
    end
  end

  defp fetch(dir) do
    case git(dir, ["fetch", "-q", "origin", "main"]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp git(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, "git #{hd(args)} in #{dir} exited #{status}: #{last_line(out)}"}
    end
  end

  # `gate` under a deadline, in `dir`, stdout and stderr together.
  defp cmd(gate, args, dir, secs) do
    deadline = Path.join(Path.dirname(Path.dirname(gate)), "libexec/deadline")
    System.cmd(deadline, [to_string(secs), gate | args], cd: dir, stderr_to_stdout: true)
  end

  defp log_path(sprite, name) do
    dir = Path.expand("~/Library/Logs/rigd-fleet")
    File.mkdir_p!(dir)
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    Path.join(dir, "#{sprite}-#{name}-#{stamp}.log")
  end

  defp last_line(text), do: Rigd.Fleet.CLI.last_line(text)
end
