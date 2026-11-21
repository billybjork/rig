defmodule Rigd.Fleet.Supervisor do
  @moduledoc """
  The fleet's processes: `Rigd.Fleet.Exe` (when `exe` is set) and the
  socket with a process per connection. `opts`: `projects` (their primary
  checkouts), `gate` (rig's `gate/bin/gate`), `golden`
  (`Rigd.Fleet.Golden`), `socket`, `deadline` (rig's
  `gate/libexec/deadline`), `exe` (`fleet.json`'s `exe` object) and `ssh`.
  The Sprite pool it also ran was retired on 2026-11-21 (rig's `EXE.md`).
  """

  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The options from `gate/fleet.json` and the defaults."
  def options(file) do
    json = file |> File.read!() |> JSON.decode!()
    gate = Path.dirname(file)

    [
      projects: Enum.map(json["projects"], &Path.expand/1),
      gate: Path.join(gate, "bin/gate"),
      deadline: Path.join(gate, "libexec/deadline"),
      golden: Rigd.Fleet.Golden,
      socket: Path.expand("~/Library/Caches/rigd/fleet.sock"),
      exe: json["exe"],
      ssh: json["ssh"] || "/usr/bin/ssh"
    ]
  end

  @impl true
  def init(opts) do
    children =
      if(opts[:exe], do: [{Rigd.Fleet.Exe, opts}], else: []) ++
        [
          {Task.Supervisor, name: Rigd.Fleet.Conns},
          {Rigd.Fleet.Socket, opts}
        ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
