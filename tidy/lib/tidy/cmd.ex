defmodule Tidy.Cmd do
  @moduledoc """
  Runs a command to its end: `{output, status}`. It runs under `alarm`, so
  one that hangs (an unreachable `gh`, a wedged `psql`) is killed after
  `:timeout` seconds (exit 142) instead of holding a session's start. A
  command not on PATH exits 127.
  """

  def run(cmd, args, opts \\ []) do
    {timeout, opts} = Keyword.pop(opts, :timeout, 30)
    {stderr, opts} = Keyword.pop(opts, :stderr, true)

    case executable(cmd, opts[:cd]) do
      nil ->
        {"#{cmd}: not found", 127}

      exe ->
        System.cmd(
          "perl",
          ["-e", "alarm shift; exec @ARGV", to_string(timeout), exe | args],
          [stderr_to_stdout: stderr] ++ opts
        )
    end
  end

  @doc "The output of a command that succeeded, or nil."
  def out(cmd, args, opts \\ []) do
    case run(cmd, args, opts) do
      {out, 0} -> out
      _ -> nil
    end
  end

  def ok?(cmd, args, opts \\ []), do: match?({_, 0}, run(cmd, args, opts))

  # A relative path with a slash (`scripts/pg.sh`) names a file in `cd`.
  defp executable(cmd, cd) do
    cond do
      String.contains?(cmd, "/") ->
        path = Path.expand(cmd, cd || File.cwd!())
        if File.regular?(path), do: path

      true ->
        System.find_executable(cmd)
    end
  end
end
