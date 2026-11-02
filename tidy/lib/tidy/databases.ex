defmodule Tidy.Databases do
  @moduledoc """
  Databases no checkout derives. Each checkout's databases take the names
  in `databases` (`.tidy.json`) with its suffix, which comes from
  evaluating the project's `workspace` file in that checkout, so the rule
  has one definition. Removing a worktree leaves its databases behind: one
  that matches a name with a suffix no existing checkout derives is
  orphaned, and `prune` drops it. One with open connections refuses the
  drop and stays. When any checkout's suffix cannot be evaluated, nothing
  is touched.
  """

  @slug "(_[a-z0-9_]+)?"
  @partition "[0-9]*"

  def run(%{databases: []}, _mode, _env), do: []

  def run(config, mode, env) do
    with {:ok, suffixes} <- suffixes(config, env),
         {:ok, rows} <- list(config) do
      orphans = orphans(rows, config.databases, suffixes)
      act(orphans, config, mode)
    else
      {:skip, why} -> [why]
      :quiet -> []
    end
  end

  @doc """
  The `{name, bytes}` rows that some template matches with some suffix but
  no template matches with a live one.
  """
  def orphans(rows, templates, suffixes) do
    any = Enum.map(templates, &regex(&1, @slug))
    live = for t <- templates, s <- suffixes, do: regex(t, Regex.escape(s))

    Enum.filter(rows, fn {name, _} ->
      Enum.any?(any, &Regex.match?(&1, name)) and not Enum.any?(live, &Regex.match?(&1, name))
    end)
  end

  defp regex(template, suffix) do
    source =
      template
      |> String.split(~r/(\{suffix\}|\{partition\})/, include_captures: true)
      |> Enum.map_join(fn
        "{suffix}" -> suffix
        "{partition}" -> @partition
        literal -> Regex.escape(literal)
      end)

    Regex.compile!("^" <> source <> "$")
  end

  defp act(orphans, config, :report) do
    for {name, bytes} <- orphans,
        do:
          "database #{name} (#{mb(bytes)}): no checkout derives it; '#{config.as} prune' drops it"
  end

  defp act(orphans, config, :prune) do
    {lines, freed} =
      Enum.map_reduce(orphans, 0, fn {name, bytes}, freed ->
        case psql(config, ["-c", ~s(DROP DATABASE "#{name}")]) do
          {_, 0} ->
            {"dropped database #{name} (#{mb(bytes)}): no checkout derives it", freed + bytes}

          _ ->
            {"database #{name} (#{mb(bytes)}): no checkout derives it, but the drop failed (open connections?); left alone",
             freed}
        end
      end)

    if length(lines) > 1 and freed > 0,
      do:
        lines ++
          [
            "dropped #{Enum.count(lines, &String.starts_with?(&1, "dropped"))} database(s), #{mb(freed)}"
          ],
      else: lines
  end

  defp mb(bytes) when bytes >= 1_073_741_824, do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"
  defp mb(bytes), do: "#{div(bytes, 1_048_576)} MB"

  # Every existing checkout's suffix, its own workspace file evaluated in it.
  defp suffixes(config, env) do
    {list, 0} = env.git.(["worktree", "list", "--porcelain"])

    list
    |> Tidy.Worktrees.parse()
    |> Enum.filter(&File.dir?(&1.path))
    |> Enum.reduce_while({:ok, []}, fn %{path: root}, {:ok, acc} ->
      case env.suffix.(config, root) do
        {:ok, s} -> {:cont, {:ok, [s | acc]}}
        {:error, why} -> {:halt, {:skip, "databases left alone: #{why}"}}
      end
    end)
  end

  @doc "A checkout's suffix: the project's workspace file, evaluated in it."
  def suffix(config, root) do
    own = Path.join(root, config.workspace)
    file = if File.regular?(own), do: own, else: Path.join(config.primary, config.workspace)

    try do
      {result, _} =
        File.cd!(root, fn -> Code.eval_string(File.read!(file), [root: root], file: file) end)

      case result do
        {suffix, _port} when is_binary(suffix) -> {:ok, suffix}
        suffix when is_binary(suffix) -> {:ok, suffix}
        other -> {:error, "#{config.workspace} returned #{inspect(other)} in #{root}"}
      end
    rescue
      e -> {:error, "#{config.workspace} failed in #{root}: #{Exception.message(e)}"}
    end
  end

  # A server that is not running has nothing to sweep; say nothing.
  defp list(config) do
    sql = "select datname, pg_database_size(datname) from pg_database where not datistemplate"

    case psql(config, ["-At", "-F", "\t", "-c", sql]) do
      {out, 0} ->
        rows =
          for line <- String.split(out, "\n", trim: true),
              [name, bytes] <- [String.split(line, "\t")],
              do: {name, String.to_integer(bytes)}

        {:ok, rows}

      _ ->
        :quiet
    end
  end

  defp psql(%{postgres: [cmd | args], primary: primary}, more) do
    Tidy.Cmd.run(cmd, args ++ ["-d", "postgres" | more], cd: primary, stderr: false, timeout: 60)
  end
end
