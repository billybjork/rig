defmodule Gate.CheckTest do
  # The fakes are on PATH, their VMs in $FAKE_VMS and Fleet's socket in
  # $GATE_FLEET_SOCKET, all global.
  use ExUnit.Case, async: false

  alias Gate.{Fake, FakeFleet}
  import Gate.Fake, only: [vm: 1]

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} = context do
    env = Fake.setup(tmp, Map.get(context, :gate, %{}))
    on_exit(fn -> Fake.stop(env.root) end)
    env
  end

  defp check(%{top: top}, parts) do
    Fake.parts(top, parts)
    Fake.capture(fn -> Gate.Check.main(Fake.config(top), []) end)
  end

  defp until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> raise "timed out"
      true -> Process.sleep(25) && until(fun, tries - 1)
    end
  end

  # The newest log of `part`, on `host` or any.
  defp log(%{logs: logs}, part, host \\ "*") do
    logs |> Path.join("#{host}-*-#{part}.log") |> Path.wildcard() |> Enum.max() |> File.read!()
  end

  defp commit(env, message),
    do:
      Fake.git(env.top, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qam", message])

  @tag gate: %{
         "warm" => [
           %{"name" => "plt", "parts" => ["static"], "key" => [".gate.json"], "command" => "true"}
         ]
       }
  test "green when every part is: a leased VM each, given back green, the row in the worker's format",
       env do
    fleet = Fake.fleet([vm(1), vm(2)])

    {status, out, err} =
      check(env, [{"static", "bash cmd.sh green"}, {"test-1", "bash cmd.sh green"}])

    assert status == 0, err
    assert out == ""
    assert err =~ "as 2 parts on exe.dev"
    assert err =~ "green in"

    [row] = Fake.rows(env.logs)
    assert [_at, sha, "check", "green", _wall, static, test] = String.split(row, "\t")
    assert sha =~ ~r/\A[0-9a-f]{40}\z/
    assert static =~ ~r/\Astatic:\d+:vm-[12]\.exe\.xyz:green\z/
    assert test =~ ~r/\Atest-1:\d+:vm-[12]\.exe\.xyz:green\z/
    assert Enum.map(FakeFleet.released(fleet), &elem(&1, 1)) == ~w(green green)

    # Each part asks for an exe.dev VM, naming the warm keys it needs.
    leases = Enum.sort_by(FakeFleet.leases(fleet), & &1["part"])
    assert [%{"pool" => "exe", "warm" => [key]}, %{"pool" => "exe", "warm" => []}] = leases
    assert key =~ ~r/^[0-9a-f]{16}$/

    log = log(env, "static")
    # A fresh VM has no stamp: it takes the commit's tools first.
    assert log =~ "refreshing tools"
    assert log =~ "provisioning"
    assert log =~ "setup ran"
    assert log =~ "all good"
    assert Gate.last_line(log) == "sprite-gate: exit 0"

    [part] = Path.wildcard(Path.join(env.root, "vm-*/home/parts/*-static-*"))
    assert File.read!(Path.join(part, "launch.sh")) =~ "exe.dev VM"
    assert File.read!(Path.join(part, "vars")) =~ "WARM_NAMES=('plt')"
  end

  test "a VM whose last tip this checkout lacks gets only the commits since the newest first parent it holds",
       env do
    Fake.fleet([vm(1)])
    {status, _out, err} = check(env, [{"static", "bash cmd.sh green"}])
    assert status == 0, err
    held = env.top |> Fake.git(["rev-parse", "HEAD"]) |> String.trim()

    # Another checkout left a commit on the VM that this one never had.
    repo = Path.join(env.root, "vm-1.exe.xyz/home/proj")

    Fake.git(repo, [
      "-c",
      "user.name=t",
      "-c",
      "user.email=t@t",
      "commit",
      "-q",
      "--allow-empty",
      "-m",
      "elsewhere"
    ])

    Fake.git(repo, ["update-ref", "refs/laptop/gate", "HEAD"])

    File.write!(Path.join(env.top, "new.txt"), "new\n")
    Fake.git(env.top, ["add", "."])
    commit(env, "new")

    {status, _out, err} = check(env, [{"static", "bash cmd.sh green"}])
    assert status == 0, err
    [bundle] = Path.wildcard(Path.join(env.root, "vm-1.exe.xyz/home/parts/*/in.bundle"))
    header = bundle |> File.read!() |> String.split("\n\n", parts: 2) |> hd()
    assert header =~ "\n-#{held}", "the bundle should stop at the commit the VM holds"
    assert log(env, "static") =~ ~r/gate: uploaded [\d.]+ MB in \d+ s/
  end

  test "a red part fails the gate, never reruns, and prints a digest of its failing tests", env do
    fleet = Fake.fleet([vm(1), vm(2), vm(3)])

    {status, out, _err} =
      check(env, [{"static", "bash cmd.sh green"}, {"test-1", "bash cmd.sh red"}])

    assert status == 1
    assert out =~ ~r/== test-1 on vm-\d\.exe\.xyz \(exit 1\)/
    assert out =~ "1) test the widget works (WidgetTest)"
    assert out =~ "3 tests, 1 failure"
    [row] = Fake.rows(env.logs)
    assert row =~ "\tred\t"
    assert row =~ ~r/test-1:\d+:vm-\d\.exe\.xyz:red$/
    assert Enum.sort(Enum.map(FakeFleet.released(fleet), &elem(&1, 1))) == ~w(green red)
    assert length(FakeFleet.leases(fleet)) == 2
  end

  test "a VM that refuses ssh fails the part, which reruns on the next VM leased", env do
    fleet = Fake.fleet([vm(1), vm(2)])
    File.touch!(Path.join(env.root, "vm-1.exe.xyz/down"))
    {status, _out, err} = check(env, [{"static", "bash cmd.sh green"}])

    assert status == 0, err
    assert err =~ "could not ask vm-1.exe.xyz what it holds"
    assert err =~ "rerunning on vm-2.exe.xyz"
    [row] = Fake.rows(env.logs)
    assert row =~ ~r/\tstatic:\d+:vm-2\.exe\.xyz:green:reran-from-vm-1\.exe\.xyz\z/
    assert FakeFleet.released(fleet) == [{vm(1), "restarted"}, {vm(2), "green"}]
  end

  test "no verdict when a part's rerun fails too: neither green nor red", env do
    Fake.fleet([vm(1), vm(2)])
    File.touch!(Path.join(env.root, "vm-1.exe.xyz/down"))
    File.touch!(Path.join(env.root, "vm-2.exe.xyz/down"))

    {status, out, err} = check(env, [{"static", "bash cmd.sh green"}])

    assert status == 2
    assert out == ""
    assert err =~ "no verdict"
    [row] = Fake.rows(env.logs)
    assert row =~ "\tnone\t"
    assert row =~ "sprite-failed"
  end

  test "a native crash is given back as crashed and reruns on the next VM leased", env do
    fleet = Fake.fleet([vm(1), vm(2)])
    {status, _out, err} = check(env, [{"static", "bash cmd.sh crash-once"}])
    assert status == 0, err
    assert err =~ "a process crashed on vm-1.exe.xyz"
    assert FakeFleet.released(fleet) == [{vm(1), "crashed"}, {vm(2), "green"}]
    [row] = Fake.rows(env.logs)
    assert row =~ ":vm-2.exe.xyz:green:reran-from-vm-1.exe.xyz"

    assert log(env, "static", vm(1)) =~
             "a native crash, not a gate result; rerunning on the next VM the fleet leases"
  end

  test "a core the command left is named in its log, and only the newest three stay", env do
    Fake.fleet([vm(1)])
    {status, _out, _err} = check(env, [{"static", "bash cmd.sh core"}])
    assert status == 1

    assert log(env, "static") =~
             "sprite-gate: core " <>
               Path.join(
                 env.root,
                 "vm-1.exe.xyz/home/cores/core.!opt!node-20.1!bin!node.42.1761700000"
               ) <>
               " (/opt/node-20.1/bin/node)"

    assert env.root |> Path.join("vm-1.exe.xyz/home/cores") |> File.ls!() |> length() == 3
  end

  @tag gate: %{"limits" => %{"poll" => 0.1, "run" => 2, "unreachable" => 5, "launch" => 10}}
  test "a part past its run limit is ended on its VM and reruns on the next", env do
    fleet = Fake.fleet([vm(1), vm(2)])
    {status, _out, err} = check(env, [{"static", "bash cmd.sh slow-once"}])

    assert status == 0, err
    assert err =~ "its run phase outlasted 2 s"
    assert FakeFleet.released(fleet) == [{vm(1), "failed"}, {vm(2), "green"}]
    # Ended there, not left running: its command never got to its end.
    Process.sleep(500)
    refute log(env, "static", vm(1)) =~ "never"
    {ps, _} = System.cmd("pgrep", ["-f", Path.join(env.root, "vm-1.exe.xyz")])
    assert ps == ""
  end

  test "a part whose VM restarted keeps its lease and is relaunched there; restarted again, it is given back as restarted",
       env do
    fleet = Fake.fleet([vm(1), vm(2)])
    {status, _out, err} = check(env, [{"static", "bash cmd.sh restart-once"}])
    assert status == 0, err
    assert err =~ "static: vm-1.exe.xyz restarted; rerunning it there"
    assert [{"vm-1.exe.xyz", "green"}] = FakeFleet.released(fleet)

    {status, _out, err} = check(env, [{"static", "bash cmd.sh restarts 2"}])
    assert status == 0, err
    assert err =~ "restarted mid-part (life life-"
    assert [_, {first, "restarted"}, {second, "green"}] = FakeFleet.released(fleet)
    assert first != second
    assert List.last(Fake.rows(env.logs)) =~ ~r/\tstatic:\d+:#{second}:green:reran-from-#{first}/
  end

  test "a VM that stops answering mid-part fails it after the unreachable limit", env do
    fleet = Fake.fleet([vm(1), vm(2)])
    {status, _out, err} = check(env, [{"static", "bash cmd.sh vanish-once"}])

    assert status == 0, err
    assert err =~ "unreachable for 2 s"
    assert FakeFleet.released(fleet) == [{vm(1), "restarted"}, {vm(2), "green"}]
  end

  @tag gate: %{
         "warm" => [
           %{
             "name" => "plt",
             "parts" => ["static*"],
             "key" => ["cmd.sh"],
             "command" => "bash cmd.sh warm 3"
           }
         ],
         "limits" => %{"poll" => 0.1, "run" => 2, "unreachable" => 5, "launch" => 10}
       }
  test "a warm cache builds before its part, outside the run limit, once per key; a restart while warming relaunches it on the same VM",
       env do
    # One VM, so each part finds what the last left.
    Fake.fleet([vm(1)])
    File.touch!(Path.join(env.root, "warm-restarted"))
    parts = [{"static-1", "bash cmd.sh green"}, {"test-1", "bash cmd.sh green"}]
    {status, _out, err} = check(env, parts)
    # The cache took 3 s; the run limit is 2.
    assert status == 0, err
    assert File.read!(Path.join(env.root, "warms")) == "warm run\n"
    assert log(env, "static-1") =~ "warmed plt"
    refute log(env, "test-1") =~ "warming plt"

    # The same key: no build.
    {0, _, _} = check(env, parts)
    assert File.read!(Path.join(env.root, "warms")) == "warm run\n"

    # A restart while warming: the part relaunches where the cache was half built.
    File.rm!(Path.join(env.root, "warm-restarted"))
    File.write!(Path.join(env.top, "cmd.sh"), File.read!(Path.join(env.top, "cmd.sh")) <> "\n")
    commit(env, "a new key")

    {status, _out, err} = check(env, parts)
    assert status == 0, err
    assert err =~ "vm-1.exe.xyz restarted while warming; relaunching it there"
    assert File.read!(Path.join(env.root, "warms")) == "warm run\nwarm run\nwarm run\n"
    assert List.last(Fake.rows(env.logs)) =~ ~r/static-1:\d+:vm-1\.exe\.xyz:green\t/
  end

  @tag gate: %{"image" => [".tool-versions"], "stamp" => nil, "provision" => nil}
  test "a project on the image: rig's image script provisions it, and the stamp covers that script",
       env do
    Fake.fleet([vm(1)])
    image = Path.join(env.tmp, "image.sh")

    File.write!(image, ~S"""
    echo "image for $2 from $3"
    echo "$1" >~/"$2-stamp"
    """)

    System.put_env("GATE_IMAGE", image)
    on_exit(fn -> System.delete_env("GATE_IMAGE") end)

    {status, _out, err} = check(env, [{"static", "bash cmd.sh green"}])

    assert status == 0, err
    assert log(env, "static") =~ ~r"image for proj from \S+/proj/\.tool-versions"

    want =
      :crypto.hash(:sha256, [File.read!(Path.join(env.top, ".tool-versions")), File.read!(image)])
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    assert File.read!(Path.join(env.root, "vm-1.exe.xyz/home/proj-stamp")) == want <> "\n"
  end

  test "the stamp is the hash of the stamp files at the commit, in order, as the old pools' was",
       env do
    expected =
      :crypto.hash(:sha256, [
        File.read!(Path.join(env.top, ".tool-versions")),
        File.read!(Path.join(env.top, "provision.sh"))
      ])
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    sha = Fake.git(env.top, ["rev-parse", "HEAD"]) |> String.trim()
    assert Gate.Stamp.stamp(Fake.config(env.top), sha) == expected
  end

  @tag gate: %{
         "warm" => [
           %{"name" => "plt", "parts" => ["static"], "key" => [".gate.json"], "command" => "true"}
         ]
       }
  test "gate keys names the stamp and each warm cache's key at a commit", env do
    config = Fake.config(env.top)
    sha = Gate.Check.git!(config, ["rev-parse", "HEAD"])
    stamp = Gate.Stamp.stamp(config, sha)
    [{name, ^stamp}, {warm, key}] = Gate.Stamp.keys(config, sha)
    assert warm == name <> "-plt"
    assert key == Gate.Stamp.warm_key(config, sha, stamp, hd(config.warm))

    # A warm cache's key changes with its command, not only its files.
    other = Map.put(hd(config.warm), "command", "true --other")
    refute Gate.Stamp.warm_key(config, sha, stamp, other) == key
  end

  test "bin/gate runs the gate in the checkout", env do
    Fake.fleet([vm(1)])
    Fake.parts(env.top, [{"static", "bash cmd.sh green"}])

    {out, status} =
      System.cmd(Path.join(Gate.root(), "bin/gate"), ["check"],
        cd: env.top,
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert out =~ "check-remote: green in"
  end

  test "a gate stopped from outside ends the parts it launched on their VMs", env do
    Fake.fleet([vm(1)])
    Fake.parts(env.top, [{"static", "bash cmd.sh slow-once"}])
    gate = Path.join(Gate.root(), "bin/gate")

    port =
      Port.open({:spawn_executable, gate}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["check"],
        cd: env.top
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

  describe "a commit from before exe.dev" do
    @tag gate: %{"pool" => "fleet"}
    test "naming the shared Sprite pool is refused, saying why", env do
      error = assert_raise Gate.Error, fn -> check(env, [{"static", "bash cmd.sh green"}]) end
      assert error.message =~ "the Sprites are gone"
      assert error.message =~ ~s("pool": "fleet")
      assert error.message =~ "rebase onto origin/main"
    end

    @tag gate: %{"pool" => ["gate-1", "gate-2"], "dev" => ["dev-1"], "locks" => "/tmp/x"}
    test "naming its own Sprites is refused too; its Sprite keys are only ignored", env do
      config = Fake.config(env.top)
      refute Map.has_key?(config, :dev)
      error = assert_raise Gate.Error, fn -> check(env, [{"static", "bash cmd.sh green"}]) end
      assert error.message =~ ~s("pool": ["gate-1","gate-2"])
    end
  end

  describe "leased from Fleet" do
    test "a part waiting for a lease when rigd restarts asks the new Fleet, and keeps its gate",
         env do
      fleet = Fake.fleet([])
      path = FakeFleet.path(fleet)
      me = self()

      spawn_link(fn ->
        until(fn -> FakeFleet.waiting(fleet) == 1 end)
        FakeFleet.stop(fleet)
        Process.sleep(300)
        send(me, {:fleet, FakeFleet.start([vm(1)], path)})
      end)

      {status, _out, err} = check(env, [{"static", "bash cmd.sh green"}])
      assert status == 0, err
      assert_received {:fleet, again}
      assert FakeFleet.released(again) == [{vm(1), "green"}]
      FakeFleet.stop(again)
    end

    test "a part whose Fleet does not come back within the reconnect time has no verdict",
         env do
      System.put_env("GATE_FLEET_RECONNECT", "1")
      on_exit(fn -> System.delete_env("GATE_FLEET_RECONNECT") end)
      fleet = Fake.fleet([])

      spawn_link(fn ->
        until(fn -> FakeFleet.waiting(fleet) == 1 end)
        FakeFleet.stop(fleet)
      end)

      assert_raise Gate.Error, ~r/rigd's Fleet went mid-gate/, fn ->
        check(env, [{"static", "bash cmd.sh green"}])
      end
    end

    @tag gate: %{
           "limits" => %{
             "poll" => 0.1,
             "run" => 20,
             "unreachable" => 2,
             "launch" => 10,
             "stage" => 1
           }
         }
    test "an upload that outlasts its limit is the laptop's link: given back as restarted, not failed",
         env do
      fleet = Fake.fleet([vm(1), vm(2)])
      File.write!(Path.join(env.root, "vm-1.exe.xyz/slow-stage"), "3")
      {status, _out, err} = check(env, [{"static", "bash cmd.sh green"}])
      assert status == 0, err
      assert err =~ "the upload outlasted 1 s"

      assert [{"vm-1.exe.xyz", "restarted"}, {"vm-2.exe.xyz", "green"}] =
               FakeFleet.released(fleet)
    end

    test "no verdict when rigd's Fleet does not answer", env do
      System.put_env("GATE_FLEET_SOCKET", "/nonexistent/fleet.sock")
      on_exit(fn -> System.delete_env("GATE_FLEET_SOCKET") end)
      Fake.parts(env.top, [{"static", "bash cmd.sh green"}])

      assert_raise Gate.Error, ~r/Fleet does not answer/, fn ->
        Gate.Check.main(Fake.config(env.top), [])
      end
    end
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("never happened")
      true -> Process.sleep(100) && wait_until(fun, tries - 1)
    end
  end
end
