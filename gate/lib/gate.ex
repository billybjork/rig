defmodule Gate do
  @moduledoc """
  rig's gate runner (`gate/README.md`): `root/0`, this tree, where the
  host-side scripts (`exe/`) and `libexec/` are, and `last_line/1`, what a
  message quotes of a command's output.
  """

  @root Path.expand("..", __DIR__)

  def root, do: @root

  def last_line(text) do
    text
    |> String.split(["\n", "\r"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> Kernel.||("no output")
  end
end

defmodule Gate.Error do
  defexception [:message]
end
