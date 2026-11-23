defmodule Rigd.Fleet.Golden do
  @moduledoc """
  What makes an exe.dev golden VM (`Rigd.Fleet.Exe`), run through rig's
  `gate`: each project's keys on `origin/main` (`gate keys origin/main` in
  its primary checkout, after a fetch), and its setup on the VM (`gate
  golden <vm>.exe.xyz`: tools, deps and warm caches, no gate part) from a
  detached worktree of `origin/main` that is removed after. The primary
  checkout's branch and tree are never touched. Each run's output goes to
  `~/Library/Logs/rigd-fleet/`. A golden's comment names the keys it holds
  by their digest (`comment/1`, `held/1`).
  """

  @doc """
  A golden's comment: `golden <digest>` (`digest/1`). exe.dev refuses a
  comment past 200 bytes, and naming each key outgrew that at seven
  (2026-11-22: two refreshes failed and heaters' new warm cache never reached
  a golden), so the keys themselves are kept on the laptop (`remember/2`).
  """
  def comment(keys), do: "golden " <> digest(keys)

  @doc "16 hex digits naming a set of keys; the same keys give the same digest."
  def digest(keys) do
    text = Enum.map_join(Enum.sort(keys), "\n", fn {k, v} -> "#{k} #{v}" end)
    # :erlang.md5 is in erts: the release carries no :crypto (release_apps_test).
    text |> :erlang.md5() |> binary_part(0, 8) |> Base.encode16(case: :lower)
  end

  @doc """
  What a golden comment says it holds, `%{digest, keys}`, or nil for any
  other text. `keys` is nil when the comment names only the digest: they are
  looked up with `recall/2`. A comment of the old kind (`golden <name> <hex>
  ...`) names the keys themselves.
  """
  def held(line) do
    cond do
      m = Regex.run(~r/^golden ([0-9a-f]{16})$/, line) ->
        %{digest: Enum.at(m, 1), keys: nil}

      m = Regex.run(~r/golden((?: [\w.-]+ [0-9a-f]{16})+)/, line) ->
        keys =
          m
          |> Enum.at(1)
          |> String.split()
          |> Enum.chunk_every(2)
          |> Map.new(fn [k, v] -> {k, v} end)

        %{digest: digest(keys), keys: keys}

      true ->
        nil
    end
  end

  @doc "Keeps `keys` in `dir` under their digest, for `recall/2`."
  def remember(dir, keys) do
    File.mkdir_p!(dir)
    text = Enum.map_join(Enum.sort(keys), "", fn {k, v} -> "#{k} #{v}\n" end)
    File.write!(Path.join(dir, digest(keys)), text)
  end

  @doc """
  The keys `remember/2` kept under `digest`, or nil. Without them (a new
  laptop) the golden is still known by its digest; every part that needs a
  warm cache gets the big size until the next golden.
  """
  def recall(dir, digest) do
    with {:ok, text} <- File.read(Path.join(dir, digest)),
         keys = parse_keys(text),
         true <- digest(keys) == digest,
         do: keys,
         else: (_ -> nil)
  end

  @doc """
  What a golden VM made from the project's `origin/main` holds (`gate keys
  origin/main`): `{:ok, %{"<name>" => stamp, "<name>-<warm>" => key}}`.
  """
  def keys(gate, dir) do
    with :ok <- fetch(dir),
         {out, 0} <- cmd(gate, ["keys", "origin/main"], dir, 120) do
      {:ok, parse_keys(out)}
    else
      {:error, why} -> {:error, why}
      {out, status} -> {:error, "gate keys exited #{status}: #{last_line(out)}"}
    end
  end

  @doc "The `<name> <16 hex>` lines of `gate keys`' output (`bin/gate` compiles to stderr first)."
  def parse_keys(out) do
    for line <- String.split(out, "\n"),
        [_, k, v] <- [Regex.run(~r/^([\w.-]+) ([0-9a-f]{16})$/, String.trim(line))],
        into: %{},
        do: {k, v}
  end

  @doc """
  The project's setup on the VM `vm` (a `<vm>.exe.xyz` host): `{:green, name,
  keys}`, `{:red, why}` (`gate golden` exited 1: not the VM's doing),
  `{:vm_failed, why}`, or `{:laptop, why}` when git failed here (no
  network, DNS): not the VM's doing either.
  """
  def run(gate, dir, vm) do
    tmp =
      Path.join(System.tmp_dir!(), "rigd-golden-#{vm}-#{System.unique_integer([:positive])}")

    with :ok <- fetch(dir),
         {:ok, json} <- git(dir, ["show", "origin/main:.gate.json"]),
         :ok <- prune(dir, vm),
         {:ok, _} <- git(dir, ["worktree", "add", "-q", "--detach", tmp, "origin/main"]) do
      name = JSON.decode!(json)["name"]
      log = log_path(vm, name)
      {out, status} = cmd(gate, ["golden", vm], tmp, 4 * 3600)
      File.write!(log, out)
      {keys, _} = cmd(gate, ["keys", "HEAD"], tmp, 120)
      git(dir, ["worktree", "remove", "--force", tmp])

      case status do
        0 -> {:green, name, parse_keys(keys)}
        1 -> {:red, "#{name}'s golden setup exited 1 (#{log})"}
        _ -> {:vm_failed, "#{name}'s golden setup: exit #{status} (#{log})"}
      end
    else
      {:error, why} -> {:laptop, why}
    end
  end

  # The worktrees an earlier run on `vm` left when rigd was killed
  # under it: none runs now, since a golden is made one project at a time.
  @doc false
  def prune(dir, vm) do
    with {:ok, list} <- git(dir, ["worktree", "list", "--porcelain"]) do
      for "worktree " <> path <- String.split(list, "\n"),
          String.starts_with?(Path.basename(path), "rigd-golden-#{vm}-"),
          do: git(dir, ["worktree", "remove", "--force", path])

      with {:ok, _} <- git(dir, ["worktree", "prune"]), do: :ok
    end
  end

  defp fetch(dir) do
    case git(dir, ["fetch", "-q", "origin", "main"]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # One git command at a time in a checkout: runs together would otherwise
  # race on its refs and worktree list.
  defp git(dir, args) do
    run = fn -> System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) end

    case :global.trans({{__MODULE__, dir}, self()}, run, [node()], :infinity) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, "git #{hd(args)} in #{dir} exited #{status}: #{last_line(out)}"}
    end
  end

  # `gate` under a deadline, in `dir`, stdout and stderr together, without
  # the release's boot variables or its erts on PATH: a child `erl` that
  # finds either boots rigd's release instead of its own.
  @doc false
  def cmd(gate, args, dir, secs) do
    deadline = Path.join(Path.dirname(Path.dirname(gate)), "libexec/deadline")
    root = to_string(:code.root_dir())

    path =
      System.get_env("PATH", "")
      |> String.split(":")
      |> Enum.reject(&String.starts_with?(&1, root))
      |> Enum.join(":")

    env =
      for {k, _} <- System.get_env(),
          k in ~w(BINDIR ROOTDIR EMU PROGNAME) or String.starts_with?(k, "RELEASE_"),
          do: {k, nil}

    System.cmd(deadline, [to_string(secs), gate | args],
      cd: dir,
      env: [{"PATH", path} | env],
      stderr_to_stdout: true
    )
  end

  defp log_path(vm, name) do
    dir = Path.expand("~/Library/Logs/rigd-fleet")
    File.mkdir_p!(dir)
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    Path.join(dir, "#{vm}-#{name}-#{stamp}.log")
  end

  @doc "The last non-blank line of a command's output, for a one-line reason."
  def last_line(text) do
    text
    |> String.split(["\n", "\r"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> Kernel.||("no output")
  end
end
