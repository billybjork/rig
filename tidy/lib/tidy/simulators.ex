defmodule Tidy.Simulators do
  @moduledoc """
  iOS Simulators booted for more than two hours, machine-wide, only ever
  reported: another session may still be driving one, so the session that
  booted it shuts it down. Its `launchd_sim`'s elapsed time is how long it
  has been up.
  """

  @limit 2 * 3600

  def run(_config, _mode, env) do
    for {name, udid, secs, up} <- env.simulators.(), secs > @limit do
      "iOS Simulator '#{name}' booted for #{up}; `xcrun simctl shutdown #{udid}` unless a session is using it"
    end
  end

  @doc "`{name, udid, seconds_up, etime}` for each booted Simulator."
  def list do
    with json when json != nil <-
           Tidy.Cmd.out("xcrun", ~w(simctl list devices booted -j), stderr: false, timeout: 20),
         ps when ps != nil <- Tidy.Cmd.out("ps", ["-Ao", "etime=,command="]) do
      booted(json, ps)
    else
      _ -> []
    end
  end

  def booted(json, ps) do
    {:ok, %{"devices" => runtimes}} = JSON.decode(json)

    for {_runtime, devices} <- runtimes,
        %{"state" => "Booted", "name" => name, "udid" => udid} <- devices do
      up = etime(ps, udid)
      {name, udid, seconds(up), up}
    end
  end

  defp etime(ps, udid) do
    ps
    |> String.split("\n", trim: true)
    |> Enum.find_value("0:00", fn line ->
      if String.contains?(line, "launchd_sim") and String.contains?(line, udid),
        do: line |> String.trim_leading() |> String.split(" ", parts: 2) |> hd()
    end)
  end

  @doc "ps's elapsed time, `[[dd-]hh:]mm:ss`, in seconds."
  def seconds(etime) do
    {days, clock} =
      case String.split(etime, "-") do
        [d, c] -> {String.to_integer(d), c}
        [c] -> {0, c}
      end

    clock
    |> String.split(":")
    |> Enum.map(&String.to_integer/1)
    |> Enum.reduce(0, &(&2 * 60 + &1))
    |> Kernel.+(days * 86_400)
  end
end
