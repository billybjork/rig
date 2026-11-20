defmodule Gate.Host do
  @moduledoc """
  Where a part runs, by its host's name: an exe.dev VM (`<vm>.exe.xyz`,
  `Gate.Exe`) or a Fly Sprite (`Gate.Sprite`). Each answers stage, launch,
  poll and end the same way; the Sprite backend stays until the last
  project leaves it (rig's EXE.md).
  """

  alias Gate.{Exe, Sprite}

  def backend(host), do: if(Exe.host?(host), do: Exe, else: Sprite)

  def exe?(host), do: Exe.host?(host)

  def holds(host, name, candidates), do: backend(host).holds(host, name, candidates)
  def stage(host, id, tar, secs), do: backend(host).stage(host, id, tar, secs)
  def launch(host, id, mode, secs), do: backend(host).launch(host, id, mode, secs)
  def poll(host, id, offset, secs), do: backend(host).poll(host, id, offset, secs)
  def kill(host, id), do: backend(host).kill(host, id)

  @doc "The host-side scripts a part's tar carries: `{source under gate/, name in the tar}`."
  def files(host) do
    launch = if exe?(host), do: "exe/launch.sh", else: "sprite/launch.sh"
    [{"sprite/job.sh", "job.sh"}, {"sprite/local.sh", "local.sh"}, {launch, "launch.sh"}]
  end
end
