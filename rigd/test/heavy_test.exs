defmodule Rigd.HeavyTest do
  use ExUnit.Case, async: false

  alias Rigd.Heavy

  @moduletag :tmp_dir
  @moduletag :capture_log

  @heavy Path.expand("../../bin/heavy", __DIR__)

  setup %{tmp_dir: tmp} do
    path = Path.join(System.tmp_dir!(), "heavy-#{System.unique_integer([:positive])}.sock")
    {:ok, pid} = Heavy.start_link(socket: path, slots: %{"cpu" => 1, "net" => 1}, demote: false)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm(path)
    end)

    %{path: path, tmp: tmp}
  end

  defp take(path, kind, label) do
    {:ok, sock} = :gen_tcp.connect({:local, path}, 0, [:binary, packet: :line, active: false])
    msg = %{take: %{kind: kind, label: label, pid: 1, cwd: "/x"}}
    :ok = :gen_tcp.send(sock, JSON.encode!(msg) <> "\n")
    sock
  end

  defp recv(sock, timeout \\ 2000) do
    case :gen_tcp.recv(sock, 0, timeout) do
      {:ok, line} -> JSON.decode!(line)
      {:error, why} -> why
    end
  end

  test "a slot per kind: the next waits, told who holds it, and gets it once the holder goes",
       %{path: path} do
    a = take(path, "cpu", "render a")
    assert recv(a) == %{"granted" => "cpu"}

    b = take(path, "cpu", "render b")
    assert recv(b) == %{"waiting" => %{"ahead" => 0, "holders" => ["render a"]}}
    assert recv(b, 200) == :timeout

    # Another kind has its own slots.
    n = take(path, "net", "upload")
    assert recv(n) == %{"granted" => "net"}

    assert %{holders: [_, _], waiting: [%{label: "render b"}]} = Heavy.status()
    :gen_tcp.close(a)
    assert recv(b) == %{"granted" => "cpu"}
  end

  test "bin/heavy holds a slot while its command runs, waits its turn, and exits with the command's status",
       %{path: path, tmp: tmp} do
    env = [{"RIGD_HEAVY_SOCKET", path}]
    holder = take(path, "cpu", "first")
    assert recv(holder) == %{"granted" => "cpu"}

    marker = Path.join(tmp, "ran")

    task =
      Task.async(fn ->
        System.cmd(
          @heavy,
          ["cpu", "--label", "second", "--", "sh", "-c", ~S|touch "$1"; exit 3|, "sh", marker],
          env: env,
          stderr_to_stdout: true
        )
      end)

    Process.sleep(500)
    refute File.exists?(marker), "it ran without its turn"
    :gen_tcp.close(holder)
    {out, status} = Task.await(task, 5000)
    assert out =~ "heavy: waiting for a cpu slot (0 ahead; holding: first)"
    assert status == 3
    assert File.exists?(marker)
    assert %{holders: [], waiting: []} = Heavy.status()
  end

  test "bin/heavy without rigd runs the command at once, saying so" do
    {out, 0} =
      System.cmd(@heavy, ["net", "--", "true"],
        env: [{"RIGD_HEAVY_SOCKET", "/nonexistent/heavy.sock"}],
        stderr_to_stdout: true
      )

    assert out =~ "running without a slot"
  end

  defp p(pid, ppid, cpu, cmd), do: %{pid: pid, ppid: ppid, cpu: cpu, cmd: cmd}

  defp procs do
    [
      p(10, 1, 9.0, "claude --dangerously-skip-permissions"),
      # A job an agent's Bash started: a shell, uv, a pool of workers.
      p(20, 10, 0.0, "/bin/zsh -c uv run python tune.py"),
      p(21, 20, 80.0, "/Users/b/.venv/bin/python tune.py"),
      p(22, 21, 75.0, "/Users/b/.venv/bin/python tune.py"),
      # A background terminal's job, right under Rex's server.
      p(30, 764, 0.0, "/Applications/Rex.app/x"),
      p(
        764,
        1,
        3.0,
        "/Users/b/Library/Application Support/RexServer/Rex Server.app/Contents/MacOS/rex"
      ),
      p(31, 764, 210.0, "uv run python pieces.py"),
      # An app the Mac runs: under neither.
      p(40, 1, 300.0, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    ]
  end

  test "demotions: a job under an agent or Rex hot for two samples running, its CPU summed; apps never" do
    {hot, demote} = Heavy.demotions(procs(), [], MapSet.new(), 150.0)
    assert hot == MapSet.new([20, 31])
    assert demote == %{}

    {_hot, demote} = Heavy.demotions(procs(), [], hot, 150.0)

    assert %{20 => %{pids: pids, cpu: 155.0}, 31 => %{cpu: 210.0, cmd: "uv run python pieces.py"}} =
             demote

    assert Enum.sort(pids) == [20, 21, 22]
    refute Map.has_key?(demote, 40)
    # An agent's Bash job is named by its busiest process, not its shell.
    assert %{top: "python tune.py", agent: 10} = demote[20]
  end

  @tag :tmp_dir
  test "who: the Claude session's name, Rex, else the agent's command", %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "10.json"), ~s({"pid": 10, "name": "heaters-be"}))
    assert Heavy.who(10, procs(), tmp) == "session heaters-be"
    assert Heavy.who(764, procs(), tmp) == "Rex"
    assert Heavy.who(5, procs(), tmp) == "under pid 5"
  end

  test "demotions: a slot's job and its children are spared" do
    {hot, _} = Heavy.demotions(procs(), [21, 31], MapSet.new([20, 31]), 150.0)
    assert hot == MapSet.new()
  end

  test "an agent or Rex is the edge of a job, never part of one" do
    assert Heavy.boundary?(p(1, 0, 0.0, "claude --resume x"))
    assert Heavy.boundary?(p(1, 0, 0.0, "/Users/b/.local/bin/claude"))
    assert Heavy.boundary?(p(1, 0, 0.0, "/opt/homebrew/bin/codex exec"))
    assert Heavy.boundary?(p(1, 0, 0.0, "/Applications/Rex Beta.app/Contents/MacOS/Rex"))
    refute Heavy.boundary?(p(1, 0, 0.0, "/Users/b/.venv/bin/python claude.py"))
  end

  test "demote: nothing while the laptop has room; back to normal once it is calm" do
    st = %{holders: [], hot: MapSet.new([20, 31]), demoted: %{}, cores: 12}
    assert Heavy.demote(st, procs(), 6.0).demoted == %{}

    demoted = %{31 => %{cmd: "x", cpu: 210.0, pids: [999_999]}}
    assert Heavy.demote(%{st | demoted: demoted}, procs(), 10.0).demoted == demoted
    assert Heavy.demote(%{st | demoted: demoted}, procs(), 8.0).demoted == %{}
  end
end
