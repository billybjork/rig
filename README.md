# rig

The development environment shared by every project in `~/dev`: agent rules
and skills, the Rex config, the gate runner and the ship worker, keeping the
Mac awake, notifications, and secrets. A project keeps only what is its own
(its gate parts, its roll, its package list); everything that would otherwise
be copied between repositories lives here.

## How it fits together

- **Agents** work on the laptop in Rex, under the shared guide
  (`agents/AGENTS.md`) and skills. Their long shells run in background
  terminals (`bin/bg`); heavy local jobs take a slot (`bin/heavy`).
- **The gate** (`gate/`) runs a project's split gate, and agents' broad
  runs (the workbench, each project's `run-remote`), each part on its own
  exe.dev VM: a fresh copy of one golden VM that carries every project's
  tools, history and warm caches.
- **rigd** (`rigd/`), a LaunchAgent, leases those VMs and keeps the golden
  current (`Fleet`), and keeps the Mac awake, notices when Billy is away,
  and pushes when an agent finishes.
- **The ship worker** (`shipyard/`) takes a project's PRs labeled `ship`
  one at a time: rebase, the gate, merge, roll. Every project ships
  through it.
- **Secrets** live in Bitwarden Secrets Manager, read through fnox
  (`secrets/`); no repository or agent holds a value.

Production is each project's own (Railway, Render); GPU work is on Modal.

## Layout

- `rex/` is Rex's config; `~/.config/rex` links here (`rex config reload`
  after a change).
- `agents/AGENTS.md` is the guide every project shares, linked as
  `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`.
- `secrets/fnox.toml` is fnox's global config (`~/.config/fnox/config.toml`
  links here): the Bitwarden Secrets Manager projects and which machine
  account's Keychain token reads each. `secrets/tools/` holds the one-off
  migration from `.env` (names and counts only, never values).
  `~/.claude/settings.json` denies agents `fnox get/export/env/edit`,
  `bws secret`, Keychain token lookups, and reading `.env`; a script an
  agent runs (a `just` recipe, `bin/shipyard`) is not affected.
- `bin/bg` runs a command in a Rex background terminal (a block no tab
  shows; `--heavy cpu|net` runs it in its turn through `bin/heavy`);
  `rex/background.lua` adds the palette's "Background: Show" (a picker
  when there are several) and "Background: Hide This Pane". `bin/` is
  on Billy's PATH (`~/.zshrc`).
- "Recently Closed" (palette, Shift+Cmd+T; `rex/closed.lua`, `bin/closed`)
  reopens a tab or pane that closed lately as a new tab in its session, each
  pane at its directory and a Claude pane as `claude --resume`. rigd's
  `Closed` records them in `~/.local/state/rig/closed.jsonl`.
- "Restore Sessions" (palette; `rex/restore.lua`, `bin/restore`) brings
  back the sessions open before Rex last restarted (a reboot, a crash): each
  by name, its tabs and splits, each pane at its directory and a Claude pane
  as `claude --resume`. rigd's `Open` keeps what is open in
  `~/.local/state/rig/open.json` (a change written once it has held 20 s, so
  a shutdown's closing tabs don't count) and moves it to `previous/` when
  Rex restarts, keeping five.
- `agents/skills/` holds the skills every project shares, each linked into
  `~/.claude/skills` and `~/.agents/skills`: `handoff` (with `bin/handoff`).
- `gate/` is the gate runner (its own `README.md`; `gate/bin/gate`): a
  project's split gate and the workbench, each part on an exe.dev VM that
  rigd's `Fleet` leases. A project's `.gate.json` says what is its own.
- `rigd/` is the daemon (Elixir, the KeepAlive LaunchAgent
  `com.billy.rigd`; its own `README.md`; `bin/rigd`): `Activity` (what
  runs), `Presence`, `Awake` (keeping the Mac awake, lid closed too, while
  work runs), `Notify` (a push per finished agent while Billy is away),
  `RexBadges`, `Closed` and `Open` (for "Recently Closed" and "Restore
  Sessions"), `Heavy` (the heavy-job slots) and `Fleet` (the gate's
  exe.dev VMs).
- `shipyard/` is the ship worker (Elixir; its own `README.md`), moved in
  from github.com/billybjork/shipyard (archived) with its history. Each
  project's ship command runs `~/dev/rig/shipyard/bin/shipyard`; a worker
  runs from its own clone of rig's `main`; the LaunchAgent
  `com.billy.shipyard` polls the queues (`bin/shipyard install`). A ship's
  end pushes on rig's topic (`shipyard/fnox.toml`, `rig-NTFY_TOPIC`) only
  while Billy is away, as rigd's status file says (pushing when rigd is
  not running), and rigd never pushes for a ship.
- `tidy/` is session hygiene (its own `README.md`; `bin/tidy`): linked
  worktrees and agent branches whose work landed, databases no checkout
  derives, dev processes orphaned in removed worktrees, long-booted
  Simulators. A project's `.tidy.json` says what is its own; soco's and
  heaters' bootstraps run it (`bin/tidy self-check` is its gate).
- `launchd/` holds copies of the LaunchAgents rig owns, as installed in
  `~/Library/LaunchAgents`.
- `history/` keeps finished plans and what they taught: `plan.md` (rig's
  plan of 2026-10-28 and the dated record of how it went),
  `sprite-fleet.md` (the Fly Sprite pool, retired 2026-11-21) and
  `exe-move.md` (the move to exe.dev).

## Where we are (2026-11-21)

Steps 1 to 4 of the 2026-10-28 plan are live (`history/plan.md`): the shared
guide and skills, the Rex config, secrets in Bitwarden through fnox, rigd,
the ship worker, and the gate on exe.dev, whose workbench replaced the dev
Sprites. Fly holds nothing of rig's.

## Next

Later, and Billy's to start (`history/exe-move.md`, step 5): secrets on the
workbench through fnox's `fleet` tier (dev values only), and agent sessions
on exe.dev VMs as Rex hosts, for long delegated work.
