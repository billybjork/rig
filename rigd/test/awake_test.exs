defmodule Rigd.AwakeTest do
  use ExUnit.Case, async: true
  alias Rigd.Awake

  @present %{
    ac: false,
    battery: 80,
    thermal_ok: true,
    lid_closed: false,
    clamshell_sleeps: true,
    lid_closed_since: nil
  }
  @shut %{@present | lid_closed: true, lid_closed_since: 9_000}

  defp plan(over),
    do:
      Awake.plan(
        Map.merge(
          %{
            active: true,
            empty_since: nil,
            presence: @present,
            sudo: true,
            now: 10_000,
            disabled: false,
            holding: false
          },
          over
        )
      )

  test "holds and disables sleep while work runs" do
    assert %{hold: true, disable_sleep: true} = plan(%{})
  end

  test "lingers a minute after work ends, then lets go of both" do
    assert %{hold: true, disable_sleep: true} = plan(%{active: false, empty_since: 9_950})

    assert %{hold: false, disable_sleep: false, why: "nothing runs"} =
             plan(%{active: false, empty_since: 9_900})

    assert %{hold: false} = plan(%{active: false, empty_since: nil})
  end

  test "keeps only caffeinate below 30% battery, unless on AC" do
    low = %{@present | battery: 29}
    assert %{hold: true, disable_sleep: false, why: "battery 29% < 30%"} = plan(%{presence: low})
    assert %{disable_sleep: true} = plan(%{presence: %{low | ac: true}})
  end

  test "lets go of disablesleep under thermal pressure or past the lid cap" do
    assert %{hold: true, disable_sleep: false, why: "thermal pressure"} =
             plan(%{presence: %{@present | thermal_ok: false}})

    assert %{disable_sleep: true} =
             plan(%{presence: %{@present | lid_closed_since: 10_000 - 3 * 3600}})

    assert %{disable_sleep: false, why: "lid closed over 4h"} =
             plan(%{presence: %{@present | lid_closed_since: 10_000 - 5 * 3600}})
  end

  test "never disables sleep without the sudoers rule or before Presence" do
    assert %{hold: true, disable_sleep: false} = plan(%{sudo: false})
    assert %{hold: true, disable_sleep: false} = plan(%{presence: nil})
  end

  test "sleeps the Mac when work ends with the lid closed, since macOS won't" do
    held = %{active: false, empty_since: 9_900, presence: @shut, disabled: true, holding: true}

    assert %{hold: false, disable_sleep: false, sleep_now: true, why: "nothing runs"} =
             plan(held)

    # Not during the linger, and not with the lid open.
    assert %{sleep_now: false} = plan(%{held | empty_since: 9_950})
    assert %{sleep_now: false} = plan(%{held | presence: %{@shut | lid_closed: false}})
  end

  test "sleeps the Mac when a limit clears disablesleep with the lid closed" do
    over = %{
      presence: %{@shut | lid_closed_since: 10_000 - 5 * 3600},
      disabled: true,
      holding: true
    }

    assert %{hold: true, disable_sleep: false, sleep_now: true} = plan(over)

    low = %{over | presence: %{@shut | battery: 20}}
    assert %{disable_sleep: false, sleep_now: true, why: "battery 20% < 30%"} = plan(low)
  end

  test "sleeps the Mac when work ends after a limit already cleared disablesleep" do
    # The lid cap cleared it while work still ran; caffeinate alone kept it awake.
    over = %{presence: %{@shut | lid_closed_since: 10_000 - 5 * 3600}, holding: true}
    assert %{sleep_now: false} = plan(over)
    assert %{sleep_now: true} = plan(Map.merge(over, %{active: false, empty_since: 9_900}))
  end

  test "sleeps only on the change, not again once let go" do
    assert %{sleep_now: false} =
             plan(%{active: false, empty_since: 9_000, presence: @shut})

    assert %{sleep_now: false} =
             plan(%{presence: %{@shut | battery: 20}})
  end

  test "never sleeps the Mac in clamshell mode (an external display)" do
    assert %{disable_sleep: false, sleep_now: false} =
             plan(%{
               active: false,
               empty_since: 9_900,
               presence: %{@shut | clamshell_sleeps: false},
               disabled: true,
               holding: true
             })
  end

  test "keeps a leftover disablesleep until Activity and Presence are read" do
    assert %{disable_sleep: true, sleep_now: false, why: "activity not read yet"} =
             plan(%{active: nil, presence: @shut, disabled: true})

    assert %{disable_sleep: true, sleep_now: false, why: "presence not read yet"} =
             plan(%{active: false, presence: nil, disabled: true})

    # Read: work runs, so it stays; nothing runs, so it goes and the Mac sleeps.
    assert %{disable_sleep: true, sleep_now: false} = plan(%{presence: @shut, disabled: true})

    assert %{disable_sleep: false, sleep_now: true} =
             plan(%{active: false, presence: @shut, disabled: true})
  end
end
