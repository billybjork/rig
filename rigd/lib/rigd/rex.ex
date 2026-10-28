defmodule Rigd.Rex do
  @moduledoc """
  rigd's view of Rex. `snapshot/0` runs `priv/probe.lua` once (a fresh
  connection each time, so a server restart or a sleep costs one tick, not
  a stuck daemon) and returns its sessions as maps with string keys.
  """

  def snapshot do
    probe = Path.join(:code.priv_dir(:rigd), "probe.lua")

    case Rigd.Cmd.run("rex", ["--autostart=false", "do", probe], timeout: 20) do
      {out, 0} ->
        line = out |> String.split("\n", trim: true) |> Enum.find(&String.starts_with?(&1, "{"))

        case line && JSON.decode(line) do
          {:ok, %{"sessions" => sessions}} -> {:ok, Enum.map(list(sessions), &session/1)}
          _ -> {:error, "probe printed no snapshot: #{String.slice(out, 0, 300)}"}
        end

      {out, status} ->
        {:error, "probe exited #{status}: #{String.slice(out, 0, 300)}"}
    end
  end

  def set_window_label(session_id, window_id, label) do
    args = JSON.encode!(%{window_id: window_id, label: label})

    Rigd.Cmd.out("rex", [
      "--autostart=false",
      "api",
      "call",
      "-s",
      session_id,
      "session.set_window_label",
      args
    ])
  end

  # Lua encodes an empty table as {}; every collection here is a list.
  defp list(x) when is_list(x), do: x
  defp list(_), do: []

  defp session(s) do
    windows = for w <- list(s["windows"]), do: Map.put(w, "blocks", list(w["blocks"]))
    %{s | "windows" => windows} |> Map.put("detached", list(s["detached"]))
  end
end
