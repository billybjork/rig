defmodule Gate.Exe do
  @moduledoc """
  Where a part runs: an exe.dev VM, `<vm>.exe.xyz` (rig's history/exe-move.md). Its
  stage, launch, poll and end are each one plain `ssh` call under
  `libexec/deadline`, which runs a host-side script (`exe/`). None streams
  a part's output: the job is started detached (`exe/launch.sh`), the VM
  runs on with nobody connected, and its log is read in short polls.

  exe's SSH logs every user in as the image's default user (root), and a
  part runs as `gate` in a login shell (`su - gate`), whose profile puts
  Python 3.13 first (`exe/base.sh`). exe-init is PID 1, with no systemd,
  so the stage and the launch first run `base.sh boot` as root: a fresh
  copy of the golden, or a VM that restarted, lacks `/dev/fd`, and bash's
  process substitution fails without it.

  `$GATE_SSH` names the client (`ssh`).
  """

  @suffix ".exe.xyz"

  @doc "Whether `host` is an exe.dev VM: its SSH name, `<vm>.exe.xyz`."
  def host?(host), do: String.ends_with?(host, @suffix)

  @doc "The host-side scripts a part's tar carries: `{source under gate/, name in the tar}`."
  def files, do: [{"exe/job.sh", "job.sh"}, {"exe/launch.sh", "launch.sh"}]

  defp ssh, do: System.get_env("GATE_SSH", "ssh")

  # Every VM presents exe's one host key, pinned in `exe/known_hosts`, so a
  # copy made a second ago is known and no other key is taken.
  defp ssh_opts do
    known = Path.join(Gate.root(), "exe/known_hosts")

    ~w(-o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=3) ++
      ["-o", "UserKnownHostsFile=#{known}", "-o", "StrictHostKeyChecking=yes"]
  end

  @doc """
  Runs `bash -c <script> <name> <args...>` as `gate` on `host` for at most
  `secs`, after `base.sh boot` as root when `opts[:boot]`, its stdin
  `opts[:in]` (a file) or nothing. Returns `{output, status}`, stderr in
  the output; 142 is the limit passing.
  """
  def call(host, script, name, args, secs, opts \\ []) do
    inner = join(["bash", "-c", script, name | args])
    as_gate = "exec su - gate -c #{q(inner)}"

    remote =
      if opts[:boot],
        do: "bash -c #{q(boot())} base.sh boot && #{as_gate}",
        else: as_gate

    input = if opts[:in], do: ["--in", opts[:in]], else: []
    deadline = Path.join(Gate.root(), "libexec/deadline")

    System.cmd(deadline, [to_string(secs)] ++ input ++ [ssh() | ssh_opts()] ++ [host, remote],
      stderr_to_stdout: true
    )
  end

  defp boot, do: File.read!(Path.join(Gate.root(), "exe/base.sh"))

  defp script(host, name, args, secs, opts \\ []) do
    text = File.read!(Path.join(Gate.root(), "exe/#{name}.sh"))
    call(host, text, "#{name}.sh", args, secs, opts)
  end

  @doc """
  What the project's tree on `host` holds: `{:ok, tip, have}`, `tip` the
  last commit a bundle brought there (`refs/laptop/gate`) and `have` the
  first of `candidates` it has, each nil when none; `{:error, why}` when
  the VM could not be asked.

  `candidates` (HEAD's first parents, newest first) are what a bundle can
  stop at when this checkout lacks `tip`: the golden's tree was fetched by
  another checkout, and sending the whole history then (soco's is about
  300 MB) outlasted the upload's limit on a busy uplink (2026-11-16).
  """
  def holds(host, name, candidates) do
    case call(host, holds_script(), "holds", [name | candidates], 60) do
      {out, 0} -> parse_holds(out)
      {out, status} -> {:error, "exit #{status}: #{Gate.last_line(out)}"}
    end
  end

  @doc false
  def holds_script do
    ~S"""
    cd ~/"$1" 2>/dev/null || { echo tip; echo have; exit 0; }
    shift
    echo "tip $(git rev-parse -q --verify refs/laptop/gate)"
    for c in "$@"; do
      git cat-file -e "$c^{commit}" 2>/dev/null && { echo "have $c"; exit 0; }
    done
    echo have
    """
  end

  @doc false
  def parse_holds(out) do
    found =
      for line <- String.split(out, "\n", trim: true),
          [key, sha] <- [String.split(String.trim(line), " ", parts: 2)],
          key in ~w(tip have),
          sha =~ ~r/\A[0-9a-f]{40}\z/,
          into: %{},
          do: {key, sha}

    if out =~ ~r/^have/m,
      do: {:ok, found["tip"], found["have"]},
      else: {:error, "an unreadable answer: #{Gate.last_line(out)}"}
  end

  @doc """
  Uploads the part's tar to `~/parts/<id>`, ending what an earlier part
  left. An upload that outlasts `secs` is `{:error, {:timeout, why}}`: the
  laptop's link was too slow, which says nothing of the VM.
  """
  def stage(host, id, tar, secs) do
    case script(host, "stage", [id], secs, in: tar, boot: true) do
      {out, 0} ->
        if out =~ "gate-staged", do: :ok, else: {:error, Gate.last_line(out)}

      {out, 142} ->
        {:error, {:timeout, "the upload outlasted #{secs} s: #{Gate.last_line(out)}"}}

      {out, status} ->
        {:error, "the upload failed (exit #{status}): #{Gate.last_line(out)}"}
    end
  end

  @doc """
  Starts the staged part detached (`exe/launch.sh`, staged as the part's
  `launch.sh`): `{:ok, life}`, the VM's life as the part began.
  """
  def launch(host, id, secs) do
    launch = ~S|exec bash ~/parts/"$1"/launch.sh "$1"|

    case call(host, launch, "launch", [id], secs, boot: true) do
      {out, 0} ->
        case launched(out) do
          nil -> {:error, "the launch said no life: #{Gate.last_line(out)}"}
          life -> {:ok, life}
        end

      {out, status} ->
        {:error, "the launch failed (exit #{status}): #{Gate.last_line(out)}"}
    end
  end

  @doc "The life in a whole `gate-launched <life>` line of the launch's output, else nil."
  def launched(out) do
    case Regex.run(~r/^gate-launched (\S+)$/m, out) do
      [_, life] -> life
      nil -> nil
    end
  end

  @doc """
  The part's state and its log from byte `offset`: `{:ok, state, bytes}`
  with `state` holding `phase`, `rc`, `life`, `job` (`up` or `down`) and
  `size`, or `{:ok, :gone, ""}` when the VM has no such part, or
  `{:error, why}`.
  """
  def poll(host, id, offset, secs) do
    case script(host, "poll", [id, to_string(offset)], secs) do
      {out, 0} -> parse_poll(out)
      {out, status} -> {:error, "exit #{status}: #{Gate.last_line(out)}"}
    end
  end

  @doc false
  def parse_poll(out) do
    case String.split(out, "gate-poll: log\n", parts: 2) do
      [head, bytes] ->
        state =
          for line <- String.split(head, "\n"),
              [key, value] <- [String.split(line, " ", parts: 2)],
              key in ~w(phase rc life job size),
              into: %{},
              do: {key, String.trim(value)}

        case Integer.parse(state["size"] || "") do
          {size, ""} -> {:ok, Map.put(state, "size", size), bytes}
          _ -> {:error, "an unreadable poll: #{Gate.last_line(head)}"}
        end

      [_] ->
        if out =~ "gate-poll: gone",
          do: {:ok, :gone, ""},
          else: {:error, "an unreadable poll: #{Gate.last_line(out)}"}
    end
  end

  @doc "Ends the part's job: TERM, then KILL 3 s later."
  def kill(host, id), do: call(host, kill_script(), "kill", [id], 30)

  defp kill_script do
    ~S"""
    p=$(cat ~/parts/"$1"/job.pid 2>/dev/null) || exit 0
    kill -TERM -- "-$p" 2>/dev/null && sleep 3
    kill -KILL -- "-$p" 2>/dev/null
    true
    """
  end

  @doc "A POSIX shell word for `value`."
  def q(value), do: "'" <> String.replace(to_string(value), "'", ~S('\'')) <> "'"

  defp join(words), do: Enum.map_join(words, " ", &q/1)
end
