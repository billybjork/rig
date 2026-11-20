defmodule Gate.ExeTest do
  # The fake ssh, su and Sprite CLI are on PATH, their hosts in
  # $FAKE_SPRITES, all global.
  use ExUnit.Case, async: false

  alias Gate.{Exe, Fake}

  @moduletag :tmp_dir
  @vms ~w(vm-1.exe.xyz vm-2.exe.xyz vm-3.exe.xyz)

  setup %{tmp_dir: tmp} = context do
    env = Fake.setup(tmp, @vms, Map.get(context, :gate, %{}))
    on_exit(fn -> Fake.stop(env.root) end)
    env
  end

  defp check(%{top: top}, parts) do
    Fake.parts(top, parts)
    Fake.capture(fn -> Gate.Check.main(Fake.config(top), []) end)
  end

  defp log(%{logs: logs}, vm, part) do
    [file] = Path.wildcard(Path.join(logs, "#{vm}-*-#{part}.log"))
    File.read!(file)
  end

  defp calls(%{root: root}), do: File.read!(Path.join(root, "calls"))

  test "a host named <vm>.exe.xyz is an exe.dev VM; any other is a Sprite" do
    assert Gate.Host.backend("rig-golden.exe.xyz") == Exe
    assert Gate.Host.backend("gate-1") == Gate.Sprite
    assert Gate.Host.backend("exe.xyz.example") == Gate.Sprite
  end

  test "exe's one host key is pinned for every VM name" do
    known = File.read!(Path.join(Gate.Sprite.root(), "exe/known_hosts"))
    assert [_] = Regex.scan(~r/^\*\.exe\.xyz ssh-rsa AAAA\S+$/m, known)
  end

  test "a command's words reach the VM whole, through ssh and su", env do
    args = ["two words", "it's", ~S($HOME "q" `x` \n), ""]

    {out, 0} =
      Exe.call("vm-1.exe.xyz", ~S|printf '<%s>\n' "$@"|, "echo", args, 10, boot: true)

    assert out == Enum.map_join(args, "", &"<#{&1}>\n")
    # The boot step ran first, as root, before `su - gate`.
    assert calls(env) =~ ~r/vm-1\.exe\.xyz ssh bash -c '.*' base\.sh boot && exec su - gate -c/s
  end

  test "a gate on exe.dev VMs: no keeper, no local disk", env do
    {status, out, err} =
      check(env, [{"static", "bash cmd.sh green"}, {"test-1", "bash cmd.sh green"}])

    assert status == 0, err
    assert out == ""
    assert err =~ "as 2 parts on vm-1.exe.xyz vm-2.exe.xyz, spare vm-3.exe.xyz"

    [row] = Fake.rows(env.logs)
    assert row =~ ~r/\tstatic:\d+:vm-1\.exe\.xyz:green\t/

    log = log(env, "vm-1.exe.xyz", "static")
    assert log =~ "setup ran"
    assert log =~ "all good"
    assert Gate.Sprite.last_line(log) == "sprite-gate: exit 0"
    refute log =~ "its keeper had gone"

    [part] = Path.wildcard(Path.join(env.root, "vm-1.exe.xyz/home/parts/*"))
    vars = File.read!(Path.join(part, "vars"))
    assert vars =~ "LOCAL_OFF=1"
    assert vars =~ "LOCAL_PATHS=()"
    assert vars =~ "HOST=exe"
    assert File.read!(Path.join(part, "launch.sh")) =~ "exe.dev VM"
    refute File.exists?(Path.join(part, "keeper.pid"))
    # Every call went over ssh, none through the Sprite CLI.
    refute calls(env) =~ ~r/^vm-\d\.exe\.xyz bash /m
  end

  test "a part whose VM restarted is relaunched there", env do
    {status, _out, err} =
      check(env, [{"static", "bash cmd.sh restart-once"}, {"test-1", "bash cmd.sh green"}])

    assert status == 0, err
    assert err =~ "static: vm-1.exe.xyz restarted; rerunning it there"
    [row] = Fake.rows(env.logs)
    assert row =~ ~r/\tstatic:\d+:vm-1\.exe\.xyz:green\t/
  end

  @tag gate: %{"limits" => %{"poll" => 0.1, "run" => 2, "unreachable" => 5, "launch" => 10}}
  test "a part past its run limit is ended on its VM and reruns on the spare", env do
    {status, _out, err} =
      check(env, [{"static", "bash cmd.sh slow-once"}, {"test-1", "bash cmd.sh green"}])

    assert status == 0, err
    assert err =~ "its run phase outlasted 2 s"
    Process.sleep(500)
    refute log(env, "vm-1.exe.xyz", "static") =~ "never"
    {ps, _} = System.cmd("pgrep", ["-f", Path.join(env.root, "vm-1.exe.xyz")])
    assert ps == ""
  end

  test "a VM that refuses ssh fails the part, which reruns on the spare", env do
    File.write!(Path.join(env.root, "vm-1.exe.xyz/down"), "")
    {status, _out, err} = check(env, [{"static", "bash cmd.sh green"}])

    assert status == 0, err
    assert err =~ "could not ask vm-1.exe.xyz what it holds"
    [row] = Fake.rows(env.logs)
    assert row =~ ~r/\tstatic:\d+:vm-3\.exe\.xyz:green:reran-from-vm-1\.exe\.xyz\z/
  end

  test "a gate stopped from outside ends the parts it launched on their VMs", env do
    Fake.parts(env.top, [{"static", "bash cmd.sh slow-once"}])
    gate = Path.join(Gate.Sprite.root(), "bin/gate")

    port =
      Port.open({:spawn_executable, gate}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["check"],
        cd: env.top,
        env: [{~c"GATE_POOL_HELD", ~c"1"}]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    job = Path.join(env.root, "vm-1.exe.xyz/home/parts")

    wait_until(fn ->
      match?([_], Path.wildcard(Path.join(job, "*/phase"))) and
        File.read!(hd(Path.wildcard(Path.join(job, "*/phase")))) =~ "run"
    end)

    System.cmd("kill", ["-TERM", to_string(pid)])
    assert_receive {^port, {:exit_status, 143}}, 20_000
    [pidfile] = Path.wildcard(Path.join(job, "*/job.pid"))

    {_, status} =
      System.cmd("kill", ["-0", File.read!(pidfile) |> String.trim()], stderr_to_stdout: true)

    assert status != 0, "the part still runs on its VM"
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("never happened")
      true -> Process.sleep(100) && wait_until(fun, tries - 1)
    end
  end
end
