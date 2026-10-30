defmodule Gate.CommandsTest do
  use ExUnit.Case, async: false

  alias Gate.Fake

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} = context do
    env = Fake.setup(tmp, ~w(gate-1 gate-2), Map.get(context, :gate, %{}))
    on_exit(fn -> Fake.stop(env.root) end)
    env
  end

  test "run: the working tree's changes over HEAD on a dev Sprite it creates, the output streamed, the status the command's",
       env do
    File.write!(
      Path.join(env.top, "cmd.sh"),
      File.read!(Path.join(env.top, "cmd.sh")) <> "# edited\n"
    )

    File.write!(Path.join(env.top, "new.txt"), "untracked and here\n")

    {status, out, err} =
      Fake.capture(fn ->
        Gate.Run.main(Fake.config(env.top), ["bash", "cmd.sh", "cat", "new.txt"])
      end)

    assert status == 0, err
    assert err =~ "dev-1: creating"
    assert err =~ "with 2 uncommitted path(s)"
    assert out =~ "working tree laid over"
    assert out =~ "untracked and here"
    assert File.read!(Path.join(env.root, "dev-1/home/proj/cmd.sh")) =~ "# edited"
    assert [_] = Path.wildcard(Path.join(env.logs, "sprite-run-dev-1-*.log"))

    {status, _out, err} =
      Fake.capture(fn -> Gate.Run.main(Fake.config(env.top), ["bash", "cmd.sh", "exit", "3"]) end)

    assert status == 3
    assert err =~ "exit 3 in"
  end

  test "run: 125 when the Sprite fails, saying so", env do
    File.mkdir_p!(Path.join(env.root, "dev-1/home"))
    File.touch!(Path.join(env.root, "dev-1/down"))
    {status, _out, err} = Fake.capture(fn -> Gate.Run.main(Fake.config(env.top), ["true"]) end)
    assert status == 125
    assert err =~ "dev-1 failed after"
    assert err =~ "(exit 125, not the command's result)"
  end

  test "pool: provision gates a Sprite and checkpoints it under the stamp; status then says ready",
       env do
    config = Fake.config(env.top)
    {status, _out, err} = Fake.capture(fn -> Gate.Pool.main(config, ["provision", "gate-1"]) end)
    assert status == 0, err
    sha = Fake.git(env.top, ["rev-parse", "HEAD"]) |> String.trim()
    stamp = Gate.Stamp.stamp(config, sha)

    assert File.read!(Path.join(env.root, "gate-1/checkpoints")) =~
             "cp-1  green gate #{String.slice(sha, 0, 8)} stamp #{stamp}"

    {0, out, _} = Fake.capture(fn -> Gate.Pool.main(config, ["status"]) end)
    assert out =~ "gate-1  ready, checkpoint cp-1"
    assert out =~ "gate-2  stale stamp none"

    # Provisioned already: nothing runs.
    {0, _, err} = Fake.capture(fn -> Gate.Pool.main(config, ["provision", "gate-1"]) end)
    assert err =~ "gate-1: ready"

    assert File.read!(Path.join(env.root, "gate-1/checkpoints"))
           |> String.split("\n", trim: true)
           |> length() == 1
  end

  test "pool: a Sprite outside the pool is refused", env do
    assert_raise Gate.Error, ~r/dev-1 is not a gate Sprite/, fn ->
      Gate.Pool.main(Fake.config(env.top), ["exec", "dev-1", "true"])
    end
  end

  test "times: weights from the newest gate whose every suite part was green", env do
    Fake.parts(env.top, [{"static", "x"}, {"test-1", "x"}, {"test-2", "x"}])
    File.mkdir_p!(env.logs)

    write = fn sprite, run, part, lines, exit ->
      File.write!(
        Path.join(env.logs, "#{sprite}-#{run}-#{part}.log"),
        Enum.join(lines ++ ["sprite-gate: exit #{exit}"], "\n") <> "\n"
      )
    end

    old = "20261027-100000-aaaaaaaa"
    new = "20261028-100000-bbbbbbbb"
    write.("gate-1", old, "test-1", ["gate-time: test/a_test.exs 1000 0"], 0)
    write.("gate-2", old, "test-2", ["gate-time: test/b_test.exs 12000 5"], 0)
    # The newer run's test-2 was red: not used.
    write.("gate-1", new, "test-1", ["gate-time: test/a_test.exs 9 0"], 0)
    write.("gate-2", new, "test-2", ["gate-time: test/b_test.exs 9 0"], 1)

    {0, _, err} = Fake.capture(fn -> Gate.Times.main(Fake.config(env.top), []) end)
    assert err =~ "2 files from run #{old}"
    weights = File.read!(Path.join(env.top, "weights.exs"))
    assert weights =~ ~s("test/a_test.exs" => {1_000, 0})
    assert weights =~ ~s("test/b_test.exs" => {12_000, 5})
  end

  test "deadline holds a command that ignores TERM to its limit and ends it" do
    deadline = Path.join(Gate.Sprite.root(), "libexec/deadline")
    t0 = System.monotonic_time(:millisecond)

    {_, status} =
      System.cmd(deadline, ["1", "perl", "-e", ~S($SIG{TERM} = "IGNORE"; sleep 30)],
        env: [{"GATE_KILL_GRACE", "1"}]
      )

    assert status == 142
    assert System.monotonic_time(:millisecond) - t0 < 5000
    assert {_, 3} = System.cmd(deadline, ["5", "sh", "-c", "exit 3"])
  end

  test "deadline ends its command when its caller dies" do
    deadline = Path.join(Gate.Sprite.root(), "libexec/deadline")
    t0 = System.monotonic_time(:millisecond)
    # The caller exits after a second; the command holds stdout open until it ends.
    System.cmd("sh", ["-c", ~s("$0" 30 sleep 30 & sleep 1; exit 0), deadline])
    assert System.monotonic_time(:millisecond) - t0 < 6000
  end

  @tag gate: %{
         "warm" => [
           %{
             "name" => "plt",
             "parts" => ["one"],
             "key" => ["cmd.sh"],
             "command" => "bash cmd.sh restarts 3"
           }
         ]
       }
  test "golden: sets up and warms each cache, no part run; a step whose Sprite restarted resumes there; the stamp on stdout",
       env do
    Fake.parts(env.top, [{"one", "bash cmd.sh red"}, {"two", "bash cmd.sh red"}])
    Fake.git(env.top, ["add", "."])
    Fake.git(env.top, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "parts"])
    config = Fake.config(env.top)
    {status, out, err} = Fake.capture(fn -> Gate.Golden.main(config, "gate-2") end)
    assert status == 0, err
    sha = Fake.git(env.top, ["rev-parse", "HEAD"]) |> String.trim()
    assert out == Gate.Stamp.stamp(config, sha) <> "\n"
    assert err =~ "setup: green"
    # Its first restart relaunches it within the try (while warming), as
    # does the second (a restart), and the third ends the try: no Sprite
    # is free for a golden's rerun.
    assert err =~ "warm-plt: sprite_failed"
    assert err =~ "warm-plt: green"
    refute err =~ ~r/\b(one|two):/
    [setup] = Path.wildcard(Path.join(env.logs, "gate-2-*-setup.log"))
    assert File.read!(setup) =~ "setup ran"
    assert File.read!(Path.join(env.root, "gate-2/home/.gate-warm/proj-plt")) != ""
    refute File.exists?(Path.join(env.root, "gate-1/home/parts"))
  end

  test "golden: a Sprite that fails a step every try fails the golden", env do
    File.write!(Path.join(env.top, "setup.sh"), "exit 3\n")
    Fake.git(env.top, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qam", "no setup"])
    {status, _out, err} = Fake.capture(fn -> Gate.Golden.main(Fake.config(env.top), "gate-2") end)
    assert status == 2, err
    assert length(String.split(err, "setup: sprite_failed")) == 4
  end

  @tag gate: %{
         "warm" => [
           %{"name" => "plt", "parts" => ["one"], "key" => ["cmd.sh"], "command" => "ls seeded"}
         ]
       }
  test "golden: a warm cache with a seed on the laptop starts from it",
       env do
    seeds = Path.join(env.tmp, "seeds")
    stage = Path.join(env.tmp, "seed")
    File.mkdir_p!(Path.join(stage, "proj"))
    File.write!(Path.join([stage, "proj", "seeded"]), "a PLT\n")
    config = Fake.config(env.top)
    File.mkdir_p!(Path.join(seeds, config.name))
    tar = Path.join([seeds, config.name, "plt.tar"])
    {_, 0} = System.cmd("tar", ["-cf", tar, "-C", stage, "proj"])
    System.put_env("GATE_SEED", seeds)
    on_exit(fn -> System.delete_env("GATE_SEED") end)

    Fake.parts(env.top, [{"one", "bash cmd.sh green"}])
    Fake.git(env.top, ["add", "."])
    Fake.git(env.top, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "parts"])
    {status, _out, err} = Fake.capture(fn -> Gate.Golden.main(Fake.config(env.top), "gate-2") end)
    assert status == 0, err
    [log] = Path.wildcard(Path.join(env.logs, "gate-2-*-warm-plt.log"))
    assert File.read!(log) =~ "seeded plt"
    assert File.read!(log) =~ "warmed plt"
  end

  test "stamp <rev>: the stamp as that commit's .gate.json names it", env do
    config = Fake.config(env.top)
    sha = Fake.git(env.top, ["rev-parse", "HEAD"]) |> String.trim()
    old = Gate.Stamp.stamp(config, sha)

    File.write!(
      Path.join(env.top, ".gate.json"),
      File.read!(Path.join(env.top, ".gate.json"))
      |> String.replace(
        ~s("stamp":[".tool-versions","provision.sh"]),
        ~s("stamp":[".tool-versions"])
      )
    )

    Fake.git(env.top, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qam", "stamp"])
    assert Gate.Stamp.stamp(Gate.Config.load(env.top, sha), sha) == old
    new = Gate.Config.load(env.top, "HEAD")
    assert new.stamp == [".tool-versions"]
    refute Gate.Stamp.stamp(new, "HEAD") == old
  end
end
