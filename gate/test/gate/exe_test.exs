defmodule Gate.ExeTest do
  # The fake ssh and su are on PATH, their VMs in $FAKE_VMS, all global.
  use ExUnit.Case, async: false

  alias Gate.{Exe, Fake}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    env = Fake.setup(tmp)
    on_exit(fn -> Fake.stop(env.root) end)
    env
  end

  defp calls(%{root: root}), do: File.read!(Path.join(root, "calls"))

  test "a host named <vm>.exe.xyz is an exe.dev VM" do
    assert Exe.host?("rig-golden.exe.xyz")
    refute Exe.host?("gate-1")
    refute Exe.host?("exe.xyz.example")
  end

  test "exe's one host key is pinned for every VM name" do
    known = File.read!(Path.join(Gate.root(), "exe/known_hosts"))
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

  test "the launch line counts only once it is whole" do
    assert Exe.launched("noise\ngate-launched be68cf3e-3d4f-41f") == "be68cf3e-3d4f-41f"

    assert Exe.launched("noise\ngate-launched be68cf3e-3d4f-41f6-1598\n") ==
             "be68cf3e-3d4f-41f6-1598"

    assert Exe.launched("gate-launched\n") == nil
    assert Exe.launched("no line\n") == nil
  end

  test "a poll's header and the log's bytes" do
    out = "phase run\nrc 0\nlife l-1\njob down\nsize 12\ngate-poll: log\nline\nexit 0\n"

    assert {:ok, %{"phase" => "run", "rc" => "0", "life" => "l-1", "job" => "down", "size" => 12},
            "line\nexit 0\n"} = Exe.parse_poll(out)

    assert {:ok, :gone, ""} = Exe.parse_poll("gate-poll: gone\n")

    assert {:error, "an unreadable poll: ssh: connect to host x port 22: Connection refused"} =
             Exe.parse_poll("ssh: connect to host x port 22: Connection refused\n")
  end

  test "what a VM holds: the tip a bundle brought, the newest candidate it has" do
    sha = String.duplicate("a", 40)
    assert {:ok, ^sha, nil} = Exe.parse_holds("tip #{sha}\nhave\n")
    assert {:ok, nil, ^sha} = Exe.parse_holds("tip\nhave #{sha}\n")
    assert {:error, "an unreadable answer: oops"} = Exe.parse_holds("oops\n")
  end
end
