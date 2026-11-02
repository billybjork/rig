defmodule Tidy.SimulatorsTest do
  use ExUnit.Case, async: true

  alias Tidy.Simulators

  test "ps elapsed times" do
    assert Simulators.seconds("05:09") == 309
    assert Simulators.seconds("02:00:01") == 7201
    assert Simulators.seconds("3-01:00:00") == 3 * 86_400 + 3600
  end

  @udid "0F5E6A2B-1C3D-4E5F-8A9B-0C1D2E3F4A5B"

  test "a Simulator booted over two hours is reported, a newer one is not" do
    json =
      JSON.encode!(%{
        "devices" => %{
          "iOS-27-0" => [
            %{"state" => "Booted", "name" => "iPhone 17", "udid" => @udid},
            %{"state" => "Booted", "name" => "iPad", "udid" => "NEW"}
          ]
        }
      })

    ps = """
     1-02:03:04 /Library/Developer/launchd_sim /Users/b/Devices/#{@udid}/data/var/run/launchd_bootstrap.plist
          10:00 /Library/Developer/launchd_sim /Users/b/Devices/NEW/data/x
    """

    sims = Simulators.booted(json, ps)
    assert [{"iPhone 17", @udid, 93_784, "1-02:03:04"}, {"iPad", "NEW", 600, "10:00"}] = sims

    assert [line] = Simulators.run(nil, :prune, %{simulators: fn -> sims end})

    assert line =~
             "iOS Simulator 'iPhone 17' booted for 1-02:03:04; `xcrun simctl shutdown #{@udid}`"
  end
end
