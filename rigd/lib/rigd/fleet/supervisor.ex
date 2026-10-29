defmodule Rigd.Fleet.Supervisor do
  @moduledoc """
  The fleet's processes: `Rigd.Fleet.CLI`, a `Rigd.Fleet.Sprite` per
  Sprite, `Rigd.Fleet`, and the socket with a process per connection.
  `opts`: `sprites`, `projects` (their primary checkouts), `gate` (rig's
  `gate/bin/gate`), `golden` (`Rigd.Fleet.Golden`), `socket`, `cli` (the
  `sprite` CLI) and `deadline` (rig's `gate/libexec/deadline`).
  """

  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The options from `gate/fleet.json` and the defaults."
  def options(file) do
    json = file |> File.read!() |> JSON.decode!()
    gate = Path.dirname(file)

    [
      sprites: json["sprites"],
      projects: Enum.map(json["projects"], &Path.expand/1),
      gate: Path.join(gate, "bin/gate"),
      deadline: Path.join(gate, "libexec/deadline"),
      golden: Rigd.Fleet.Golden,
      socket: Path.expand("~/Library/Caches/rigd/fleet.sock"),
      cli: Path.expand(json["cli"] || "~/.local/bin/sprite")
    ]
  end

  @impl true
  def init(opts) do
    children = [
      {Rigd.Fleet.CLI, opts},
      {Registry, keys: :unique, name: Rigd.Fleet.Registry},
      {DynamicSupervisor, name: Rigd.Fleet.Sprites, strategy: :one_for_one},
      {Rigd.Fleet, opts},
      {Task.Supervisor, name: Rigd.Fleet.Conns},
      {Rigd.Fleet.Socket, opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
