defmodule Gate.LeaseTest do
  use ExUnit.Case, async: false

  setup do
    before = System.get_env("SHIPYARD_STATUS_ID")

    on_exit(fn ->
      if before,
        do: System.put_env("SHIPYARD_STATUS_ID", before),
        else: System.delete_env("SHIPYARD_STATUS_ID")
    end)
  end

  test "a ship worker's gate leases as ship, any other as session" do
    System.put_env("SHIPYARD_STATUS_ID", "pr-777")
    assert Gate.Lease.priority() == "ship"
    System.delete_env("SHIPYARD_STATUS_ID")
    assert Gate.Lease.priority() == "session"
  end
end
