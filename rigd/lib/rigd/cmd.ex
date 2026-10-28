defmodule Rigd.Cmd do
  @moduledoc """
  Runs a command to its end and returns its output and exit status. It runs
  under `alarm`, so a command that hangs (a Rex call after the Mac wakes) is
  killed after `:timeout` seconds (exit 142) rather than holding its caller.
  """

  require Logger

  def run(cmd, args, opts \\ []) do
    {timeout, opts} = Keyword.pop(opts, :timeout, 15)

    case System.find_executable(cmd) do
      nil ->
        {"#{cmd}: not found on PATH", 127}

      exe ->
        System.cmd(
          "perl",
          ["-e", "alarm shift; exec @ARGV", to_string(timeout), exe | args],
          [stderr_to_stdout: true] ++ opts
        )
    end
  end

  # The output of a command expected to succeed, or nil (logged) when it fails.
  def out(cmd, args, opts \\ []) do
    case run(cmd, args, opts) do
      {out, 0} ->
        out

      {out, status} ->
        Logger.warning(
          "#{cmd} #{Enum.join(args, " ")} exited #{status}: #{String.slice(out, 0, 300)}"
        )

        nil
    end
  end
end
