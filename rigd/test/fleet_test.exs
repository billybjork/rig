defmodule Rigd.FleetTest do
  use ExUnit.Case, async: false

  alias Rigd.Fleet.Golden

  @moduletag :tmp_dir
  @moduletag :capture_log

  @stamp "0123456789abcdef"
  @newer "fedcba9876543210"

  test "a golden's comment names its keys, and only such a comment reads as one" do
    keys = %{"soco" => @stamp, "heaters" => @newer, "soco-plt" => @newer}
    comment = Golden.comment(keys)
    assert comment == "golden heaters #{@newer} soco #{@stamp} soco-plt #{@newer}"
    assert Golden.comment_keys(comment) == keys
    assert Golden.comment_keys("refreshing") == nil
    assert Golden.comment_keys("") == nil
  end

  test "enqueue: ships in arrival order, then sessions in theirs" do
    s1 = %{id: :s1, priority: :session}
    s2 = %{id: :s2, priority: :session}
    p1 = %{id: :p1, priority: :ship}
    p2 = %{id: :p2, priority: :ship}
    queue = Enum.reduce([s1, p1, s2, p2], [], &Rigd.Fleet.Exe.enqueue(&2, &1))
    assert Enum.map(queue, & &1.id) == [:p1, :p2, :s1, :s2]
  end

  test "a reason is the output's last non-blank line" do
    assert Golden.last_line("a\nb\r\n\n  ") == "b"
    assert Golden.last_line("") == "no output"
  end

  test "gate/fleet.json names no Sprites: the pool is retired" do
    json = Application.fetch_env!(:rigd, :fleet_config) |> File.read!() |> JSON.decode!()
    refute Map.has_key?(json, "sprites")
    assert json["exe"]
  end

  test "gate/fleet.json's options name the gate and deadline that exist" do
    opts = Rigd.Fleet.Supervisor.options(Application.fetch_env!(:rigd, :fleet_config))
    assert File.exists?(opts[:gate]), opts[:gate]
    assert File.exists?(opts[:deadline]), opts[:deadline]
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

    assert {"none none " <> out, 0} = Golden.cmd(gate, [], tmp, 10)
    [dir, child_path] = String.split(out, "\n", trim: true)
    assert dir == Path.expand(tmp)
    refute child_path =~ erts
    assert child_path =~ "/usr/bin"
  end

  @tag :tmp_dir
  test "a golden run first removes the worktrees a killed one left on its VM", %{
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

    assert :ok = Golden.prune(repo, "rig-gate-1")
    refute File.exists?(left)
    assert File.exists?(other)
    {list, 0} = System.cmd("git", ["-C", repo, "worktree", "list"])
    refute list =~ "rig-gate-1-7"
  end
end
