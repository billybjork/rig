defmodule Rigd.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    daemon =
      if Application.get_env(:rigd, :start),
        do: [Rigd.Presence, Rigd.Awake, Rigd.Notify, Rigd.RexBadges, Rigd.Status, Rigd.Activity],
        else: []

    # Temporary: a fleet that keeps failing stops on its own and leaves the
    # rest of rigd running.
    fleet =
      if Application.get_env(:rigd, :start),
        do: [
          Supervisor.child_spec(
            {Rigd.Fleet.Supervisor,
             Rigd.Fleet.Supervisor.options(Application.get_env(:rigd, :fleet_config))},
            restart: :temporary
          )
        ],
        else: []

    children = [{Registry, keys: :duplicate, name: Rigd.Bus} | daemon ++ fleet]
    Supervisor.start_link(children, strategy: :one_for_one, name: Rigd.Supervisor)
  end
end
