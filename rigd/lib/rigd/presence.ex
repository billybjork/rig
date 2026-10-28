defmodule Rigd.Presence do
  @moduledoc """
  Whether Billy is at the Mac, and the power facts Awake guards on, read
  every few seconds and published as `{:presence, state}`. He is away when
  the lid is closed, the screen is locked, or there has been no input for
  5 minutes.
  """

  use GenServer

  @every :timer.seconds(5)
  @away_idle 300

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    send(self(), :tick)
    {:ok, nil}
  end

  @impl true
  def handle_info(:tick, prev) do
    now = System.monotonic_time(:second)
    p = read()

    lid_closed_since =
      cond do
        not p.lid_closed -> nil
        prev && prev.lid_closed_since -> prev.lid_closed_since
        true -> now
      end

    p = Map.merge(p, %{lid_closed_since: lid_closed_since, away: away?(p)})
    Rigd.Bus.publish(:presence, p)
    Process.send_after(self(), :tick, @every)
    {:noreply, p}
  end

  def away?(p), do: p.lid_closed or p.locked or p.idle_s >= @away_idle

  defp read do
    root = Rigd.Cmd.out("ioreg", ["-n", "Root", "-d1"]) || ""
    hid = Rigd.Cmd.out("ioreg", ["-c", "IOHIDSystem", "-d", "4"]) || ""
    clam = Rigd.Cmd.out("ioreg", ["-r", "-k", "AppleClamshellState", "-d", "1"]) || ""

    Map.merge(
      %{
        lid_closed: clam =~ ~r/"AppleClamshellState" = Yes/,
        locked: root =~ ~r/"CGSSessionScreenIsLocked"=Yes/,
        idle_s: idle_seconds(hid)
      },
      power(
        Rigd.Cmd.out("pmset", ["-g", "batt"]) || "",
        Rigd.Cmd.out("pmset", ["-g", "therm"]) || ""
      )
    )
  end

  defp idle_seconds(hid) do
    case Regex.run(~r/"HIDIdleTime" = (\d+)/, hid) do
      [_, ns] -> div(String.to_integer(ns), 1_000_000_000)
      _ -> 0
    end
  end

  @doc """
  Battery and thermal facts from `pmset -g batt` and `pmset -g therm`.
  Thermal pressure is any recorded warning level or a CPU speed limit.
  """
  def power(batt, therm) do
    limit =
      case Regex.run(~r/CPU_Speed_Limit\s*=\s*(\d+)/, therm) do
        [_, n] -> String.to_integer(n)
        _ -> 100
      end

    warning =
      case Regex.run(~r/hermal warning level (?:set to|is) (\d+)/i, therm) do
        [_, n] -> String.to_integer(n)
        _ -> 0
      end

    %{
      ac: batt =~ "'AC Power'",
      battery:
        case Regex.run(~r/(\d+)%/, batt) do
          [_, n] -> String.to_integer(n)
          _ -> 100
        end,
      thermal_ok: limit >= 100 and warning == 0
    }
  end
end
