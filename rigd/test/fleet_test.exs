defmodule Rigd.FleetTest do
  use ExUnit.Case, async: false

  alias Rigd.Fleet
  alias Rigd.Fleet.Sprite

  @moduletag :tmp_dir
  @moduletag :capture_log

  @stamp "0123456789abcdef"
  @newer "fedcba9876543210"

  # A `sprite` CLI whose Sprites are directories under $FAKE_SPRITES; every
  # call is appended to `calls`.
  @cli ~S"""
  #!/bin/bash
  root=$FAKE_SPRITES
  echo "$*" >>"$root/calls"
  case "$1 $2" in
    "list "*) for d in "$root"/*/; do [ -d "$d" ] && basename "$d"; done; exit 0 ;;
    "create "*) mkdir -p "$root/$3"; exit 0 ;;
    "destroy "*) rm -rf "${root:?}/$4"; exit 0 ;;
    "checkpoint list") cat "$root/$4/checkpoints" 2>/dev/null; exit 0 ;;
    "checkpoint create")
      n=$(($(wc -l <"$root/$4/checkpoints" 2>/dev/null || echo 0) + 1))
      echo "v$n  2026-10-29 12:00  $6" >>"$root/$4/checkpoints"; exit 0 ;;
    "checkpoint restore") exit 0 ;;
  esac
  exit 0
  """

  defmodule Golden do
    @moduledoc "A provision gate per Sprite as the test sets it: `{:golden, sprite}` in persistent_term."
    def stamp(_gate, _dir), do: {:ok, "proj", :persistent_term.get({__MODULE__, :stamp})}

    def run(_gate, _dir, sprite) do
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

  test "a part the Sprite failed restores its golden checkpoint; a third strike in a day replaces it",
       %{root: root, opts: opts} do
    golden_sprite(root, "rig-gate-1", @stamp)
    start(opts)
    until(fn -> status("rig-gate-1") == :idle end)

    for n <- 1..3 do
      a = lease(opts, "proj", ["rig-gate-1"])
      assert recv(a) == %{"granted" => "rig-gate-1"}

      send_line(a, %{
        release: %{sprite: "rig-gate-1", result: if(n == 2, do: "crashed", else: "failed")}
      })

      assert recv(a) == %{"released" => "rig-gate-1"}
      until(fn -> status("rig-gate-1") == :idle end)
      :gen_tcp.close(a)
    end

    assert length(String.split(calls(root), "checkpoint restore v1 -s rig-gate-1")) == 3
    assert calls(root) =~ "destroy --force -s rig-gate-1"
    assert Fleet.status().sprites["rig-gate-1"].strikes == 0
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

  test "the nightly restore is at the next 04:00" do
    assert Fleet.until_nightly(~N[2026-10-29 03:00:00]) == 3600 * 1000
    assert Fleet.until_nightly(~N[2026-10-29 04:00:00]) == 24 * 3600 * 1000
  end
end
