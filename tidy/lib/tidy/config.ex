defmodule Tidy.Config do
  @moduledoc """
  A project's `.tidy.json`, at the root of its checkout: what in the
  machine's leftovers is the project's, and its rules. The mechanics (which
  worktree may go, which database no checkout derives, which process is
  orphaned) are rig's.

    * `landed`: when a linked worktree's or branch's work is on `main`, so
      it may go. `"origin/main"` (the default): its HEAD is an ancestor of
      `origin/main`, for a project that ships by pushing `main`.
      `"merged-pr"`: a merged pull request's head is its HEAD (`gh`).
    * `branches`: a regex naming the agent branches (`"^[a-z]+/"`). Given,
      the `branches` section deletes local ones no worktree carries once
      landed, and reports remote ones no worktree here carries.
    * `workspace`: the file (`config/workspace.exs`) that, evaluated in a
      checkout's directory (and with `root:` bound to it), returns
      `{suffix, port_offset}`: the one definition of a checkout's suffix.
    * `postgres`: the command, run in the primary checkout, that runs
      `psql` against the project's server with the arguments it is given
      (`["psql", "-h", "localhost"]`, `["scripts/pg.sh", "psql"]`).
    * `databases`: the names a checkout's databases take, with
      `{suffix}` for the workspace suffix and `{partition}` for
      `MIX_TEST_PARTITION` (`"soco_test{partition}{suffix}"`). A database
      matching one, with a suffix no checkout derives, is orphaned.
    * `dev_commands`: a regex of a dev command (`"^npm run (watch|dev)"`)
      that, reparented to launchd, has lost its server.
    * `processes`: the commands that, running in a removed worktree, are
      orphaned (default: node, npm, beam.smp, esbuild*, tailwindcss).
  """

  defstruct [
    :primary,
    :here,
    :branches,
    :workspace,
    :postgres,
    :dev_commands,
    landed: :ancestor,
    databases: [],
    processes: ~w(node npm beam.smp esbuild* tailwindcss),
    as: "tidy"
  ]

  @fields ~w(landed branches workspace postgres databases dev_commands processes)

  @doc "The config of the repository `dir` is in (any of its checkouts)."
  def load(dir) do
    with {:ok, primary, here} <- checkouts(dir),
         {:ok, json} <- read(Path.join(here, ".tidy.json"), Path.join(primary, ".tidy.json")) do
      from_map(json, primary, here)
    end
  end

  def from_map(json, primary, here) do
    case Map.keys(json) -- @fields do
      [] -> build(json, primary, here)
      extra -> {:error, ".tidy.json: unknown field(s) #{Enum.join(extra, ", ")}"}
    end
  end

  defp build(json, primary, here) do
    landed =
      case json["landed"] do
        nil ->
          {:ok, :ancestor}

        "origin/main" ->
          {:ok, :ancestor}

        "merged-pr" ->
          {:ok, :merged_pr}

        other ->
          {:error,
           ".tidy.json: landed is \"origin/main\" or \"merged-pr\", not #{inspect(other)}"}
      end

    with {:ok, landed} <- landed,
         {:ok, branches} <- regex(json["branches"], "branches"),
         {:ok, dev_commands} <- regex(json["dev_commands"], "dev_commands"),
         :ok <- databases_need(json) do
      {:ok,
       %__MODULE__{
         primary: primary,
         here: here,
         landed: landed,
         branches: branches,
         dev_commands: dev_commands,
         workspace: json["workspace"],
         postgres: json["postgres"],
         databases: json["databases"] || [],
         processes: json["processes"] || %__MODULE__{}.processes,
         as: System.get_env("TIDY_AS") || "tidy"
       }}
    end
  end

  defp databases_need(%{"databases" => [_ | _]} = json) do
    cond do
      not is_binary(json["workspace"]) -> {:error, ".tidy.json: databases need workspace"}
      not match?([_ | _], json["postgres"]) -> {:error, ".tidy.json: databases need postgres"}
      true -> :ok
    end
  end

  defp databases_need(_), do: :ok

  defp regex(nil, _), do: {:ok, nil}

  defp regex(source, field) do
    case Regex.compile(source) do
      {:ok, re} -> {:ok, re}
      {:error, _} -> {:error, ".tidy.json: #{field} is not a regex: #{inspect(source)}"}
    end
  end

  # The checkout's own file, or the primary's when it predates the file.
  defp read(own, primary) do
    path = if File.regular?(own), do: own, else: primary

    with {:ok, text} <- File.read(path),
         {:ok, json} <- JSON.decode(text) do
      {:ok, json}
    else
      {:error, :enoent} -> {:error, "no .tidy.json in this repository"}
      {:error, reason} -> {:error, "#{path}: #{inspect(reason)}"}
    end
  end

  # The primary checkout (the first `git worktree list` entry) and the one
  # `dir` is in.
  defp checkouts(dir) do
    with {here, 0} <-
           System.cmd("git", ["rev-parse", "--show-toplevel"], cd: dir, stderr_to_stdout: true),
         {list, 0} <- System.cmd("git", ["worktree", "list", "--porcelain"], cd: dir) do
      [primary | _] = Tidy.Worktrees.parse(list)
      {:ok, primary.path, String.trim(here)}
    else
      _ -> {:error, "not in a git checkout"}
    end
  end
end
