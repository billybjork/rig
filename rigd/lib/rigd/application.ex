defmodule Rigd.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    daemon =
      if Application.get_env(:rigd, :start),
        do: [Rigd.Presence, Rigd.Awake, Rigd.Notify, Rigd.RexBadges, Rigd.Status, Rigd.Activity],
        else: []

    children = [{Registry, keys: :duplicate, name: Rigd.Bus} | daemon]
    Supervisor.start_link(children, strategy: :one_for_one, name: Rigd.Supervisor)
  end
end
