defmodule Gate do
  @moduledoc """
  rig's gate runner (`gate/README.md`): `root/0`, this tree, where the
  host-side scripts (`exe/`) and `libexec/` are, `work!/1`, a run's own
  folder, and `last_line/1`, what a message quotes of a command's output.
  """

  @root Path.expand("..", __DIR__)

  def root, do: @root

  @doc """
  Makes `name`'s work folder in the tmp dir, `<name>-<random>`, which no
  other process has or can get: the name is random and the folder must not
  exist yet. A name of the second, the commit and a unique integer was not
  enough, since unique integers start over in each process: two `gate run`s
  of one second shared a folder and mixed their working trees (2026-11-24).
  """
  def work!(name) do
    random = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    path = Path.join(System.tmp_dir!(), "#{name}-#{random}")

    case File.mkdir(path) do
      :ok -> path
      {:error, why} -> raise Gate.Error, "could not make #{path}: #{:file.format_error(why)}"
    end
  end

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
