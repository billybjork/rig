defmodule Rigd.Bus do
  @moduledoc """
  How rigd's parts hear each other: Activity publishes `{:activity, state}`
  and Presence `{:presence, state}`; a part subscribes to the topics it acts on.
  """

  def subscribe(topic), do: Registry.register(__MODULE__, topic, nil)

  def publish(topic, message) do
    Registry.dispatch(__MODULE__, topic, fn subs ->
      for {pid, _} <- subs, do: send(pid, {topic, message})
    end)
  end
end
