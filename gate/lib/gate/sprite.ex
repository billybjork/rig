defmodule Gate.Sprite do
  @moduledoc """
  Every call to the `sprite` CLI. Each is short and runs under
  `libexec/deadline`, which holds it to its limit from outside (the CLI
  ignores SIGALRM, and SIGTERM for 5 s and more). None streams a part's
  output: a long exec stream dies with "connection closed" and takes the
  part with it, so a part runs detached (`sprite/launch.sh`) and is read
  in short polls. `$GATE_SPRITE_CLI` names the CLI (`sprite`).
  """

  @root Path.expand("../..", __DIR__)

  def root, do: @root

  defp cli, do: System.get_env("GATE_SPRITE_CLI", "sprite")

  @doc """
  Runs `sprite <args>` for at most `secs`, its stdin `opts[:in]` (a file)
  or nothing. Returns `{output, status}`, stderr in the output; 142 is the
  limit passing.
  """
  def call(args, secs, opts \\ []) do
    repair_config()
    input = if opts[:in], do: ["--in", opts[:in]], else: []
    deadline = Path.join(@root, "libexec/deadline")
    System.cmd(deadline, [to_string(secs)] ++ input ++ [cli() | args], stderr_to_stdout: true)
  end

  # Two `sprite` calls at once (another project's gate) can leave
  # ~/.sprites/sprites.json with a stray tail, which fails every call.
  defp repair_config do
    case System.cmd(Path.join(@root, "libexec/sprite-config-repair"), [], stderr_to_stdout: true) do
      {"", 0} -> :ok
      {said, 0} -> IO.write(:stderr, said)
      {said, _} -> raise Gate.Error, String.trim(said)
    end
  end

  @doc "Runs the Sprite-side script `sprite/<name>.sh` with `args` on `sprite`."
  def script(sprite, name, args, secs, opts \\ []) do
    text = File.read!(Path.join(@root, "sprite/#{name}.sh"))
    call(["-s", sprite, "exec", "--", "bash", "-c", text, "#{name}.sh" | args], secs, opts)
  end

  def exists?(sprite) do
    case call(["list"], 60) do
      {out, 0} -> out |> String.split(~r/\s+/) |> Enum.member?(sprite)
      _ -> false
    end
  end

  def create(sprite), do: call(["create", "--skip-console", sprite], 300)

  @doc "The last commit `sprite` fetched into the project's tree, or nil."
  def tip(sprite, name) do
    script = ~S|git -C ~/"$1" rev-parse -q --verify refs/laptop/gate|

    case call(["-s", sprite, "exec", "--", "bash", "-c", script, "tip", name], 60) do
      {out, 0} ->
        out = String.trim(out)
        if out =~ ~r/\A[0-9a-f]{40}\z/, do: out

      _ ->
        nil
    end
  end

  @doc "Uploads the part's tar to `~/parts/<id>`, ending what an earlier part left."
  def stage(sprite, id, tar, secs) do
    case script(sprite, "stage", [id], secs, in: tar) do
      {out, 0} ->
        if out =~ "gate-staged", do: :ok, else: {:error, last_line(out)}

      {out, status} ->
        {:error, "the upload failed (exit #{status}): #{last_line(out)}"}
    end
  end

  @doc """
  Starts the staged part in a TTY session (`sprite/launch.sh`; `keep`
  starts only its keeper) and drops the client once the Sprite says it
  launched. Returns `{:ok, life}`, the Sprite's life as the part began.
  A TTY wants a terminal, which a gate under the ship worker lacks, so the
  client runs under `script`.
  """
  def launch(sprite, id, mode, secs) do
    launch = ~S|exec bash ~/parts/"$1"/launch.sh "$@"|
    deadline = Path.join(@root, "libexec/deadline")

    args =
      [to_string(secs), "--in", "-", "script", "-q", "/dev/null", cli(), "-s", sprite] ++
        ["exec", "--tty", "--", "bash", "-c", launch, "launch", id] ++ List.wrap(mode)

    repair_config()

    port =
      Port.open({:spawn_executable, deadline}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    await_launch(port, pid, "")
  end

  defp await_launch(port, pid, seen) do
    receive do
      {^port, {:data, data}} ->
        seen = seen <> data

        case launched(seen) do
          life when is_binary(life) ->
            System.cmd("kill", ["-TERM", to_string(pid)])
            drain(port)
            {:ok, life}

          nil ->
            await_launch(port, pid, String.slice(seen, -4000, 4000))
        end

      {^port, {:exit_status, status}} ->
        {:error, "the launch failed (exit #{status}): #{last_line(seen)}"}
    end
  end

  @doc """
  The life in a whole "gate-launched <life>" line of the TTY's output,
  else nil. The output comes in chunks, and a chunk can end inside the
  line; a life read short would look like a restart at the first poll.
  """
  def launched(seen) do
    case Regex.run(~r/gate-launched (\S+)\r?\n/, seen) do
      [_, life] -> life
      nil -> nil
    end
  end

  defp drain(port) do
    receive do
      {^port, {:data, _}} -> drain(port)
      {^port, {:exit_status, _}} -> :ok
    after
      30_000 -> :ok
    end
  end

  @doc """
  The part's state and its log from byte `offset`: `{:ok, state, bytes}`
  with `state` holding `phase`, `rc`, `life`, `job` and `keeper` (`up` or
  `down`) and `size`, or `{:ok, :gone, ""}` when the Sprite has no such
  part, or `{:error, why}`.
  """
  def poll(sprite, id, offset, secs) do
    case script(sprite, "poll", [id, to_string(offset)], secs) do
      {out, 0} -> parse_poll(out)
      {out, status} -> {:error, "exit #{status}: #{last_line(out)}"}
    end
  end

  @doc false
  def parse_poll(out) do
    case String.split(out, "gate-poll: log\n", parts: 2) do
      [head, bytes] ->
        state =
          for line <- String.split(head, "\n"),
              [key, value] <- [String.split(String.trim(line, "\r"), " ", parts: 2)],
              key in ~w(phase rc life job keeper size),
              into: %{},
              do: {key, String.trim(value)}

        case Integer.parse(state["size"] || "") do
          {size, ""} -> {:ok, Map.put(state, "size", size), String.replace(bytes, "\r\n", "\n")}
          _ -> {:error, "an unreadable poll: #{last_line(head)}"}
        end

      [_] ->
        if out =~ "gate-poll: gone",
          do: {:ok, :gone, ""},
          else: {:error, "an unreadable poll: #{last_line(out)}"}
    end
  end

  @doc "Ends the part's job and keeper: TERM, then KILL 3 s later."
  def kill(sprite, id) do
    script = ~S"""
    d=~/parts/$1
    for sig in TERM KILL; do
      for f in job keeper; do
        p=$(cat "$d/$f.pid" 2>/dev/null) && kill -$sig -- "-$p" 2>/dev/null
      done
      [ $sig = KILL ] || sleep 3
    done
    true
    """

    call(["-s", sprite, "exec", "--", "bash", "-c", script, "kill", id], 30)
  end

  def last_line(text) do
    text
    |> String.split(["\n", "\r"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> Kernel.||("no output")
  end
end
