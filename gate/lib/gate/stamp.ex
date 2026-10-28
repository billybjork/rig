defmodule Gate.Stamp do
  @moduledoc """
  Hashes of files at a commit: the provision stamp a Sprite must carry
  (the project's `stamp` files, in order: its toolchain pins and its
  provision script), and each warm cache's key (its `key` files and the
  stamp, so a toolchain bump rebuilds it too).
  """

  def stamp(config, sha), do: hash(config, sha, config.stamp, "")

  def warm_key(config, sha, stamp, warm), do: hash(config, sha, warm["key"], stamp)

  defp hash(config, sha, files, extra) do
    contents =
      for file <- files do
        case System.cmd("git", ["show", "#{sha}:#{file}"], cd: config.top, stderr_to_stdout: true) do
          {text, 0} ->
            text

          {out, _} ->
            raise Gate.Error, "#{file} at #{String.slice(sha, 0, 8)}: #{String.trim(out)}"
        end
      end

    :crypto.hash(:sha256, [contents, extra]) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end
end
