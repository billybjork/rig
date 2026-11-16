import Config

# `mix run` starts the worker; the tests and the reporting tasks
# (`mix shipyard.list`, `mix shipyard.wait`) start none.
config :shipyard, worker: config_env() != :test

# The laptop's load as a gate without a verdict ends (Shipyard.Entry): the
# tests' own, not the laptop's.
if config_env() == :test, do: config(:shipyard, load: {0.0, 1})
