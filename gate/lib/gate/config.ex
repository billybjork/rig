defmodule Gate.Config do
  @moduledoc """
  A project's `.gate.json`, at the root of its checkout: what its gate
  runs where. Everything else (the runner, the Sprite side, the lock) is
  rig's.

    * `name`: the project; its tree on a Sprite is `~/<name>`, its stamp
      `~/<name>-stamp`, its environment `~/<name>-env.sh`.
    * `pool`: the gate's Sprites; the last is the spare. Or `"fleet"`: the
      shared pool, whose Sprites are leased from rigd's `Fleet`. `dev`: the Sprites
      `gate run` uses, never in the pool.
    * `logs`: where each part's log and `check-remote.tsv` go; `locks`:
      where the pool's and each dev Sprite's lock files are.
    * `parts`: a command, run in the checkout with the tier as its last
      argument, printing one `name<TAB>command` line per part.
    * `stamp`: the files whose hash is the provision stamp, in order.
      `provision`: the provision script and its arguments, run on the
      Sprite from the checkout as `bash <script> <stamp> <args...>`.
    * `image`: instead of `stamp` and `provision`, the project's pin files
      (its `.tool-versions` first) for rig's one gate image
      (`image/provision.sh`), which every project on the shared pool uses;
      the stamp is then the hash of those files and the image script.
    * `setup`: the script that readies a checked-out tree before each part
      (databases, deps, Node trees).
    * `keep`: the paths `git clean` keeps between parts (build caches).
    * `warm`: caches built before a part, outside its limit, when their
      key changes: `name`, `parts` (globs of part names), `key` (files),
      `command`.
    * `provision_gate`: the commands a Sprite must pass before
      `gate pool provision` checkpoints it.
    * `weights`: the file `gate times` writes.
    * `limits`: seconds for each phase (`setup`, `warm`, `run`), for a
      Sprite to stay unreachable (`unreachable`), for the upload (`stage`)
      and the launch (`launch`), and between polls (`poll`).
  """

  @enforce_keys [:top, :name, :pool, :logs, :locks, :parts, :setup]
  defstruct [
    :top,
    :name,
    :pool,
    :logs,
    :locks,
    :parts,
    :stamp,
    :provision,
    :image,
    :setup,
    :weights,
    dev: [],
    keep: [],
    warm: [],
    provision_gate: [],
    limits: %{}
  ]

  @limits %{
    "setup" => 1800,
    "warm" => 2700,
    "run" => 1500,
    "unreachable" => 180,
    "stage" => 600,
    "launch" => 90,
    "poll" => 10
  }

  def load(top) do
    path = Path.join(top, ".gate.json")

    json =
      case File.read(path) do
        {:ok, text} -> JSON.decode!(text)
        {:error, _} -> raise Gate.Error, "#{path} is missing: this checkout has no Sprite gate"
      end

    from_json(top, json, path)
  end

  @doc "The `.gate.json` committed at `rev` (`gate stamp <rev>`, which rigd's `Fleet` reads)."
  def load(top, rev) do
    case System.cmd("git", ["show", "#{rev}:.gate.json"], cd: top, stderr_to_stdout: true) do
      {text, 0} -> from_json(top, JSON.decode!(text), "#{rev}:.gate.json")
      {out, _} -> raise Gate.Error, "#{rev}:.gate.json: #{String.trim(out)}"
    end
  end

  defp from_json(top, json, path) do
    %__MODULE__{
      top: top,
      name: fetch!(json, "name", path),
      pool: fetch!(json, "pool", path),
      dev: Map.get(json, "dev", []),
      logs: json |> fetch!("logs", path) |> Path.expand(),
      locks: json |> fetch!("locks", path) |> Path.expand(),
      parts: fetch!(json, "parts", path),
      image: Map.get(json, "image"),
      stamp: if(json["image"], do: json["image"], else: fetch!(json, "stamp", path)),
      provision:
        if(json["image"], do: ["@image" | json["image"]], else: fetch!(json, "provision", path)),
      setup: fetch!(json, "setup", path),
      keep: Map.get(json, "keep", []),
      warm: Map.get(json, "warm", []),
      provision_gate: Map.get(json, "provision_gate", []),
      weights: Map.get(json, "weights"),
      limits: Map.merge(@limits, Map.get(json, "limits", %{}))
    }
  end

  @doc "A limit in milliseconds."
  def limit_ms(%__MODULE__{limits: limits}, name), do: round(limits[name] * 1000)

  defp fetch!(json, key, path) do
    case Map.fetch(json, key) do
      {:ok, value} -> value
      :error -> raise Gate.Error, "#{path} has no #{inspect(key)}"
    end
  end
end

defmodule Gate.Error do
  defexception [:message]
end
