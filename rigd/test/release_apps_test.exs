defmodule Rigd.ReleaseAppsTest do
  use ExUnit.Case, async: true

  # The release carries only rigd's applications and theirs; a call into
  # any other (`:crypto` killed Fleet.Exe on its first lease, 2026-11-20)
  # works under mix and fails live.
  test "rigd calls no module outside the applications its release carries" do
    carried = [:erts | closure([:rigd])]

    outside =
      for mod <- Application.spec(:rigd, :modules),
          {:ok, {_, [imports: imports]}} = :beam_lib.chunks(:code.which(mod), [:imports]),
          {callee, _, _} <- imports,
          app = app(callee),
          app not in carried,
          uniq: true,
          do: {mod, callee, app}

    assert outside == []
  end

  defp app(mod) do
    case {:application.get_application(mod), :code.which(mod)} do
      {{:ok, app}, _} -> app
      # erlang, prim_* and the like: erts, in every release.
      {:undefined, :preloaded} -> :erts
      {:undefined, _} -> mod
    end
  end

  defp closure(apps, seen \\ MapSet.new())
  defp closure([], seen), do: MapSet.to_list(seen)

  defp closure([app | rest], seen) do
    if app in seen do
      closure(rest, seen)
    else
      Application.load(app)

      deps =
        (Application.spec(app, :applications) || []) ++
          (Application.spec(app, :included_applications) || [])

      closure(deps ++ rest, MapSet.put(seen, app))
    end
  end
end
