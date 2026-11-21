defmodule Rigd.FleetExeTest do
  use ExUnit.Case, async: false

  alias Rigd.Fleet.Exe

  @moduletag :tmp_dir
  @moduletag :capture_log

  @keys %{"proj" => "0123456789abcdef", "proj-plt" => "1111111111111111"}
  @newer %{"proj" => "fedcba9876543210", "proj-plt" => "2222222222222222"}

  # `ssh` as Fleet calls it: `exe.dev <command>` against VMs that are
  # directories under $FAKE_EXE/vms (files `status`, `comment`, `created`),
  # and `<vm>.exe.xyz true`, which answers while the VM is there. Every
  # call is appended to `calls`; `cp-fails` makes the next cp fail.
  @ssh ~S"""
  #!/bin/bash
  root=$FAKE_EXE
  while [ "${1:-}" = -o ]; do shift 2; done
  host=$1; shift
  echo "$host $*" >>"$root/calls"
  if [ "$host" != exe.dev ]; then
    [ -d "$root/vms/${host%.exe.xyz}" ] && exit 0
    echo "ssh: connect to host $host port 22: Connection refused"; exit 255
  fi
  vm=$root/vms
  case "$1" in
    ls)
      sep=; printf '{"vms":['
      for d in "$vm"/*/; do
        [ -d "$d" ] || continue
        n=$(basename "$d")
        printf '%s{"vm_name":"%s","status":"%s","comment":"%s","created_at":"%s"}' \
          "$sep" "$n" "$(cat "$d/status")" "$(cat "$d/comment" 2>/dev/null)" "$(cat "$d/created")"
        sep=,
      done
      printf ']}\n' ;;
    cp)
      [ -f "$root/cp-fails" ] && { rm "$root/cp-fails"; echo "error: no capacity"; exit 1; }
      [ -d "$vm/$2" ] || { echo "error: VM \"$2\" not found"; exit 1; }
      mkdir -p "$vm/$3"
      cp "$vm/$2/comment" "$vm/$3/" 2>/dev/null
      echo running >"$vm/$3/status"
      n=$(($(cat "$root/seq" 2>/dev/null || echo 0) + 1)); echo $n >"$root/seq"
      printf '2026-11-21T%06d\n' $n >"$vm/$3/created" ;;
    rm) shift; for n; do
          if [ -d "$vm/$n" ]; then rm -rf "${vm:?}/$n"; else echo "VM \"$n\" not found"; fi
        done ;;
    comment) printf '%s' "$3" >"$vm/$2/comment" ;;
    pause) echo paused >"$vm/$2/status" ;;
  esac
  exit 0
  """

  defmodule Golden do
    @moduledoc "Each project's keys and setup as the test sets them in persistent_term."
    def keys(_gate, _dir), do: {:ok, :persistent_term.get({__MODULE__, :target})}
    def stamp(_gate, _dir), do: {:ok, "proj", "0123456789abcdef"}

    def run(_gate, _dir, host, :keys) do
      File.write!(:persistent_term.get({__MODULE__, :log}), "golden #{host}\n", [:append])

      case :persistent_term.get({__MODULE__, :result}, nil) do
        nil -> {:green, "proj", :persistent_term.get({__MODULE__, :target})}
        result -> result
      end
    end
  end

  setup %{tmp_dir: tmp} do
    root = Path.join(tmp, "exe")
    File.mkdir_p!(Path.join(root, "vms"))
    ssh = Path.join(tmp, "ssh")
    File.write!(ssh, @ssh)
    File.chmod!(ssh, 0o755)
    System.put_env("FAKE_EXE", root)
    :persistent_term.put({Golden, :target}, @keys)
    :persistent_term.put({Golden, :log}, Path.join(root, "golden.log"))
    on_exit(fn -> :persistent_term.erase({Golden, :result}) end)

    opts = [
      sprites: [],
      projects: ["/nowhere/proj"],
      gate: "/nowhere/gate/bin/gate",
      golden: Golden,
      socket: Path.join(System.tmp_dir!(), "fleet-#{System.unique_integer([:positive])}.sock"),
      cli: "/nowhere/sprite",
      deadline: Path.expand("../../gate/libexec/deadline", __DIR__),
      ssh: ssh,
      answer_ms: 10,
      exe: %{"golden" => "rig-golden", "max" => 2}
    ]

    %{root: root, opts: opts}
  end

  defp vm(root, name, status, comment, created \\ "2026-11-20T000001") do
    dir = Path.join([root, "vms", name])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "status"), status)
    File.write!(Path.join(dir, "comment"), comment)
    File.write!(Path.join(dir, "created"), created)
  end

  defp golden(root, keys \\ @keys, name \\ "rig-golden"),
    do: vm(root, name, "paused", Rigd.Fleet.Sprite.golden_comment(keys))

  defp vms(root), do: root |> Path.join("vms") |> File.ls!() |> Enum.sort()

  defp calls(root) do
    case File.read(Path.join(root, "calls")) do
      {:ok, text} -> text
      {:error, :enoent} -> ""
    end
  end

  defp start(opts), do: start_supervised!({Rigd.Fleet.Supervisor, opts})

  defp until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out: #{inspect(Exe.status())}")
      true -> Process.sleep(25) && until(fun, tries - 1)
    end
  end

  defp ready?(keys \\ @keys), do: Exe.status().keys == keys and Exe.status().target == keys

  defp lease(opts, warm \\ [], priority \\ nil) do
    {:ok, sock} =
      :gen_tcp.connect({:local, opts[:socket]}, 0, [:binary, packet: :line, active: false])

    lease = %{project: "proj", part: "p", pool: "exe", warm: warm}
    lease = if priority, do: Map.put(lease, :priority, priority), else: lease
    :ok = :gen_tcp.send(sock, JSON.encode!(%{lease: lease}) <> "\n")
    sock
  end

  defp recv(sock, timeout \\ 5000) do
    case :gen_tcp.recv(sock, 0, timeout) do
      {:ok, line} -> JSON.decode!(line)
      {:error, why} -> why
    end
  end

  defp release(sock, host, result \\ "green") do
    :ok = :gen_tcp.send(sock, JSON.encode!(%{release: %{sprite: host, result: result}}) <> "\n")
    recv(sock)
  end

  test "a lease is a fresh copy of the golden at 4 vCPU, granted once it answers; a release removes it",
       %{root: root, opts: opts} do
    golden(root)
    start(opts)
    until(&ready?/0)

    a = lease(opts, ["1111111111111111"])
    assert %{"granted" => host} = recv(a)
    name = String.replace_suffix(host, ".exe.xyz", "")
    assert name =~ ~r/^rig-part-/
    assert calls(root) =~ "exe.dev cp rig-golden #{name} --standalone --cpu=4 --memory=8GB"
    assert calls(root) =~ "#{host} true"
    assert name in vms(root)

    assert release(a, host, "red") == %{"released" => host}
    until(fn -> name not in vms(root) end)
    assert Exe.status().leases == %{}
  end

  test "a part needing a warm cache the golden lacks gets 8 vCPU / 16 GB", %{
    root: root,
    opts: opts
  } do
    golden(root)
    start(opts)
    until(&ready?/0)

    a = lease(opts, ["9999999999999999"])
    assert %{"granted" => host} = recv(a)
    name = String.replace_suffix(host, ".exe.xyz", "")
    assert calls(root) =~ "exe.dev cp rig-golden #{name} --standalone --cpu=8 --memory=16GB"
  end

  test "a holder that goes without releasing has its VM removed", %{root: root, opts: opts} do
    golden(root)
    start(opts)
    until(&ready?/0)

    a = lease(opts)
    assert %{"granted" => host} = recv(a)
    :gen_tcp.close(a)
    until(fn -> vms(root) == ["rig-golden"] end)
    assert calls(root) =~ "exe.dev rm #{String.replace_suffix(host, ".exe.xyz", "")}"
  end

  test "at most max leases at once; a ship's gate waits ahead of a session's",
       %{root: root, opts: opts} do
    golden(root)
    start(opts)
    until(&ready?/0)

    a = lease(opts)
    b = lease(opts)
    assert %{"granted" => ha} = recv(a)
    assert %{"granted" => _} = recv(b)
    c = lease(opts)
    until(fn -> Exe.status().waiting == 1 end)
    d = lease(opts, [], "ship")
    until(fn -> Exe.status().waiting == 2 end)
    assert recv(c, 200) == :timeout

    assert release(a, ha) == %{"released" => ha}
    assert %{"granted" => _} = recv(d)
    assert recv(c, 200) == :timeout
  end

  test "a copy that fails is tried again for the same waiter", %{root: root, opts: opts} do
    golden(root)
    File.write!(Path.join(root, "cp-fails"), "")
    start(opts)
    until(&ready?/0)

    a = lease(opts)
    assert %{"granted" => host} = recv(a, 10_000)
    assert String.replace_suffix(host, ".exe.xyz", "") in vms(root)
  end

  test "at start, part VMs nothing holds and a cut-off refresh are removed",
       %{root: root, opts: opts} do
    golden(root)
    vm(root, "rig-part-old", "running", "golden proj 0123456789abcdef")
    vm(root, "rig-golden-1120-cut", "running", "refreshing")
    vm(root, "soco-dev-1", "running", "")
    start(opts)
    until(fn -> vms(root) == ["rig-golden", "soco-dev-1"] end)
  end

  test "when origin/main's keys change, a new golden is made at 8 vCPU and the old one removed",
       %{root: root, opts: opts} do
    golden(root)
    start(opts)
    until(&ready?/0)

    :persistent_term.put({Golden, :target}, @newer)
    send(Exe, :keys)
    until(fn -> ready?(@newer) end)

    %{golden: name} = Exe.status()
    assert name =~ ~r/^rig-golden-/
    assert calls(root) =~ "exe.dev cp rig-golden #{name} --standalone --cpu=8 --memory=16GB"
    assert File.read!(Path.join(root, "golden.log")) == "golden #{name}.exe.xyz\n"
    assert File.read!(Path.join([root, "vms", name, "status"])) == "paused\n"
    until(fn -> vms(root) == [name] end)

    # The next lease copies the new golden.
    a = lease(opts)
    assert %{"granted" => _} = recv(a)
    assert calls(root) =~ "exe.dev cp #{name} rig-part-"
  end

  test "a seed without a golden comment is leased from, then refreshed", %{root: root, opts: opts} do
    vm(root, "rig-golden", "paused", "")
    start(opts)
    until(fn -> Exe.status().golden not in [nil, "rig-golden"] end)
    until(&ready?/0)
    until(fn -> vms(root) == [Exe.status().golden] end)
  end

  test "a refresh whose setup is red is dropped and the old golden kept",
       %{root: root, opts: opts} do
    golden(root)
    :persistent_term.put({Golden, :result}, {:red, "proj's golden setup exited 1"})
    :persistent_term.put({Golden, :target}, @newer)
    start(opts)
    until(fn -> (Exe.status().why || "") =~ "exited 1" end)
    until(fn -> vms(root) == ["rig-golden"] end)
    assert Exe.status().golden == "rig-golden"
  end

  test "a drain names the leases and the refresh under way", %{root: root, opts: opts} do
    golden(root)
    start(opts)
    until(&ready?/0)

    a = lease(opts)
    assert %{"granted" => host} = recv(a)
    name = String.replace_suffix(host, ".exe.xyz", "")
    assert %{leased: [^name], waiting: 0} = Exe.drain()
    b = lease(opts)
    until(fn -> Exe.status().waiting == 1 end)
    assert recv(b, 200) == :timeout
  end
end
