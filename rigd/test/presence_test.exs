defmodule Rigd.PresenceTest do
  use ExUnit.Case, async: true
  alias Rigd.Presence

  test "reads battery, power source, and thermal pressure from pmset" do
    batt =
      "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t93%; discharging; 4:59 remaining present: true\n"

    calm =
      "Note: No thermal warning level has been recorded\nNote: No performance warning level has been recorded\n"

    assert Presence.power(batt, calm) == %{ac: false, battery: 93, thermal_ok: true}

    hot =
      "CPU Power notify\n\tCPU_Scheduler_Limit \t= 100\n\tCPU_Available_CPUs \t= 10\n\tCPU_Speed_Limit \t= 70\n"

    assert %{thermal_ok: false} = Presence.power(batt, hot)
    assert %{thermal_ok: false} = Presence.power(batt, "Thermal warning level set to 2.")

    assert %{ac: true, battery: 100} =
             Presence.power(
               "Now drawing from 'AC Power'\n -InternalBattery-0\t100%; charged",
               calm
             )
  end

  test "away when the lid is closed, the screen is locked, or idle five minutes" do
    base = %{lid_closed: false, locked: false, idle_s: 10}
    refute Presence.away?(base)
    assert Presence.away?(%{base | lid_closed: true})
    assert Presence.away?(%{base | locked: true})
    assert Presence.away?(%{base | idle_s: 300})
  end
end
