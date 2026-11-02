defmodule Tidy.ProcessesTest do
  use ExUnit.Case, async: true

  alias Tidy.Processes
  alias Tidy.Processes.Proc

  setup do
    primary = Path.join(System.tmp_dir!(), "tidy-proc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(primary, ".worktrees/live"))
    on_exit(fn -> File.rm_rf!(primary) end)

    {:ok, config} =
      Tidy.Config.from_map(%{"dev_commands" => "^npm run (watch|dev)"}, primary, primary)

    %{config: config, primary: primary}
  end

  test "lsof and ps make one record per process, cwd where lsof saw one" do
    lsof = "p10\ncnode\nn/p/.worktrees/gone\np11\nczsh\nn/p\n"
    ps = "   10     1 node server.js\n   11   900 -zsh\n   12    10 esbuild --watch  \n"

    assert Enum.sort_by(Processes.parse(lsof, ps), & &1.pid) == [
             %Proc{
               pid: 10,
               ppid: 1,
               comm: "node",
               cwd: "/p/.worktrees/gone",
               args: "node server.js"
             },
             %Proc{pid: 11, ppid: 900, comm: "zsh", cwd: "/p", args: "-zsh"},
             %Proc{pid: 12, ppid: 10, comm: "", cwd: "", args: "esbuild --watch"}
           ]
  end

  test "what is orphaned", %{config: config, primary: p} do
    gone = Path.join(p, ".worktrees/gone")
    live = Path.join(p, ".worktrees/live")
    proc = &%Proc{pid: 1000, ppid: &1, comm: &2, cwd: &3, args: &4}

    assert Processes.orphaned(proc.(1, "npm", p, "npm run watch:css"), config) ==
             "its dev server is gone"

    assert Processes.orphaned(proc.(1, "beam.smp", gone, "beam.smp -- mix phx.server"), config) ==
             "its worktree was removed"

    assert Processes.orphaned(proc.(77, "esbuild-darwin", gone, "esbuild"), config) ==
             "its worktree was removed"

    # A server still running, a dev command with its parent, a shell or an
    # agent in a removed worktree, anything outside the project: left.
    refute Processes.orphaned(proc.(77, "npm", live, "npm run dev"), config)
    refute Processes.orphaned(proc.(77, "node", live, "node x"), config)
    refute Processes.orphaned(proc.(77, "zsh", gone, "-zsh"), config)
    refute Processes.orphaned(proc.(77, "claude", gone, "claude"), config)
    refute Processes.orphaned(proc.(1, "npm", "/elsewhere", "npm run dev"), config)
    refute Processes.orphaned(proc.(1, "npm", p <> "-other", "npm run dev"), config)
  end

  test "prune stops each orphan with its tree; report only says so", %{config: config, primary: p} do
    procs = [
      %Proc{pid: 10, ppid: 1, comm: "npm", cwd: p, args: "npm run watch:js"},
      %Proc{pid: 11, ppid: 10, comm: "node", cwd: p, args: "node esbuild.js"},
      %Proc{pid: 12, ppid: 11, comm: "esbuild", cwd: p, args: "esbuild"},
      %Proc{pid: 13, ppid: 1, comm: "node", cwd: p, args: "node other"}
    ]

    me = self()
    env = %{procs: fn -> procs end, kill: &send(me, {:kill, &1})}

    name = Path.basename(p)

    assert Processes.run(config, :prune, env) ==
             ["stopped npm run watch:js (pid 10, #{name}): its dev server is gone"]

    assert_received {:kill, [10, 11, 12]}

    assert Processes.run(config, :report, env) ==
             ["npm run watch:js (pid 10, #{name}): its dev server is gone; 'tidy prune' stops it"]

    refute_received {:kill, _}
  end
end
