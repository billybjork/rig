defmodule Gate.SpriteTest do
  use ExUnit.Case, async: true

  alias Gate.Sprite

  test "the launch line counts only once it is whole" do
    assert Sprite.launched("noise gate-launched be68cf3e-3d4f-41f") == nil

    assert Sprite.launched("noise gate-launched be68cf3e-3d4f-41f6-1598\r\n.") ==
             "be68cf3e-3d4f-41f6-1598"

    assert Sprite.launched("gate-launched life-1\n") == "life-1"
  end

  test "the TTY's terminal sequences inside the launch line are not the life's" do
    seen = "gate-launched 92464127-55\e[?1004s\e[?2004s\e[>u565238554d-831\r\n\e]0;t\a."
    assert Sprite.launched(seen) == "92464127-55565238554d-831"
  end

  test "a poll's header and the log's bytes, with the CLI's CRLFs undone" do
    out =
      "phase run\r\nrc 0\r\nlife l-1\r\njob down\r\nkeeper down\r\nsize 12\r\ngate-poll: log\nline\r\nexit 0\n"

    assert {:ok, %{"phase" => "run", "rc" => "0", "life" => "l-1", "job" => "down", "size" => 12},
            "line\nexit 0\n"} =
             Sprite.parse_poll(out)

    assert {:ok, :gone, ""} = Sprite.parse_poll("gate-poll: gone\n")

    assert {:error, "an unreadable poll: Error: connection closed"} =
             Sprite.parse_poll("Error: connection closed\n")
  end
end
