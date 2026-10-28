defmodule Rigd.Awake do
  @moduledoc """
  Keeps the Mac awake while Activity is not empty (and for a minute after,
  so the gap between an agent's turns doesn't let it sleep). Replaces
  Amphetamine and a manual `caffeinate -dimsu`.

    * Lid open: holds `caffeinate -ims`, which ends with rigd (`-w`).
    * Lid closed: caffeinate can't stop clamshell sleep, so while work runs
      rigd also sets `pmset -a disablesleep 1` through a sudoers rule for
      exactly that (`rigd/sudoers`). Only on AC power or above
      30% battery, without thermal pressure, and for at most 4 hours of
      lid-closed time; past any of those it clears it and the Mac sleeps.
      It is set ahead of the lid closing, since a closed lid sleeps the Mac
      before rigd could act, and cleared when work ends, when rigd stops, and
      when it starts (a leftover from a crash or a reboot).
  """

  use GenServer
  require Logger

  @linger 60
  @battery_min 30
  @lid_cap 4 * 3600
  @pmset "/usr/bin/pmset"

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  What to hold given whether work runs (`active`, `empty_since` for the
  linger), Presence, and whether the sudoers rule is in place. Returns
  `%{hold: bool, disable_sleep: bool, why: text}`.
  """
  def plan(%{active: active, empty_since: empty_since, presence: p, sudo: sudo, now: now}) do
    hold = active or (empty_since != nil and now - empty_since < @linger)

    blocker =
      cond do
        not hold ->
          "nothing runs"

        not sudo ->
          "no sudoers rule for pmset (rigd/sudoers)"

        p == nil ->
          "presence not read yet"

        not p.ac and p.battery < @battery_min ->
          "battery #{p.battery}% < #{@battery_min}%"

        not p.thermal_ok ->
          "thermal pressure"

        p.lid_closed_since && now - p.lid_closed_since > @lid_cap ->
          "lid closed over #{div(@lid_cap, 3600)}h"

        true ->
          nil
      end

    %{hold: hold, disable_sleep: blocker == nil, why: blocker || "work runs"}
  end

  @impl true
  def init(nil) do
    Process.flag(:trap_exit, true)
    Rigd.Bus.subscribe(:activity)
    Rigd.Bus.subscribe(:presence)
    if sleep_disabled?(), do: set_disable_sleep(false, "left set by an earlier run")

    {:ok,
     %{
       active: false,
       empty_since: nil,
       presence: nil,
       sudo: sudo?(),
       sudo_checked: now(),
       caff: nil,
       disabled: false,
       items: 0
     }}
  end

  @impl true
  def handle_info({:activity, a}, st) do
    active = map_size(a.items) > 0

    empty_since =
      cond do
        active -> nil
        st.active -> now()
        true -> st.empty_since
      end

    apply_plan(%{st | active: active, empty_since: empty_since, items: map_size(a.items)})
  end

  def handle_info({:presence, p}, st), do: apply_plan(%{st | presence: p})

  def handle_info({:EXIT, port, _}, %{caff: port} = st), do: {:noreply, %{st | caff: nil}}

  def handle_info({port, {:exit_status, _}}, %{caff: port} = st),
    do: {:noreply, %{st | caff: nil}}

  def handle_info(_, st), do: {:noreply, st}

  @impl true
  def terminate(_, st) do
    release_caffeinate(st.caff)
    if st.disabled or sleep_disabled?(), do: set_disable_sleep(false, "rigd stopping")
  end

  defp apply_plan(st) do
    # The rule may be installed after rigd starts: look again now and then.
    st =
      if not st.sudo and now() - st.sudo_checked > 300,
        do: %{st | sudo: sudo?(), sudo_checked: now()},
        else: st

    plan = plan(Map.put(st, :now, now()))

    caff =
      cond do
        plan.hold and st.caff == nil ->
          Logger.info("awake: holding (#{st.items} running)")
          hold_caffeinate()

        not plan.hold and st.caff != nil ->
          Logger.info("awake: released")
          release_caffeinate(st.caff)

        true ->
          st.caff
      end

    disabled =
      if plan.disable_sleep != st.disabled,
        do: set_disable_sleep(plan.disable_sleep, plan.why),
        else: st.disabled

    Rigd.Bus.publish(:awake, %{
      holding: caff != nil,
      sleep_disabled: disabled,
      why: plan.why,
      sudo: st.sudo
    })

    {:noreply, %{st | caff: caff, disabled: disabled}}
  end

  defp hold_caffeinate do
    Port.open({:spawn_executable, "/usr/bin/caffeinate"}, [
      :exit_status,
      args: ["-ims", "-w", System.pid()]
    ])
  end

  defp release_caffeinate(nil), do: nil

  defp release_caffeinate(port) do
    with {:os_pid, pid} <- Port.info(port, :os_pid), do: System.cmd("kill", [to_string(pid)])
    nil
  end

  # Returns the state pmset is left in.
  defp set_disable_sleep(on, why) do
    case Rigd.Cmd.run("sudo", ["-n", @pmset, "-a", "disablesleep", if(on, do: "1", else: "0")]) do
      {_, 0} ->
        Logger.info("awake: disablesleep #{if on, do: "set", else: "cleared"} (#{why})")
        on

      {out, status} ->
        Logger.warning("awake: sudo pmset disablesleep exited #{status}: #{String.trim(out)}")
        sleep_disabled?()
    end
  end

  defp sleep_disabled? do
    (Rigd.Cmd.out("pmset", ["-g"]) || "") =~ ~r/SleepDisabled\s+1/
  end

  defp sudo? do
    match?({_, 0}, Rigd.Cmd.run("sudo", ["-n", "-l", @pmset, "-a", "disablesleep", "1"]))
  end

  defp now, do: System.monotonic_time(:second)
end
