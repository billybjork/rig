defmodule Rigd.FleetTest do
  use ExUnit.Case, async: false

  alias Rigd.Fleet
  alias Rigd.Fleet.Sprite

  @moduletag :tmp_dir
  @moduletag :capture_log

  @stamp "0123456789abcdef"
  @newer "fedcba9876543210"

  # A `sprite` CLI whose Sprites are directories under $FAKE_SPRITES; every
  # call is appended to `calls`. It fails as the real one does on a Sprite
  # already there or already gone; `<name>.create-times-out` makes the next
  # create of that Sprite outlast its deadline after making it,
  # `offline` makes every restore fail as it does with no network, and
  # `full` every create as the account's limit of Sprites at once does.
  @cli ~S"""
  #!/bin/bash
  root=$FAKE_SPRITES
  echo "$*" >>"$root/calls"
  case "$1 $2" in
    "list "*) for d in "$root"/*/; do [ -d "$d" ] && basename "$d"; done; exit 0 ;;
    "create "*)
      [ -f "$root/full" ] && { echo "Error: Maximum concurrent sprites limit (10) reached for your organization."; exit 1; }
      [ -d "$root/$3" ] && { echo "Error: A sprite named '$3' already exists."; exit 1; }
      mkdir -p "$root/$3"
      [ -f "$root/$3.create-times-out" ] && { rm "$root/$3.create-times-out"; exit 142; }
      exit 0 ;;
    "destroy "*)
      [ -d "$root/$4" ] || { echo "Error: failed to destroy sprite: sprite not found"; exit 1; }
      rm -rf "${root:?}/$4"; exit 0 ;;
    "checkpoint list") cat "$root/$4/checkpoints" 2>/dev/null; exit 0 ;;
    "checkpoint create")
      n=$(($(wc -l <"$root/$4/checkpoints" 2>/dev/null || echo 0) + 1))
      echo "v$n  2026-10-29 12:00  $6" >>"$root/$4/checkpoints"; exit 0 ;;
    "checkpoint restore")
      [ -f "$root/offline" ] && { echo "Error: failed to restore checkpoint: failed to make request: dial tcp: lookup api.sprites.dev: no such host"; exit 1; }
      exit 0 ;;
  esac
  exit 0
  """

  defmodule Golden do
    @moduledoc """
    A provision gate per Sprite as the test sets it: `{:golden, sprite}` in
    persistent_term, each result or a function returning one. With `{:golden,
    :log}` set, each run writes when it starts and ends there.
    """
    def stamp(_gate, _dir), do: {:ok, "proj", :persistent_term.get({__MODULE__, :stamp})}

    def run(gate, dir, sprite) do
      if log = :persistent_term.get({__MODULE__, :log}, nil) do
        File.write!(log, "start #{sprite}\n", [:append])
        Process.sleep(200)
        result = result(sprite)
        File.write!(log, "end #{sprite}\n", [:append])
        result
      else
        result(sprite)
      end
      |> then(fn r -> if is_function(r), do: r.(gate, dir), else: r end)
    end

    defp result(sprite) do
      case :persistent_term.get({__MODULE__, sprite}, []) do
        [next | rest] ->
          :persistent_term.put({__MODULE__, sprite}, rest)
          next

        [] ->
          {:green, "proj", :persistent_term.get({__MODULE__, :stamp})}
      end
    end
  end

  setup %{tmp_dir: tmp} do
    root = Path.join(tmp, "sprites")
    File.mkdir_p!(root)
    cli = Path.join(tmp, "sprite")
    File.write!(cli, @cli)
    File.chmod!(cli, 0o755)
    System.put_env("FAKE_SPRITES", root)
    :persistent_term.put({Golden, :stamp}, @stamp)

    opts = [
      sprites: ~w(rig-gate-1 rig-gate-2),
      projects: ["/nowhere/proj"],
      gate: "/nowhere/gate",
      golden: Golden,
      # A socket's path holds 104 bytes at most.
      socket: Path.join(System.tmp_dir!(), "fleet-#{System.unique_integer([:positive])}.sock"),
      cli: cli,
      deadline: Path.expand("../../gate/libexec/deadline", __DIR__)
    ]

    on_exit(fn ->
      for s <- opts[:sprites], do: :persistent_term.erase({Golden, s})
      :persistent_term.erase({Golden, :log})
    end)

    %{root: root, opts: opts}
  end

  defp golden_sprite(root, name, stamp) do
    File.mkdir_p!(Path.join(root, name))
    File.write!(Path.join([root, name, "checkpoints"]), "v1  2026-10-28  golden proj #{stamp}\n")
  end

  defp start(opts), do: start_supervised!({Rigd.Fleet.Supervisor, opts})

  defp until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out: #{inspect(Fleet.status())}")
      true -> Process.sleep(50) && until(fun, tries - 1)
    end
  end

  defp status(name), do: Fleet.status().sprites[name][:status]

  defp calls(root), do: File.read!(Path.join(root, "calls"))

  defp connect(opts) do
    {:ok, sock} =
      :gen_tcp.connect({:local, opts[:socket]}, 0, [:binary, packet: :line, active: false])

    sock
  end

  defp send_line(sock, msg), do: :ok = :gen_tcp.send(sock, JSON.encode!(msg) <> "\n")

  defp recv(sock, timeout \\ 5000) do
    case :gen_tcp.recv(sock, 0, timeout) do
      {:ok, line} -> JSON.decode!(line)
      {:error, why} -> why
    end
  end

  defp lease(opts, project \\ "proj", prefer \\ []) do
    sock = connect(opts)
    send_line(sock, %{lease: %{project: project, part: "p", prefer: prefer}})
    sock
  end

  test "a Sprite with a golden checkpoint is idle; a missing one is created and made golden",
       %{root: root, opts: opts} do
    golden_sprite(root, "rig-gate-1", @stamp)
    start(opts)
    until(fn -> status("rig-gate-1") == :idle and status("rig-gate-2") == :idle end)
    assert calls(root) =~ "create --skip-console rig-gate-2"
    assert calls(root) =~ "checkpoint create -s rig-gate-2 -comment golden proj #{@stamp}"
    assert Fleet.status().sprites["rig-gate-2"].stamps == %{"proj" => @stamp}
  end

  test "leases go to the waiters in turn, the preferred Sprite first; a released one goes to the next",
       %{root: root, opts: opts} do
    for s <- opts[:sprites], do: golden_sprite(root, s, @stamp)
    start(opts)
    until(fn -> status("rig-gate-2") == :idle end)

    a = lease(opts, "proj", ["rig-gate-2"])
    assert recv(a) == %{"granted" => "rig-gate-2"}
    b = lease(opts)
    assert recv(b) == %{"granted" => "rig-gate-1"}
    c = lease(opts, "other")
    assert recv(c, 300) == :timeout
    assert Fleet.status().waiting == 1

    send_line(a, %{release: %{sprite: "rig-gate-2", result: "green"}})
    assert recv(a) == %{"released" => "rig-gate-2"}
    assert recv(c) == %{"granted" => "rig-gate-2"}

    send_line(c, %{status: %{}})
    assert %{"sprites" => %{"rig-gate-2" => %{"status" => "leased"}}} = recv(c)
  end

  test "a holder that goes without releasing has its parts ended before the Sprite is idle again",
       %{root: root, opts: opts} do
    golden_sprite(root, "rig-gate-1", @stamp)
    start(opts)
    until(fn -> status("rig-gate-1") == :idle end)

    a = lease(opts)
    assert recv(a) == %{"granted" => "rig-gate-1"}
    :gen_tcp.close(a)
    until(fn -> calls(root) =~ "-s rig-gate-1 exec -- bash -c" end)
    until(fn -> status("rig-gate-1") == :idle end)
  end

  defp part(opts, result) do
    a = lease(opts, "proj", ["rig-gate-1"])
    assert recv(a) == %{"granted" => "rig-gate-1"}
    send_line(a, %{release: %{sprite: "rig-gate-1", result: result}})
    assert recv(a) == %{"released" => "rig-gate-1"}
    until(fn -> status("rig-gate-1") == :idle end)
    :gen_tcp.close(a)
  end

  defp strikes(name), do: Fleet.status().sprites[name].strikes

  test "a crash is a strike, and a failure right after a failure; a third strike in a day replaces it",
       %{root: root, opts: opts} do
    golden_sprite(root, "rig-gate-1", @stamp)
    start(opts)
    until(fn -> status("rig-gate-1") == :idle end)

    part(opts, "crashed")
    assert strikes("rig-gate-1") == 1
    part(opts, "failed")
    assert strikes("rig-gate-1") == 1
    part(opts, "green")
    part(opts, "failed")
    assert strikes("rig-gate-1") == 1
    part(opts, "failed")
    assert strikes("rig-gate-1") == 2
    part(opts, "failed")

    assert calls(root) =~ "destroy --force -s rig-gate-1"
    assert strikes("rig-gate-1") == 0
  end

  test "a restart releases the Sprite without a strike", %{root: root, opts: opts} do
    golden_sprite(root, "rig-gate-1", @stamp)
    start(opts)
    until(fn -> status("rig-gate-1") == :idle end)

    for _ <- 1..4, do: part(opts, "restarted")

    assert strikes("rig-gate-1") == 0
    refute calls(root) =~ "destroy"
  end

  test "a restore that never reached the Sprite is tried again, not rebuilt",
       %{root: root, opts: opts} do
    golden_sprite(root, "rig-gate-1", @stamp)
    start(opts)
    until(fn -> status("rig-gate-1") == :idle end)
    File.write!(Path.join(root, "offline"), "")

    a = lease(opts, "proj", ["rig-gate-1"])
    assert recv(a) == %{"granted" => "rig-gate-1"}
    send_line(a, %{release: %{sprite: "rig-gate-1", result: "failed"}})
    assert recv(a) == %{"released" => "rig-gate-1"}

    until(fn -> (Fleet.status().sprites["rig-gate-1"].why || "") =~ "no such host" end)
    Process.sleep(300)
    assert status("rig-gate-1") == :restoring
    refute calls(root) =~ "destroy"
    assert Fleet.status().sprites["rig-gate-1"].stamps == %{"proj" => @stamp}

    # Back online: the retry restores it, and the failure leaves its status.
    File.rm!(Path.join(root, "offline"))

    send(
      GenServer.whereis({:via, Registry, {Rigd.Fleet.Registry, "rig-gate-1"}}),
      {:again, :restore}
    )

    until(fn -> status("rig-gate-1") == :idle end)
    assert Fleet.status().sprites["rig-gate-1"].why == nil
  end

  test "a provision the Sprite fails is tried once more, then the Sprite is rebuilt",
       %{root: root, opts: opts} do
    golden_sprite(root, "rig-gate-1", @stamp)
    failed = {:sprite_failed, "restarted"}
    :persistent_term.put({Golden, "rig-gate-2"}, [failed, failed])
    start(opts)
    until(fn -> status("rig-gate-2") == :idle end)
    assert calls(root) =~ "destroy --force -s rig-gate-2"
    assert Fleet.status().sprites["rig-gate-2"].stamps == %{"proj" => @stamp}
  end

  test "a provision that failed on the laptop's side is tried again later, costing the Sprite nothing",
       %{root: root, opts: opts} do
    golden_sprite(root, "rig-gate-1", @stamp)
    fetch = &{:laptop, "git fetch in ~/dev/proj exited 128: Could not resolve host (#{&1})"}
    :persistent_term.put({Golden, "rig-gate-2"}, Enum.map(1..4, fetch))
    start(opts)
    pid = GenServer.whereis({:via, Registry, {Rigd.Fleet.Registry, "rig-gate-2"}})

    for n <- 1..4 do
      until(fn -> (Fleet.status().sprites["rig-gate-2"].why || "") =~ "host (#{n})" end)
      assert status("rig-gate-2") == :provisioning
      send(pid, {:again, {:provision, true}})
    end

    until(fn -> status("rig-gate-2") == :idle end)
    refute calls(root) =~ "destroy"
    assert Fleet.status().sprites["rig-gate-2"].stamps == %{"proj" => @stamp}
  end

  test "a create the account's limit refused waits for a slot, costing the Sprite nothing",
       %{root: root, opts: opts} do
    golden_sprite(root, "rig-gate-1", @stamp)
    File.write!(Path.join(root, "full"), "")
    start(opts)
    pid = GenServer.whereis({:via, Registry, {Rigd.Fleet.Registry, "rig-gate-2"}})

    for _ <- 1..3 do
      File.rm(Path.join(root, "calls"))
      until(fn -> File.exists?(Path.join(root, "calls")) and calls(root) =~ "create" end)
      until(fn -> (Fleet.status().sprites["rig-gate-2"].why || "") =~ "limit (10)" end)
      Process.sleep(100)
      assert status("rig-gate-2") == :provisioning
      send(pid, {:again, {:provision, true}})
    end

    File.rm!(Path.join(root, "full"))
    until(fn -> status("rig-gate-2") == :idle end)
    refute calls(root) =~ "destroy"
  end

  test "Sprites provision three at a time", %{root: root, opts: opts} do
    log = Path.join(root, "golden.log")
    :persistent_term.put({Golden, :log}, log)
    sprites = for n <- 1..4, do: "rig-gate-#{n}"
    start(Keyword.put(opts, :sprites, sprites))
    until(fn -> Enum.all?(sprites, &(status(&1) == :idle)) end)

    events = log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&String.split/1)
    {first, rest} = Enum.split(events, 3)
    assert Enum.all?(first, &match?(["start", _], &1))
    # The fourth starts only once one of the three has ended.
    assert [["end", _] | _] = rest
    starts = for ["start", s] <- events, do: s
    assert Enum.sort(starts) == sprites
  end

  test "a create that outlasted its deadline but made the Sprite is done on its retry",
       %{root: root, opts: opts} do
    golden_sprite(root, "rig-gate-1", @stamp)
    File.write!(Path.join(root, "rig-gate-2.create-times-out"), "")
    start(opts)
    # A call that outlasted its deadline is tried again later, as one that never reached the API.
    until(fn -> (Fleet.status().sprites["rig-gate-2"].why || "") =~ "exited 142" end)

    send(
      GenServer.whereis({:via, Registry, {Rigd.Fleet.Registry, "rig-gate-2"}}),
      {:again, {:provision, true}}
    )

    until(fn -> status("rig-gate-2") == :idle end)
    assert length(String.split(calls(root), "create --skip-console rig-gate-2")) == 3
    assert Fleet.status().sprites["rig-gate-2"].stamps == %{"proj" => @stamp}
  end

  test "a rebuild of a Sprite already gone creates it", %{root: root, opts: opts} do
    golden_sprite(root, "rig-gate-1", @stamp)
    failed = {:sprite_failed, "restarted"}
    gone = fn _gate, _dir -> File.rm_rf!(Path.join(root, "rig-gate-2")) && failed end
    :persistent_term.put({Golden, "rig-gate-2"}, [failed, gone])
    start(opts)
    until(fn -> status("rig-gate-2") == :idle end)
    assert calls(root) =~ "destroy --force -s rig-gate-2"
    assert Fleet.status().sprites["rig-gate-2"].stamps == %{"proj" => @stamp}
  end

  test "a stamp change makes idle Sprites golden again, one at a time", %{root: root, opts: opts} do
    for s <- opts[:sprites], do: golden_sprite(root, s, @stamp)
    :persistent_term.put({Golden, :stamp}, @newer)
    start(opts)

    until(fn ->
      Enum.all?(Fleet.status().sprites, fn {_, s} -> s.stamps == %{"proj" => @newer} end)
    end)

    assert calls(root) =~ "checkpoint create -s rig-gate-1 -comment golden proj #{@newer}"
    assert calls(root) =~ "checkpoint create -s rig-gate-2 -comment golden proj #{@newer}"
  end

  test "pick: idle and golden, the preferred one, then one that served the project" do
    sprites = %{
      "a" => %{status: :idle, stamps: %{}, served: []},
      "b" => %{status: :idle, stamps: %{}, served: ["soco"]},
      "c" => %{status: :leased, stamps: %{}, served: ["soco"]},
      "d" => %{status: :idle, stamps: nil, served: []}
    }

    assert Fleet.pick(sprites, "soco", ["c", "a"]) == "a"
    assert Fleet.pick(sprites, "soco", []) == "b"
    assert Fleet.pick(sprites, "heaters", ["d"]) == "a"
    assert Fleet.pick(Map.take(sprites, ~w(c d)), "soco", []) == nil
  end

  test "stale: one idle Sprite under other stamps, none while another is provisioning" do
    now = %{"soco" => @newer}
    old = %{status: :idle, stamps: %{"soco" => @stamp}, served: []}
    assert Fleet.stale(%{"a" => old}, now) == "a"
    assert Fleet.stale(%{"a" => %{old | stamps: now}}, now) == nil
    assert Fleet.stale(%{"a" => old, "b" => %{old | status: :provisioning}}, now) == nil
    assert Fleet.stale(%{"a" => old, "b" => %{old | status: :waiting}}, now) == nil
    assert Fleet.stale(%{"a" => old}, %{}) == nil
  end

  test "golden checkpoints: the comment, and the newest in a list" do
    stamps = %{"soco" => @stamp, "heaters" => @newer}
    comment = Sprite.golden_comment(stamps)
    assert comment == "golden heaters #{@newer} soco #{@stamp}"
    assert Sprite.golden_stamps("v4  2026-10-29  " <> comment) == stamps
    assert Sprite.golden_stamps("v3  green gate 1234 stamp #{@stamp}") == nil

    list = [
      {"v2", "v2 x golden soco #{@stamp}"},
      {"v10", "v10 x golden soco #{@newer}"},
      {"v11", "v11 x after a restore"}
    ]

    assert Sprite.newest_golden(list) == %{id: "v10", stamps: %{"soco" => @newer}}
  end

  test "strikes count within a day; three retire" do
    day = 24 * 3600
    strikes = Sprite.strike([100, 100 - day], 200)
    assert strikes == [200, 100]
    refute Sprite.retire?(strikes)
    assert Sprite.retire?(Sprite.strike(strikes, 300))
  end

  test "gate/fleet.json's options name the gate and deadline that exist" do
    opts = Rigd.Fleet.Supervisor.options(Application.fetch_env!(:rigd, :fleet_config))
    assert File.exists?(opts[:gate]), opts[:gate]
    assert File.exists?(opts[:deadline]), opts[:deadline]
  end

  test "a deadline that cannot run is a failed call", %{opts: opts} do
    start(Keyword.put(opts, :deadline, "/nowhere/deadline"))
    assert {"cannot run /nowhere/deadline" <> _, 127} = Rigd.Fleet.CLI.call(["list"], 5)
  end

  test "gate runs without the boot variables of the rigd release", %{tmp_dir: tmp} do
    gate = Path.join([tmp, "gate", "bin", "gate"])
    File.mkdir_p!(Path.dirname(gate))
    File.mkdir_p!(Path.join([tmp, "gate", "libexec"]))

    File.ln_s!(
      Path.expand("../../gate/libexec/deadline", __DIR__),
      Path.join([tmp, "gate", "libexec", "deadline"])
    )

    File.write!(
      gate,
      "#!/bin/bash\necho \"${ROOTDIR:-none} ${RELEASE_ROOT:-none} $PWD\"\necho \"$PATH\"\n"
    )

    File.chmod!(gate, 0o755)

    # The release's erts/bin leads PATH inside a release.
    erts = Path.join(to_string(:code.root_dir()), "erts/bin")
    path = System.get_env("PATH")
    System.put_env(%{"ROOTDIR" => "/rel", "RELEASE_ROOT" => "/rel", "PATH" => "#{erts}:#{path}"})

    on_exit(fn ->
      Enum.each(~w(ROOTDIR RELEASE_ROOT), &System.delete_env/1)
      System.put_env("PATH", path)
    end)

    assert {"none none " <> out, 0} = Rigd.Fleet.Golden.cmd(gate, [], tmp, 10)
    [dir, child_path] = String.split(out, "\n", trim: true)
    assert dir == Path.expand(tmp)
    refute child_path =~ erts
    assert child_path =~ "/usr/bin"
  end

  @tag :tmp_dir
  test "a golden run first removes the worktrees a killed one left on its Sprite", %{
    tmp_dir: tmp
  } do
    repo = Path.join(tmp, "repo")
    git = fn args -> {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) end
    File.mkdir_p!(repo)
    git.(["init", "-q"])

    git.([
      "-c",
      "user.name=t",
      "-c",
      "user.email=t@t",
      "commit",
      "-q",
      "--allow-empty",
      "-m",
      "x"
    ])

    left = Path.join(tmp, "rigd-golden-rig-gate-1-7")
    other = Path.join(tmp, "rigd-golden-rig-gate-10-8")
    for path <- [left, other], do: git.(["worktree", "add", "-q", "--detach", path])

    assert :ok = Rigd.Fleet.Golden.prune(repo, "rig-gate-1")
    refute File.exists?(left)
    assert File.exists?(other)
    {list, 0} = System.cmd("git", ["-C", repo, "worktree", "list"])
    refute list =~ "rig-gate-1-7"
  end

  test "the nightly restore is at the next 04:00" do
    assert Fleet.until_nightly(~N[2026-10-29 03:00:00]) == 3600 * 1000
    assert Fleet.until_nightly(~N[2026-10-29 04:00:00]) == 24 * 3600 * 1000
  end
end
