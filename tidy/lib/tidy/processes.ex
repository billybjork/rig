defmodule Tidy.Processes do
  @moduledoc """
  Processes finished sessions left running in the project's checkouts
  (their working directory under the primary's). `prune` stops each, with
  its process tree; only the provably orphaned qualify:

    * a dev command (`dev_commands` in `.tidy.json`) reparented to launchd:
      its dev server is gone;
    * one of `processes` (node, BEAM, esbuild, tailwind) whose working
      directory is a removed worktree. Shells and agent sessions sitting in
      one are a person's, and stay.
  """

  defmodule Proc do
    @moduledoc false
    defstruct [:pid, :ppid, :comm, :cwd, :args]
  end

  def run(config, mode, env) do
    procs = env.procs.()

    for p <- procs, why = orphaned(p, config), why != nil do
      dir =
        if p.cwd == config.primary,
          do: Path.basename(p.cwd),
          else: Path.relative_to(p.cwd, config.primary)

      what = "#{String.slice(p.args, 0, 60)} (pid #{p.pid}, #{dir})"

      if mode == :prune do
        env.kill.([p.pid | descendants(p.pid, procs)])
        "stopped #{what}: #{why}"
      else
        "#{what}: #{why}; '#{config.as} prune' stops it"
      end
    end
  end

  @doc "Why `p` is orphaned, or nil."
  def orphaned(%Proc{} = p, config) do
    cond do
      not under?(p.cwd, config.primary) ->
        nil

      p.ppid == 1 and dev_command?(p.args, config.dev_commands) ->
        "its dev server is gone"

      not File.dir?(p.cwd) and Enum.any?(config.processes, &comm?(p.comm, &1)) ->
        "its worktree was removed"

      true ->
        nil
    end
  end

  defp dev_command?(_args, nil), do: false
  defp dev_command?(args, re), do: Regex.match?(re, args)

  defp under?(cwd, primary), do: cwd == primary or String.starts_with?(cwd, primary <> "/")

  defp comm?(comm, pattern) do
    case String.split(pattern, "*", parts: 2) do
      [exact] -> comm == exact
      [prefix, ""] -> String.starts_with?(comm, prefix)
      _ -> false
    end
  end

  def descendants(pid, procs) do
    Enum.flat_map(procs, fn
      %Proc{pid: child, ppid: ^pid} -> [child | descendants(child, procs)]
      _ -> []
    end)
  end

  @doc """
  The user's processes with a working directory: `lsof -Fpcn` for each
  one's cwd, `ps` for its parent and arguments.
  """
  def list do
    # lsof exits 1 when it could not read some process; what it read stands.
    with {lsof, s} when s in [0, 1] <-
           Tidy.Cmd.run("lsof", ["-a", "-d", "cwd", "-u", System.get_env("USER", ""), "-Fpcn"],
             stderr: false
           ),
         ps when ps != nil <- Tidy.Cmd.out("ps", ["-Ao", "pid=,ppid=,command="]) do
      parse(lsof, ps)
    else
      _ -> []
    end
  end

  def parse(lsof, ps) do
    table =
      for line <- String.split(ps, "\n", trim: true),
          [pid, ppid, args] <- [String.split(String.trim_leading(line), ~r/\s+/, parts: 3)],
          into: %{},
          do: {String.to_integer(pid), {String.to_integer(ppid), String.trim_trailing(args)}}

    with_cwd =
      lsof
      |> String.split("\n", trim: true)
      |> Enum.reduce({nil, nil, []}, fn
        "p" <> pid, {_, _, acc} -> {String.to_integer(pid), nil, acc}
        "c" <> comm, {pid, _, acc} -> {pid, comm, acc}
        "n" <> cwd, {pid, comm, acc} -> {pid, comm, [{pid, comm, cwd} | acc]}
        _, st -> st
      end)
      |> elem(2)

    cwds = Map.new(with_cwd, fn {pid, comm, cwd} -> {pid, {comm, cwd}} end)

    for {pid, {ppid, args}} <- table do
      {comm, cwd} = Map.get(cwds, pid, {"", ""})
      %Proc{pid: pid, ppid: ppid, comm: comm || "", cwd: cwd, args: args}
    end
  end

  def kill(pids),
    do: System.cmd("kill", ["-TERM" | Enum.map(pids, &to_string/1)], stderr_to_stdout: true)
end
