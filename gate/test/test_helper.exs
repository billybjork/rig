ExUnit.start()

defmodule Gate.Fake do
  @moduledoc """
  A project checkout and fake exe.dev VMs, each a directory:
  `<root>/<vm>/home` is its home, `~/.life` its life. A fake `ssh`
  (`$GATE_SSH`) runs its remote command there, and a fake `su` runs
  `su - gate -c <command>` there too. A VM with a `down` file refuses ssh;
  one with `slow-stage` takes that many seconds over each upload.
  `Gate.FakeFleet` leases them.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  @vms ~w(vm-1.exe.xyz vm-2.exe.xyz vm-3.exe.xyz)

  @doc "The fake VMs' names: `vm(1)` is `vm-1.exe.xyz`."
  def vm(n), do: "vm-#{n}.exe.xyz"

  @ssh ~S"""
  #!/bin/bash
  root=$FAKE_VMS
  while [ "${1:-}" = -o ]; do shift 2; done
  host=$1 remote=$2
  [ -d "$root/$host" ] || { echo "ssh: Could not resolve hostname $host"; exit 255; }
  [ ! -e "$root/$host/down" ] || { echo "ssh: connect to host $host port 22: Connection refused"; exit 255; }
  export HOME=$root/$host/home
  cd "$HOME"
  echo "$host ssh $remote" >>"$root/calls"
  case "$remote" in
    *gate-staged*) [ ! -e "$root/$host/slow-stage" ] || sleep "$(cat "$root/$host/slow-stage")" ;;
  esac
  # In a session of its own, as a real remote command is out of reach of
  # what ends the client (`libexec/deadline` kills its group); fd 3 keeps
  # stdin, which a background job would lose.
  exec 3<&0
  setsid bash -c "$remote" <&3 3<&- &
  wait $!
  """

  @su ~S"""
  #!/bin/bash
  # su - gate -c <command>
  [ "$1 $2 $3" = "- gate -c" ] || { echo "su: unexpected $*"; exit 1; }
  exec bash -c "$4"
  """

  @setsid ~S"""
  #!/usr/bin/perl
  use POSIX ();
  POSIX::setsid() or die "setsid: $!\n";
  exec @ARGV or die "setsid: $ARGV[0]: $!\n";
  """

  @doc """
  A checkout with `.gate.json` (`config` merged in) and the scripts the
  parts run (`cmd.sh <behavior>`), the VMs, and the fakes on PATH.
  Returns `%{top, root, logs, tmp}`.
  """
  def setup(tmp, config \\ %{}) do
    top = Path.join(tmp, "proj")
    root = Path.join(tmp, "vms")
    bin = Path.join(tmp, "bin")
    logs = Path.join(tmp, "logs")
    Enum.each([top, root, bin], &File.mkdir_p!/1)

    for s <- @vms do
      File.mkdir_p!(Path.join([root, s, "home"]))
      File.write!(Path.join([root, s, "home", ".life"]), "life-1\n")
    end

    executable(Path.join(bin, "setsid"), @setsid)
    executable(Path.join(bin, "fake-ssh"), @ssh)
    executable(Path.join(bin, "su"), @su)
    System.put_env("GATE_SSH", Path.join(bin, "fake-ssh"))

    gate =
      Map.merge(
        %{
          "name" => "proj",
          "pool" => "exe",
          "logs" => logs,
          "parts" => ["bash", "-c", "cat parts.tsv", "parts"],
          "stamp" => [".tool-versions", "provision.sh"],
          "provision" => ["provision.sh", ".tool-versions"],
          "setup" => "setup.sh",
          "keep" => ["cache"],
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

    System.put_env("FAKE_VMS", root)
    System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))
    System.put_env("GATE_KILL_GRACE", "1")
    %{top: top, root: root, logs: logs, tmp: tmp}
  end

  @doc "Ends what the fake VMs still run (detached jobs)."
  def stop(root), do: System.cmd("pkill", ["-f", root])

  def parts(top, parts) do
    File.write!(
      Path.join(top, "parts.tsv"),
      Enum.map_join(parts, "", fn {n, c} -> "#{n}\t#{c}\n" end)
    )
  end

  def config(top), do: Gate.Config.load(top)

  @doc "A `Gate.FakeFleet` leasing `hosts`, stopped when the test ends."
  def fleet(hosts) do
    fleet = Gate.FakeFleet.start(hosts)

    on_exit(fn ->
      if Process.alive?(fleet), do: Gate.FakeFleet.stop(fleet)
      System.delete_env("GATE_FLEET_SOCKET")
    end)

    fleet
  end

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

defmodule Gate.FakeFleet do
  @moduledoc """
  rigd's `Fleet` as a gate sees it: a Unix socket that leases `hosts`,
  idle ones oldest-released first, one per waiting connection, and takes
  them back. `released/1` lists `{host, result}` in order, `leases/1`
  each lease request as sent; a connection that closes holding a VM gives
  it back as `"dropped"`.
  """

  use GenServer

  def start(hosts) do
    # The OS pid too: unique integers start over each run, and a run cut
    # short leaves its sockets behind.
    path =
      Path.join(
        System.tmp_dir!(),
        "gate-fleet-#{System.pid()}-#{System.unique_integer([:positive])}.sock"
      )

    System.put_env("GATE_FLEET_SOCKET", path)
    start(hosts, path)
  end

  @doc "Starts one on `path`, as rigd does again on its socket after a restart."
  def start(hosts, path) do
    {:ok, pid} = GenServer.start(__MODULE__, {path, hosts})
    pid
  end

  def released(pid), do: GenServer.call(pid, :released)
  def waiting(pid), do: GenServer.call(pid, :waiting)
  def leases(pid), do: GenServer.call(pid, :leases)
  def path(pid), do: GenServer.call(pid, :path)
  def stop(pid), do: GenServer.stop(pid)

  @impl true
  def init({path, hosts}) do
    File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ifaddr: {:local, path}])

    me = self()
    spawn_link(fn -> accept(listen, me) end)
    {:ok, %{idle: hosts, waiting: [], held: %{}, released: [], leases: [], path: path}}
  end

  @impl true
  def terminate(_, st), do: File.rm(st.path)

  defp accept(listen, owner) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        :ok = :gen_tcp.controlling_process(sock, owner)
        send(owner, {:conn, sock})
        accept(listen, owner)

      _ ->
        :ok
    end
  end

  @impl true
  def handle_call(:released, _from, st), do: {:reply, Enum.reverse(st.released), st}
  def handle_call(:waiting, _from, st), do: {:reply, length(st.waiting), st}
  def handle_call(:leases, _from, st), do: {:reply, Enum.reverse(st.leases), st}
  def handle_call(:path, _from, st), do: {:reply, st.path, st}

  @impl true
  def handle_info({:conn, sock}, st) do
    :inet.setopts(sock, active: true)
    {:noreply, st}
  end

  def handle_info({:tcp, sock, line}, st) do
    st =
      case JSON.decode!(line) do
        %{"lease" => lease} ->
          grant(%{st | waiting: st.waiting ++ [sock], leases: [lease | st.leases]})

        %{"release" => %{"sprite" => s, "result" => r}} ->
          :gen_tcp.send(sock, JSON.encode!(%{released: s}) <> "\n")
          back(st, sock, s, r)
      end

    {:noreply, st}
  end

  def handle_info({:tcp_closed, sock}, st) do
    st = %{st | waiting: List.delete(st.waiting, sock)}

    case st.held[sock] do
      nil -> {:noreply, st}
      s -> {:noreply, back(st, sock, s, "dropped")}
    end
  end

  defp back(st, sock, s, r) do
    grant(%{
      st
      | held: Map.delete(st.held, sock),
        idle: st.idle ++ [s],
        released: [{s, r} | st.released]
    })
  end

  defp grant(%{waiting: [sock | waiting], idle: [s | idle]} = st) do
    :gen_tcp.send(sock, JSON.encode!(%{granted: s}) <> "\n")
    grant(%{st | waiting: waiting, idle: idle, held: Map.put(st.held, sock, s)})
  end

  defp grant(st), do: st
end
