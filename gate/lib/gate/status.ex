defmodule Gate.Status do
  @moduledoc """
  Rex's program status (OSC 7501: a state, an id, a one-line message, and
  a title) on the terminal device `$SHIPYARD_STATUS_TTY` (the ship
  worker's tab, whose gate has no controlling terminal), else the
  controlling terminal. Without one (a harness, launchd) it does nothing,
  and it never writes to stdout or stderr, which callers parse and log.
  """

  def report(state, id, message, title \\ nil) do
    fields =
      ["state=#{state}", "id=#{id}", "app=gate"] ++
        if(title, do: ["title=#{encode(title, 120)}"], else: []) ++
        ["msg=#{encode(message, 400)}"]

    tty = System.get_env("SHIPYARD_STATUS_TTY", "/dev/tty")

    try do
      File.write(tty, "\e]7501;#{Enum.join(fields, ":")}\e\\")
    rescue
      _ -> :ok
    end

    :ok
  end

  defp encode(text, max) do
    text
    |> String.replace(~r/[\x00-\x1f]/, "")
    |> String.slice(0, max)
    |> Base.encode64()
  end
end
