defmodule Gate.Exe do
  @moduledoc """
  The exe.dev host backend (rig's EXE.md, step 2): the same stage, launch,
  poll and end as `Gate.Sprite`, each one plain `ssh <vm>.exe.xyz` call
  under `libexec/deadline`, and the same Sprite-side scripts (`sprite/`)
  but for the launch (`exe/launch.sh`), which needs no keeper: an exe.dev
  VM runs on with nobody connected, so the job is started detached and the
  call returns.

  exe's SSH logs every user in as the image's default user (root), and a
  part runs as `gate` in a login shell (`su - gate`), whose profile puts
  Python 3.13 first (`exe/base.sh`). exe-init is PID 1, with no systemd,
  so the stage and the launch first run `base.sh boot` as root: a fresh
  copy of the golden, or a VM that restarted, lacks `/dev/fd`, and bash's
  process substitution fails without it.

  `$GATE_SSH` names the client (`ssh`).
  """

  alias Gate.Sprite

  @suffix ".exe.xyz"

  @doc "Whether `host` is an exe.dev VM: its SSH name, `<vm>.exe.xyz`."
  def host?(host), do: String.ends_with?(host, @suffix)

  defp ssh, do: System.get_env("GATE_SSH", "ssh")

  # Every VM presents exe's one host key, pinned in `exe/known_hosts`, so a
  # copy made a second ago is known and no other key is taken.
  defp ssh_opts do
    known = Path.join(Sprite.root(), "exe/known_hosts")

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
    deadline = Path.join(Sprite.root(), "libexec/deadline")

    System.cmd(deadline, [to_string(secs)] ++ input ++ [ssh() | ssh_opts()] ++ [host, remote],
      stderr_to_stdout: true
    )
  end

  defp boot, do: File.read!(Path.join(Sprite.root(), "exe/base.sh"))

  defp script(host, name, args, secs, opts \\ []) do
    text = File.read!(Path.join(Sprite.root(), "sprite/#{name}.sh"))
    call(host, text, "#{name}.sh", args, secs, opts)
  end

  @doc "As `Gate.Sprite.holds/3`."
  def holds(host, name, candidates) do
    case call(host, Sprite.holds_script(), "holds", [name | candidates], 60) do
      {out, 0} -> Sprite.parse_holds(out)
      {out, status} -> {:error, "exit #{status}: #{Sprite.last_line(out)}"}
    end
  end

  @doc "As `Gate.Sprite.stage/4`."
  def stage(host, id, tar, secs) do
    case script(host, "stage", [id], secs, in: tar, boot: true) do
      {out, 0} ->
        if out =~ "gate-staged", do: :ok, else: {:error, Sprite.last_line(out)}

      {out, 142} ->
        {:error, {:timeout, "the upload outlasted #{secs} s: #{Sprite.last_line(out)}"}}

      {out, status} ->
        {:error, "the upload failed (exit #{status}): #{Sprite.last_line(out)}"}
    end
  end

  @doc """
  Starts the staged part detached (`exe/launch.sh`, staged as the part's
  `launch.sh`): `{:ok, life}`, the VM's life as the part began. There is no
  keeper, so `keep` has nothing to start.
  """
  def launch(_host, _id, "keep", _secs), do: {:ok, nil}

  def launch(host, id, _mode, secs) do
    launch = ~S|exec bash ~/parts/"$1"/launch.sh "$1"|

    case call(host, launch, "launch", [id], secs, boot: true) do
      {out, 0} ->
        case Sprite.launched(out) do
          nil -> {:error, "the launch said no life: #{Sprite.last_line(out)}"}
          life -> {:ok, life}
        end

      {out, status} ->
        {:error, "the launch failed (exit #{status}): #{Sprite.last_line(out)}"}
    end
  end

  @doc "As `Gate.Sprite.poll/4`, with no keeper to report."
  def poll(host, id, offset, secs) do
    case script(host, "poll", [id, to_string(offset)], secs) do
      {out, 0} ->
        case Sprite.parse_poll(out) do
          {:ok, state, bytes} when is_map(state) -> {:ok, Map.delete(state, "keeper"), bytes}
          other -> other
        end

      {out, status} ->
        {:error, "exit #{status}: #{Sprite.last_line(out)}"}
    end
  end

  @doc "As `Gate.Sprite.kill/2`."
  def kill(host, id), do: call(host, Sprite.kill_script(), "kill", [id], 30)

  @doc "A POSIX shell word for `value`."
  def q(value), do: "'" <> String.replace(to_string(value), "'", ~S('\'')) <> "'"

  defp join(words), do: Enum.map_join(words, " ", &q/1)
end
