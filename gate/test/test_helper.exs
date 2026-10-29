ExUnit.start()

defmodule Gate.Fake do
  @moduledoc """
  A project checkout and a fake `sprite` CLI whose Sprites are directories:
  `<root>/<sprite>/home` is a Sprite's home, `~/.life` its life. An exec
  runs there; a TTY exec runs in a session of its own that outlives its
  client, as a real one does. A Sprite with a `down` file answers nothing
  ("Error: connection closed"). Checkpoints go to `<sprite>/checkpoints`.
  """

  import ExUnit.Assertions

  @sprite_cli ~S"""
  #!/bin/bash
  root=$FAKE_SPRITES
  s=
  [ "${1:-}" != -s ] || { s=$2; shift 2; }
  case "$1" in
    list) for d in "$root"/*/; do basename "$d"; done; exit 0 ;;
    create) mkdir -p "$root/$3/home" && echo life-1 >"$root/$3/home/.life"; exit 0 ;;
    destroy) rm -rf "${root:?}/$4"; exit 0 ;;
    checkpoint)
      [ "$2" != list ] || { cat "$root/$4/checkpoints" 2>/dev/null; exit 0; }
      n=$(($(wc -l <"$root/$4/checkpoints" 2>/dev/null || echo 0) + 1))
      echo "cp-$n  $6" >>"$root/$4/checkpoints"; exit 0 ;;
  esac
  [ -d "$root/$s" ] || { echo "Error: no sprite $s"; exit 1; }
  [ ! -e "$root/$s/down" ] || { echo "Error: connection closed"; exit 1; }
  shift
  tty=
  [ "$1" != --tty ] || { tty=1; shift; }
  shift
  export HOME=$root/$s/home
  cd "$HOME"
  echo "$s $*" >>"$root/calls"
  if [ -n "$tty" ]; then
    out=$root/$s/tty-$$.out
    : >"$out"
    setsid "$@" >"$out" 2>&1 </dev/null &
    exec tail -f "$out"
  fi
  exec "$@"
  """

  @setsid ~S"""
  #!/usr/bin/perl
  use POSIX ();
  POSIX::setsid() or die "setsid: $!\n";
  exec @ARGV or die "setsid: $ARGV[0]: $!\n";
  """

  @doc """
  A checkout with `.gate.json` (`config` merged in) and the scripts the
  parts run (`cmd.sh <behavior>`), Sprites `sprites`, and the fake CLI on
  PATH. Returns `%{top, root, logs}`.
  """
  def setup(tmp, sprites, config \\ %{}) do
    top = Path.join(tmp, "proj")
    root = Path.join(tmp, "sprites")
    bin = Path.join(tmp, "bin")
    logs = Path.join(tmp, "logs")
    Enum.each([top, root, bin], &File.mkdir_p!/1)

    for s <- sprites do
      File.mkdir_p!(Path.join([root, s, "home"]))
      File.write!(Path.join([root, s, "home", ".life"]), "life-1\n")
    end

    executable(Path.join(bin, "sprite"), @sprite_cli)
    executable(Path.join(bin, "setsid"), @setsid)

    gate =
      Map.merge(
        %{
          "name" => "proj",
          "pool" => sprites,
          "dev" => ["dev-1"],
          "logs" => logs,
          "locks" => Path.join(tmp, "locks"),
          "parts" => ["bash", "-c", "cat parts.tsv", "parts"],
          "stamp" => [".tool-versions", "provision.sh"],
          "provision" => ["provision.sh", ".tool-versions"],
          "setup" => "setup.sh",
          "keep" => ["cache"],
          "provision_gate" => ["bash cmd.sh green"],
          "weights" => "weights.exs",
          "limits" => %{"poll" => 0.1, "run" => 20, "unreachable" => 2, "launch" => 10}
        },
        config
      )
      |> Map.reject(fn {_, value} -> value == nil end)

    files = %{
      ".gate.json" => JSON.encode!(gate),
      ".tool-versions" => "elixir 1.20.3-otp-28\n",
      "provision.sh" => ~S"""
      echo "provisioning $1 from $2"
      echo "$1" >~/proj-stamp
      """,
      "setup.sh" => "echo setup ran\n",
      "cmd.sh" => File.read!(Path.expand("support/cmd.sh", __DIR__)),
      "parts.tsv" => ""
    }

    for {name, text} <- files, do: File.write!(Path.join(top, name), text)
    git(top, ["init", "-q", "-b", "main"])
    git(top, ["add", "."])
    git(top, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "the project"])

    System.put_env("FAKE_SPRITES", root)
    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))
    System.put_env("GATE_KILL_GRACE", "1")
    %{top: top, root: root, logs: logs, tmp: tmp}
  end

  @doc "Ends what the fake Sprites still run (detached jobs, keepers, `tail -f` clients)."
  def stop(root), do: System.cmd("pkill", ["-f", root])

  def parts(top, parts) do
    File.write!(
      Path.join(top, "parts.tsv"),
      Enum.map_join(parts, "", fn {n, c} -> "#{n}\t#{c}\n" end)
    )
  end

  def config(top), do: Gate.Config.load(top)

  @doc "Runs `fun` capturing stdout and stderr: `{status, stdout, stderr}`."
  def capture(fun) do
    me = self()

    err =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        out = ExUnit.CaptureIO.capture_io(fn -> send(me, {:status, fun.()}) end)
        send(me, {:out, out})
      end)

    assert_received {:status, status}
    assert_received {:out, out}
    {status, out, err}
  end

  def rows(logs),
    do: logs |> Path.join("check-remote.tsv") |> File.read!() |> String.split("\n", trim: true)

  def git(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end

  defp executable(path, text) do
    File.write!(path, text)
    File.chmod!(path, 0o755)
  end
end
