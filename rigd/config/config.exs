import Config

config :logger, :default_formatter, format: "$date $time [$level] $message\n"

# The tests start none of the daemon's processes.
config :rigd, start: config_env() != :test

# rigd's own secrets (NTFY_TOPIC), named for fnox; read from the deploy tier.
config :rigd, fnox_config: Path.expand("../fnox.toml", __DIR__)

# The shared pool of gate Sprites (rig's gate/FLEET.md): its Sprites and the
# projects whose provision gates make one golden.
config :rigd, fleet_config: Path.expand("../../gate/fleet.json", __DIR__)
