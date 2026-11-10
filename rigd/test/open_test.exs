defmodule Rigd.OpenTest do
  use ExUnit.Case, async: true
  alias Rigd.Open

  @server %{"instance_id" => "i1", "started_at" => "2026-11-10T18:11:39Z"}

  defp pane(id, extra \\ %{}),
    do: Map.merge(%{block: id, cwd: "/dev/#{id}", title: nil, app: nil, pid: 1}, extra)

  defp tab(sid, wid, panes, layout),
    do: %{
      session_id: sid,
      session: "s-#{sid}",
      window_id: wid,
      label: "L #{wid}",
      panes: panes,
      layout: layout,
      server: @server
    }

  test "each session's tabs keep their split layout, each pane what reopening it needs" do
    claude =
      pane("b2", %{
        app: "claude-code",
        title: "Fix it",
        claude_session: "c-2",
        skip_permissions: true
      })

    layout = %{
      "split" => %{
        "direction" => "vertical",
        "ratio" => 0.3,
        "before" => %{"block" => "b1"},
        "after" => %{"block" => "b2"}
      }
    }

    snap =
      Open.snapshot([
        tab("s1", "w1", [pane("b1"), claude], layout),
        tab("s2", "w2", [pane("b3")], %{"block" => "b3"})
      ])

    assert snap == %{
             "server" => "i1",
             "server_started" => "2026-11-10T18:11:39Z",
             "sessions" => [
               %{
                 "session" => "s-s1",
                 "tabs" => [
                   %{
                     "label" => "L w1",
                     "layout" => %{
                       "split" => %{
                         "direction" => "vertical",
                         "ratio" => 0.3,
                         "before" => %{"cwd" => "/dev/b1"},
                         "after" => %{
                           "cwd" => "/dev/b2",
                           "app" => "claude-code",
                           "title" => "Fix it",
                           "claude_session" => "c-2",
                           "skip_permissions" => true
                         }
                       }
                     }
                   }
                 ]
               },
               %{
                 "session" => "s-s2",
                 "tabs" => [%{"label" => "L w2", "layout" => %{"cwd" => "/dev/b3"}}]
               }
             ]
           }
  end

  test "a block in the layout that is not a terminal is dropped, its split collapsing" do
    layout = %{
      "split" => %{
        "direction" => "horizontal",
        "ratio" => 0.5,
        "before" => %{"block" => "x"},
        "after" => %{"block" => "b1"}
      }
    }

    assert %{"sessions" => [%{"tabs" => [%{"layout" => %{"cwd" => "/dev/b1"}}]}]} =
             Open.snapshot([tab("s1", "w1", [pane("b1")], layout)])
  end

  test "a tab without a layout has its panes side by side; one without terminals is left out" do
    snap =
      Open.snapshot([tab("s1", "w1", [pane("b1"), pane("b2")], nil), tab("s1", "w2", [], nil)])

    assert %{
             "sessions" => [
               %{
                 "tabs" => [
                   %{
                     "layout" => %{
                       "split" => %{
                         "direction" => "horizontal",
                         "before" => %{"cwd" => "/dev/b1"}
                       }
                     }
                   }
                 ]
               }
             ]
           } = snap
  end

  test "no tabs, nothing to save" do
    assert Open.snapshot([]) == nil
  end

  test "a change is saved only once it has held for the settle time" do
    st = %{saved: %{"a" => 1}, pending: nil}

    st = Open.consider(%{"a" => 1}, 0, st)
    assert st.pending == nil

    # Rex flickering during a shutdown: each new state restarts the wait.
    st = Open.consider(%{"a" => 2}, 0, st)
    assert st.pending == {%{"a" => 2}, 0}
    st = Open.consider(%{"a" => 3}, 10_000, st)
    assert st.pending == {%{"a" => 3}, 10_000}
    st = Open.consider(%{"a" => 3}, 25_000, st)
    assert st.pending == {%{"a" => 3}, 10_000}
    assert st.saved == %{"a" => 1}

    # Back to what was saved before the wait ended: nothing to write.
    assert Open.consider(%{"a" => 1}, 26_000, st).pending == nil
  end

  test "the saved file moves aside when Rex has restarted and it held tabs" do
    old = %{"server" => "i0", "sessions" => [%{"session" => "dev", "tabs" => [%{}]}]}

    assert Open.rotate?(old, %{"server" => "i1"})
    refute Open.rotate?(old, %{"server" => "i0"})

    refute Open.rotate?(%{old | "sessions" => [%{"session" => "dev", "tabs" => []}]}, %{
             "server" => "i1"
           })

    refute Open.rotate?(nil, %{"server" => "i1"})
  end
end
