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

  describe "restore?/4, the first look at a server" do
    @saved %{"server" => "i0", "sessions" => [%{"session" => "dev", "tabs" => [%{}]}]}
    @fresh %{"instance_id" => "i1", "started_at" => "2026-11-21T10:00:00Z"}
    @now ~U[2026-11-21 10:01:00Z]

    defp fresh_tab(panes), do: %{tab("s1", "w1", panes, nil) | server: @fresh}

    test "a Rex just restarted, still as it opens, restores the last server's set" do
      assert Open.restore?(@saved, [fresh_tab([pane("b1")])], @fresh, @now)
    end

    test "nothing saved, or saved under this same server (rigd restarted), restores nothing" do
      refute Open.restore?(nil, [fresh_tab([pane("b1")])], @fresh, @now)

      refute Open.restore?(%{@saved | "server" => "i1"}, [fresh_tab([pane("b1")])], @fresh, @now)
    end

    test "a saved set without tabs restores nothing" do
      empty = %{@saved | "sessions" => [%{"session" => "dev", "tabs" => []}]}
      refute Open.restore?(empty, [fresh_tab([pane("b1")])], @fresh, @now)
    end

    test "a server that has run a while restores nothing" do
      refute Open.restore?(@saved, [fresh_tab([pane("b1")])], @fresh, ~U[2026-11-21 10:06:00Z])

      refute Open.restore?(
               @saved,
               [fresh_tab([pane("b1")])],
               %{@fresh | "started_at" => nil},
               @now
             )
    end

    test "a Rex that already shows more than its first tab, or an agent, restores nothing" do
      two = [fresh_tab([pane("b1")]), %{fresh_tab([pane("b2")]) | window_id: "w2"}]
      refute Open.restore?(@saved, two, @fresh, @now)

      agent = fresh_tab([pane("b1", %{app: "claude-code"})])
      refute Open.restore?(@saved, [agent], @fresh, @now)
    end
  end
end
