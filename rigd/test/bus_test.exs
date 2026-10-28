defmodule Rigd.BusTest do
  use ExUnit.Case, async: true

  test "a subscriber hears {topic, message} on its topics only" do
    Rigd.Bus.subscribe(:presence)
    Rigd.Bus.publish(:presence, %{away: true})
    Rigd.Bus.publish(:awake, %{holding: true})
    assert_received {:presence, %{away: true}}
    refute_received {:awake, _}
  end
end
