defmodule Rigd.Fleet.CLI do
  @moduledoc """
  The one process in rigd that runs `sprite`: every lifecycle call (list,
  create, destroy, checkpoint, restore, and ending a dead lease's parts)
  goes through it, one at a time, under rig's `gate/libexec/deadline`,
  which holds the CLI to its limit from outside (it ignores SIGALRM, and
  SIGTERM for 5 s and more). One at a time ends the `sprites.json`
  tearing that two calls at once cause. Gates still call the CLI for
  their own parts' stage, launch and polls, each short.
  """

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs `sprite <args>` for at most `secs`: `{output, status}`, 142 when the limit passed."
  def call(args, secs), do: GenServer.call(__MODULE__, {:call, args, secs}, :infinity)

  @doc "The Sprites the account has."
  def list do
    case call(["list"], 60) do
      {out, 0} -> {:ok, String.split(out, ~r/\s+/, trim: true)}
      {out, status} -> {:error, "sprite list exited #{status}: #{last_line(out)}"}
    end
  end

  @doc "`sprite checkpoint list`, newest first as the CLI prints it: `[{id, line}]`."
  def checkpoints(sprite) do
    case call(["checkpoint", "list", "-s", sprite], 60) do
      {out, 0} ->
        {:ok,
         for(
           line <- String.split(out, "\n", trim: true),
           [id | _] = String.split(line),
           do: {id, line}
         )}

      {out, status} ->
        {:error, "checkpoint list exited #{status}: #{last_line(out)}"}
    end
  end

  @doc "`:ok` when the call exits 0, or fails with output matching `done` (its work was already done)."
  def ok(args, secs, done \\ nil) do
    case call(args, secs) do
      {_, 0} ->
        :ok

      {out, status} ->
        if done && status != 142 && out =~ done,
          do: :ok,
          else: {:error, "sprite #{hd(args)} exited #{status}: #{last_line(out)}"}
    end
  end

  def last_line(text) do
    text
    |> String.split(["\n", "\r"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> Kernel.||("no output")
  end

  @impl true
  def init(opts), do: {:ok, %{cli: opts[:cli], deadline: opts[:deadline]}}

  @impl true
  def handle_call({:call, args, secs}, _from, st) do
    result =
      try do
        System.cmd(st.deadline, [to_string(secs), st.cli | args], stderr_to_stdout: true)
      rescue
        # A deadline or CLI that cannot run is a failed call, not a crash.
        e in ErlangError -> {"cannot run #{st.deadline}: #{inspect(e.original)}", 127}
      end

    {:reply, result, st}
  end
end
