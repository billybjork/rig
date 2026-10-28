defmodule Gate.Digest do
  @moduledoc "What a red part says, in a few lines (`priv/digest.awk`), or its log's tail when nothing matched."

  @awk Path.expand("../../priv/digest.awk", __DIR__)

  def lines(log, max) do
    text = File.read!(log)
    suite = if text =~ ~r/^  [0-9]+\) /m, do: "1", else: "0"
    {out, _} = System.cmd("awk", ["-v", "suite=#{suite}", "-f", @awk, log])

    picked =
      case out |> String.split("\n", trim: true) |> Enum.uniq() do
        [] ->
          text
          |> String.split("\n", trim: true)
          |> Enum.reject(&(&1 =~ ~r/^(sprite-(gate|health)|gate):/))
          |> Enum.take(-max)

        lines ->
          lines
      end

    Enum.take(picked, max)
  end
end
