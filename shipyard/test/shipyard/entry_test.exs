defmodule Shipyard.EntryTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  defp git(dir, args) do
    {out, 0} =
      System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@t" | args],
        cd: dir,
        stderr_to_stdout: true
      )

    String.trim(out)
  end

  test "each gate runs rig's main as it begins, from a clone beside the worker's own",
       %{tmp_dir: tmp} do
    rig = Path.join(tmp, "rig")
    File.mkdir_p!(rig)
    git(rig, ["init", "-q", "-b", "main"])
    git(rig, ["commit", "-q", "--allow-empty", "-m", "a"])
    app = Path.join(tmp, "app")
    git(tmp, ["clone", "-q", rig, app])
    System.put_env("RIG", app)
    on_exit(fn -> System.delete_env("RIG") end)
    ship = %Shipyard{home: tmp, env: []}

    assert [{"RIG", dir}] = Shipyard.Entry.gate_rig(ship)
    assert git(dir, ["rev-parse", "HEAD"]) == git(rig, ["rev-parse", "main"])

    # A fix lands on rig's main while the worker runs: the next gate has it.
    git(rig, ["commit", "-q", "--allow-empty", "-m", "a gate fix"])
    assert [{"RIG", ^dir}] = Shipyard.Entry.gate_rig(ship)
    assert git(dir, ["log", "-1", "--format=%s"]) == "a gate fix"
    assert git(app, ["log", "-1", "--format=%s"]) == "a"

    # Without RIG, the project's script finds rig itself.
    System.delete_env("RIG")
    assert Shipyard.Entry.gate_rig(ship) == []
  end
end
