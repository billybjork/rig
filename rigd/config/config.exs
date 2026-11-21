import Config

config :logger, :default_formatter, format: "$date $time [$level] $message\n"

# The tests start none of the daemon's processes.
config :rigd, start: config_env() != :test

# rigd's own secrets (NTFY_TOPIC), named for fnox; read from the deploy tier.
config :rigd, fnox_config: Path.expand("../fnox.toml", __DIR__)

# The gate's exe.dev VMs (rigd/README.md, "Fleet"): the projects the golden
# serves, its name, the VM sizes and the cap.
config :rigd, fleet_config: Path.expand("../../gate/fleet.json", __DIR__)
