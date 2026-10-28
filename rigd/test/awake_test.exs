defmodule Rigd.AwakeTest do
  use ExUnit.Case, async: true
  alias Rigd.Awake

  @present %{ac: false, battery: 80, thermal_ok: true, lid_closed_since: nil}
  defp plan(over),
    do:
      Awake.plan(
        Map.merge(
          %{active: true, empty_since: nil, presence: @present, sudo: true, now: 10_000},
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
end
