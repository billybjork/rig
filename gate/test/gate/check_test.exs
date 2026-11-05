defmodule Gate.CheckTest do
  # The fake CLI is on PATH and its Sprites in $FAKE_SPRITES, both global.
  use ExUnit.Case, async: false

  alias Gate.Fake

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} = context do
    env = Fake.setup(tmp, ~w(gate-1 gate-2 gate-3), Map.get(context, :gate, %{}))
    on_exit(fn -> Fake.stop(env.root) end)
    env
  end

  defp check(%{top: top}, parts) do
    Fake.parts(top, parts)
    Fake.capture(fn -> Gate.Check.main(Fake.config(top), []) end)
  end

  defp log(%{logs: logs}, sprite, part) do
    [file] = Path.wildcard(Path.join(logs, "#{sprite}-*-#{part}.log"))
    File.read!(file)
  end

  test "green when every part is: one Sprite each, the spare unused, the row in the worker's format",
       env do
    {status, out, err} =
      check(env, [{"static", "bash cmd.sh green"}, {"test-1", "bash cmd.sh green"}])

    assert status == 0, err
    assert out == ""
    assert err =~ "as 2 parts on gate-1 gate-2, spare gate-3"
    assert err =~ "green in"

    [row] = Fake.rows(env.logs)
    assert [_at, sha, "check", "green", _wall, static, test] = String.split(row, "\t")
    assert sha =~ ~r/\A[0-9a-f]{40}\z/
    assert static =~ ~r/\Astatic:\d+:gate-1:green\z/
    assert test =~ ~r/\Atest-1:\d+:gate-2:green\z/

    log = log(env, "gate-1", "static")
    # A fresh Sprite has no stamp: it takes the commit's tools first.
    assert log =~ "refreshing tools"
    assert log =~ "provisioning"
    assert log =~ "setup ran"
    assert log =~ "all good"
    assert Gate.Sprite.last_line(log) == "sprite-gate: exit 0"
  end

  test "a red part fails the gate, never reruns, and prints a digest of its failing tests", env do
    {status, out, _err} =
      check(env, [{"static", "bash cmd.sh green"}, {"test-1", "bash cmd.sh red"}])

    assert status == 1
    assert out =~ "== test-1 on gate-2 (exit 1)"
    assert out =~ "1) test the widget works (WidgetTest)"
    assert out =~ "3 tests, 1 failure"
    [row] = Fake.rows(env.logs)
    assert row =~ "\tred\t"
    assert row =~ ~r/test-1:\d+:gate-2:red$/
    refute File.exists?(Path.join(env.root, "gate-3/home/parts"))
  end

  test "a Sprite that cannot take the part: it reruns on the spare, and the gate says so", env do
    File.touch!(Path.join(env.root, "gate-2/down"))

    {status, _out, err} =
      check(env, [{"static", "bash cmd.sh green"}, {"test-1", "bash cmd.sh green"}])

    assert status == 0, err
    assert err =~ "test-1: gate-2 failed"
    assert err =~ "rerunning on gate-3"
    [row] = Fake.rows(env.logs)
    assert row =~ ~r/test-1:\d+:gate-3:green:reran-from-gate-2$/
  end

  test "two Sprites fail: one part reruns on the spare, the other there once the first ends",
       env do
    File.touch!(Path.join(env.root, "gate-1/down"))
    File.touch!(Path.join(env.root, "gate-2/down"))

    {status, _out, err} =
      check(env, [{"static", "bash cmd.sh green"}, {"test-1", "bash cmd.sh green"}])

    assert status == 0, err
    [row] = Fake.rows(env.logs)

    assert row =~
             ~r/static:\d+:gate-3:green:reran-from-gate-1\ttest-1:\d+:gate-3:green:reran-from-gate-2$/

    assert err =~ "reran static on gate-3, test-1 on gate-3"
  end

  test "a crash reruns on a Sprite whose own part has ended when the spare is taken", env do
    File.touch!(Path.join(env.root, "gate-2/down"))

    {status, _out, err} =
      check(env, [{"static", "bash cmd.sh crash-once"}, {"test-1", "bash cmd.sh green"}])

    assert status == 0, err
    [row] = Fake.rows(env.logs)

    assert row =~
             ~r/static:\d+:gate-3:green:reran-from-gate-1\ttest-1:\d+:gate-3:green:reran-from-gate-2$/
  end

  @tag gate: %{"limits" => %{"poll" => 0.1, "launch" => 2}}
  test "a launch whose line never came through but whose job runs is launched, not a failed Sprite",
       env do
    File.touch!(Path.join(env.root, "gate-1/tty-silent"))

    {status, _out, err} =
      check(env, [{"static", "bash cmd.sh green"}, {"test-1", "bash cmd.sh green"}])

    assert status == 0, err
    refute err =~ "failed"
    [row] = Fake.rows(env.logs)
    assert row =~ ~r/static:\d+:gate-1:green\t/
  end

  @tag gate: %{"limits" => %{"poll" => 0.1, "launch" => 60}}
  test "a launch line lost among the keeper's dots is read from the Sprite at the first dot",
       env do
    File.touch!(Path.join(env.root, "gate-1/tty-lossy"))
    lost = Path.join(env.tmp, "lost")
    System.put_env("GATE_LOST_LAUNCH", lost)
    on_exit(fn -> System.delete_env("GATE_LOST_LAUNCH") end)
    parts = [{"static", "bash cmd.sh sleep 6"}, {"test-1", "bash cmd.sh green"}]
    t0 = System.monotonic_time(:second)
    {status, _out, err} = check(env, parts)
    assert status == 0, err
    refute err =~ "failed"
    assert System.monotonic_time(:second) - t0 < 30
    # What the TTY showed is kept, to learn what hid the line.
    assert [raw] = File.ls!(lost)
    assert File.read!(Path.join(lost, raw)) =~ "garbled"
  end

  test "no verdict when a part's rerun fails too: neither green nor red", env do
    File.touch!(Path.join(env.root, "gate-2/down"))
    File.touch!(Path.join(env.root, "gate-3/down"))

    {status, out, err} =
      check(env, [{"static", "bash cmd.sh green"}, {"test-1", "bash cmd.sh green"}])

    assert status == 2
    assert out == ""
    assert err =~ "no verdict"
    [row] = Fake.rows(env.logs)
    assert row =~ "\tnone\t"
    assert row =~ "sprite-failed"
  end

  test "a native crash reruns on the spare and is judged there", env do
    {status, _out, err} =
      check(env, [{"static", "bash cmd.sh crash-once"}, {"test-1", "bash cmd.sh green"}])

    assert status == 0, err
    assert err =~ "a process crashed on gate-1"
    [row] = Fake.rows(env.logs)
    assert row =~ ~r/static:\d+:gate-3:green:reran-from-gate-1/
    assert log(env, "gate-1", "static") =~ "a native crash, not a gate result; reran on gate-3"
    # A crashed Sprite is not free again: nothing else runs on gate-1.
    assert row =~ ~r/test-1:\d+:gate-2:green$/
  end

  test "a core the command left is named in its log, and only the newest three stay", env do
    {status, _out, _err} =
      check(env, [{"static", "bash cmd.sh core"}, {"test-1", "bash cmd.sh green"}])

    assert status == 1

    assert log(env, "gate-1", "static") =~
             "sprite-gate: core " <>
               Path.join(env.root, "gate-1/home/cores/core.!opt!node-20.1!bin!node.42.1761700000") <>
               " (/opt/node-20.1/bin/node)"

    assert env.root |> Path.join("gate-1/home/cores") |> File.ls!() |> length() == 3
  end

  @tag gate: %{"limits" => %{"poll" => 0.1, "run" => 2, "unreachable" => 5, "launch" => 10}}
  test "a part past its run limit is ended on its Sprite and reruns on the spare", env do
    {status, _out, err} =
      check(env, [{"static", "bash cmd.sh slow-once"}, {"test-1", "bash cmd.sh green"}])

    assert status == 0, err
    assert err =~ "its run phase outlasted 2 s"
    # Ended there, not left running: its command never got to its end.
    Process.sleep(500)
    refute log(env, "gate-1", "static") =~ "never"
    {ps, _} = System.cmd("pgrep", ["-f", Path.join(env.root, "gate-1")])
    assert ps |> String.split() |> Enum.reject(&tail_client?/1) == []
  end

  test "a part whose Sprite restarted is relaunched there; restarted again, it reruns on the spare",
       env do
    {status, _out, err} =
      check(env, [{"static", "bash cmd.sh restart-once"}, {"test-1", "bash cmd.sh green"}])

    assert status == 0, err
    assert err =~ "static: gate-1 restarted; rerunning it there"
    [row] = Fake.rows(env.logs)
    assert row =~ ~r/\tstatic:\d+:gate-1:green\t/
    assert File.read!(Path.join(env.root, "gate-3/home/.life")) == "life-1\n"
    refute File.exists?(Path.join(env.root, "gate-3/home/parts"))

    {status, _out, err} =
      check(env, [{"static", "bash cmd.sh restarts 2"}, {"test-1", "bash cmd.sh green"}])

    assert status == 0, err
    assert err =~ "restarted mid-part (life life-"
    assert List.last(Fake.rows(env.logs)) =~ ~r/\tstatic:\d+:gate-3:green:reran-from-gate-1/
  end

  test "a Sprite that stops answering mid-part fails it after the unreachable limit", env do
    {status, _out, err} =
      check(env, [{"static", "bash cmd.sh vanish-once"}, {"test-1", "bash cmd.sh green"}])

    assert status == 0, err
    assert err =~ "unreachable for 2 s"
    [row] = Fake.rows(env.logs)
    assert row =~ "reran-from-gate-1"
  end

  test "a keeper that goes is relaunched, and the part runs on", env do
    {status, _out, err} =
      check(env, [{"static", "bash cmd.sh drop-keeper"}, {"test-1", "bash cmd.sh green"}])

    assert status == 0, err
    log = log(env, "gate-1", "static")
    assert log =~ "outlived its keeper"
    assert log =~ "its keeper had gone; relaunched it"
    refute Fake.rows(env.logs) |> hd() =~ "reran"
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
  test "a warm cache builds before its part, outside the run limit, once per key; a restart while warming relaunches it on the same Sprite",
       env do
    File.touch!(Path.join(env.root, "warm-restarted"))
    parts = [{"static-1", "bash cmd.sh green"}, {"test-1", "bash cmd.sh green"}]
    {status, _out, err} = check(env, parts)
    # The cache took 3 s; the run limit is 2.
    assert status == 0, err
    assert File.read!(Path.join(env.root, "warms")) == "warm run\n"
    log = log(env, "gate-1", "static-1")
    assert log =~ "warmed plt"
    refute log(env, "gate-2", "test-1") =~ "warming plt"

    # The same key: no build.
    {0, _, _} = check(env, parts)
    assert File.read!(Path.join(env.root, "warms")) == "warm run\n"

    # A restart while warming: the part relaunches where the cache was half built.
    File.rm!(Path.join(env.root, "warm-restarted"))
    File.write!(Path.join(env.top, "cmd.sh"), File.read!(Path.join(env.top, "cmd.sh")) <> "\n")

    Fake.git(env.top, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qam", "a new key"])

    {status, _out, err} = check(env, parts)
    assert status == 0, err
    assert err =~ "gate-1 restarted while warming; relaunching it there"
    assert File.read!(Path.join(env.root, "warms")) == "warm run\nwarm run\nwarm run\n"
    assert List.last(Fake.rows(env.logs)) =~ ~r/static-1:\d+:gate-1:green\t/
  end

  @tag gate: %{"image" => [".tool-versions"], "stamp" => nil, "provision" => nil}
  test "a project on the image: rig's image script provisions it, and the stamp covers that script",
       env do
    image = Path.join(env.tmp, "image.sh")

    File.write!(image, ~S"""
    echo "image for $2 from $3"
    echo "$1" >~/"$2-stamp"
    """)

    System.put_env("GATE_IMAGE", image)
    on_exit(fn -> System.delete_env("GATE_IMAGE") end)

    {status, _out, err} =
      check(env, [{"static", "bash cmd.sh green"}, {"test-1", "bash cmd.sh green"}])

    assert status == 0, err
    log = log(env, "gate-1", "static")
    assert log =~ ~r"image for proj from \S+/proj/\.tool-versions"

    want =
      :crypto.hash(:sha256, [File.read!(Path.join(env.top, ".tool-versions")), File.read!(image)])
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    assert File.read!(Path.join(env.root, "gate-1/home/proj-stamp")) == want <> "\n"
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

  test "bin/gate holds the pool's lock and runs the gate in the checkout", env do
    Fake.parts(env.top, [{"static", "bash cmd.sh green"}])

    {out, status} =
      System.cmd(Path.join(Gate.Sprite.root(), "bin/gate"), ["check"],
        cd: env.top,
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert out =~ "check-remote: green in"
    assert File.exists?(Path.join(env.tmp, "locks"))
  end

  test "a gate stopped from outside ends the parts it launched on their Sprites", env do
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
    job = Path.join(env.root, "gate-1/home/parts")

    wait_until(fn ->
      match?([_], Path.wildcard(Path.join(job, "*/phase"))) and
        File.read!(hd(Path.wildcard(Path.join(job, "*/phase")))) =~ "run"
    end)

    System.cmd("kill", ["-TERM", to_string(pid)])
    assert_receive {^port, {:exit_status, 143}}, 20_000
    [pidfile] = Path.wildcard(Path.join(job, "*/job.pid"))

    {_, status} =
      System.cmd("kill", ["-0", File.read!(pidfile) |> String.trim()], stderr_to_stdout: true)

    assert status != 0, "the part still runs on its Sprite"
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("never happened")
      true -> Process.sleep(100) && wait_until(fun, tries - 1)
    end
  end

  defp tail_client?(pid) do
    {cmd, _} = System.cmd("ps", ["-o", "command=", "-p", pid])
    cmd =~ "tail -f"
  end

  describe "the local disk" do
    @describetag gate: %{
                   "pool" => ["gate-1", "gate-2"],
                   "keep" => ["cache"],
                   "local" => %{"paths" => ["cache", "~/data"], "tools" => ["tool"]}
                 }

    setup %{tmp_dir: tmp, root: root} do
      local = Fake.local_disk(tmp)

      on_exit(fn ->
        for var <- ~w(GATE_LOCAL_ROOT GATE_LOCAL_OPT GATE_LOCAL_BUDGET_MB),
            do: System.delete_env(var)
      end)

      home = Path.join(root, "gate-1/home")
      tool = Path.join(local.opt, "tool-1")
      File.mkdir_p!(Path.join(tool, "bin"))
      File.write!(Path.join(tool, "bin/the-tool"), "the tool\n")
      File.mkdir_p!(Path.join(home, "data"))
      File.write!(Path.join(home, "data/row"), "a row\n")
      File.write!(Path.join(home, "proj-env.sh"), "export PATH=#{tool}/bin:$PATH\n")
      Map.merge(local, %{home: home, tool: tool})
    end

    defp commit_commands(env) do
      Fake.git(env.top, ["add", "."])
      Fake.git(env.top, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "cmd"])
    end

    # The part after it: its log, on a Sprite with one part at a time.
    defp part(env, command) do
      File.rm_rf!(env.logs)
      {status, _out, err} = check(env, [{"one", command}])
      assert status == 0, err
      log(env, "gate-1", "one")
    end

    test "paths and tools are copied once and mounted, and what a part writes lands there",
         env do
      log = part(env, "bash cmd.sh write-cache first")
      assert log =~ "local disk: copied 3, mounted 3 new"

      assert File.read!(Path.join(env.disk, "projects/proj/cache/built")) == "first\n"
      assert File.read!(Path.join(env.disk, "projects/proj/~%data/row")) == "a row\n"
      assert File.read!(Path.join(env.disk, "tools/tool-1/bin/the-tool")) == "the tool\n"

      # The same paths read the copy.
      assert File.read!(Path.join(env.tool, "bin/the-tool")) == "the tool\n"
      assert File.read!(Path.join(env.home, "proj/cache/built")) == "first\n"

      log = part(env, "bash cmd.sh cat-cache")
      assert log =~ "first"
      assert log =~ "local disk: copied 0, mounted 0 new"
    end

    test "a restart drops the mounts and the next part mounts the same copies", env do
      part(env, "bash cmd.sh write-cache first")
      unmount_all(env)

      log = part(env, "bash cmd.sh cat-cache")
      assert log =~ "first"
      assert log =~ "local disk: copied 0, mounted 3 new"
    end

    test "after a restore the copies of paths go, since the root disk went back, and tools stay",
         env do
      part(env, "bash cmd.sh write-cache day")
      unmount_all(env)
      # The checkpoint holds no token (see the golden test below).
      File.rm_rf!(Path.join(env.home, ".gate-local"))

      log = part(env, "bash cmd.sh cat-cache")
      assert log =~ "cache empty"
      assert log =~ "local disk: copied 2, mounted 3 new"
    end

    test "a host move empties the disk: all of it is copied again", env do
      part(env, "bash cmd.sh write-cache first")
      unmount_all(env)
      File.rm_rf!(env.disk)

      log = part(env, "bash cmd.sh cat-cache")
      assert log =~ "cache empty"
      assert log =~ "local disk: copied 3, mounted 3 new"
    end

    test "what does not fit stays on the root disk, and the part still passes", env do
      System.put_env("GATE_LOCAL_BUDGET_MB", "0")
      log = part(env, "bash cmd.sh write-cache first")
      assert log =~ "cache stays on the root disk"
      assert log =~ "tool-1 stays on the root disk"
      assert log =~ "local disk: copied 0, mounted 0 new"
      assert File.read!(Path.join(env.home, "proj/cache/built")) == "first\n"
      refute File.dir?(Path.join(env.disk, "projects/proj/cache"))
    end

    test "a golden runs on the root disk and leaves no token in its checkpoint", env do
      part(env, "bash cmd.sh write-cache day")
      commit_commands(env)

      {status, _out, err} =
        Fake.capture(fn -> Gate.Golden.main(Fake.config(env.top), "gate-1") end)

      assert status == 0, err

      refute File.exists?(Path.join(env.home, ".gate-local"))
      refute Fake.mounted?(Path.join(env.home, "proj/cache"))
      refute Fake.mounted?(env.tool)
      refute File.exists?(Path.join(env.disk, "projects"))
      # The tools' copies keep: they are the same whichever disk.
      assert File.exists?(Path.join(env.disk, "tools/tool-1.ok"))
    end

    test "a provision writes to the root disk, and tools no env script names go", env do
      part(env, "bash cmd.sh green")
      File.mkdir_p!(Path.join(env.disk, "tools/tool-0"))
      File.write!(Path.join(env.home, "proj-stamp"), "old\n")

      log = part(env, "bash cmd.sh green")
      assert log =~ "refreshing tools"
      refute File.exists?(Path.join(env.disk, "tools/tool-0"))
      assert File.exists?(Path.join(env.disk, "tools/tool-1"))
      # Unmounted for it, mounted again after, and not copied again.
      assert log =~ "local disk: copied 0, mounted 3 new"
    end

    defp unmount_all(env) do
      for path <- [Path.join(env.home, "proj/cache"), Path.join(env.home, "data"), env.tool] do
        {_, 0} = System.cmd("sudo", ["-n", "umount", path], env: [])
      end
    end
  end

  test "a local path in the checkout must be one `git clean` keeps", env do
    json = Path.join(env.top, ".gate.json")
    gate = json |> File.read!() |> JSON.decode!()
    File.write!(json, JSON.encode!(Map.put(gate, "local", %{"paths" => ["_build"]})))

    assert_raise Gate.Error, ~r/local paths not in keep: _build/, fn -> Fake.config(env.top) end
  end

  describe "on the shared pool" do
    @describetag gate: %{"pool" => "fleet"}

    setup do
      on_exit(fn -> System.delete_env("GATE_FLEET_SOCKET") end)
    end

    test "each part on a Sprite the fleet leases as one frees; each given back with its result",
         env do
      fleet = Gate.FakeFleet.start(~w(gate-1 gate-2))

      {status, _out, err} =
        check(env, [
          {"static", "bash cmd.sh green"},
          {"test-1", "bash cmd.sh red"},
          {"test-2", "bash cmd.sh green"}
        ])

      assert status == 1, err
      assert err =~ "as 3 parts on the shared pool"
      released = Gate.FakeFleet.released(fleet)
      assert Enum.sort(Enum.map(released, &elem(&1, 1))) == ~w(green green red)
      [row] = Fake.rows(env.logs)
      assert row =~ ~r/\ttest-2:\d+:gate-[12]:green/
      Gate.FakeFleet.stop(fleet)
    end

    test "a crashed part is given back as crashed and reruns on the next Sprite leased", env do
      fleet = Gate.FakeFleet.start(~w(gate-1 gate-2))
      {status, _out, err} = check(env, [{"static", "bash cmd.sh crash-once"}])
      assert status == 0, err
      assert [{first, "crashed"}, {second, "green"}] = Gate.FakeFleet.released(fleet)
      assert {first, second} == {"gate-1", "gate-2"}
      [row] = Fake.rows(env.logs)
      assert row =~ ":gate-2:green:reran-from-gate-1"
      Gate.FakeFleet.stop(fleet)
    end

    test "a part whose Sprite restarted keeps its lease and is relaunched there; restarted again, it is given back as restarted",
         env do
      fleet = Gate.FakeFleet.start(~w(gate-1 gate-2))
      {status, _out, err} = check(env, [{"static", "bash cmd.sh restart-once"}])
      assert status == 0, err
      assert [{"gate-1", "green"}] = Gate.FakeFleet.released(fleet)

      {status, _out, err} = check(env, [{"static", "bash cmd.sh restarts 2"}])
      assert status == 0, err
      assert [_, {first, "restarted"}, {second, "green"}] = Gate.FakeFleet.released(fleet)
      assert first != second
      Gate.FakeFleet.stop(fleet)
    end

    test "no verdict when rigd's Fleet does not answer", env do
      System.put_env("GATE_FLEET_SOCKET", "/nonexistent/fleet.sock")
      Fake.parts(env.top, [{"static", "bash cmd.sh green"}])

      assert_raise Gate.Error, ~r/Fleet does not answer/, fn ->
        Gate.Check.main(Fake.config(env.top), [])
      end
    end
  end
end
