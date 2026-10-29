# rig

The development environment shared by every project in `~/dev`: agent rules
and skills, the Rex config, the ship worker and its Sprite fleet, keeping the
Mac awake, notifications, and secrets. A project keeps only what is its own
(its gate parts, its roll, its package list); everything that would otherwise
be copied between repositories lives here.

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
  shows); `rex/background.lua` adds the palette's "Background: Show" (a
  picker when there are several) and "Background: Hide This Pane". `bin/` is
  on Billy's PATH (`~/.zshrc`).
- `agents/skills/` holds the skills every project shares, each linked into
  `~/.claude/skills` and `~/.agents/skills`: `handoff` (with `bin/handoff`).
- `rigd/` is the daemon (Elixir, a KeepAlive LaunchAgent `com.billy.rigd`;
  `bin/rigd install | status | log | restart | sudoers`). Every few seconds
  `Activity` rebuilds what runs (agents working, per the status each reports
  to Rex, read by `priv/probe.lua`; agents' background shells; running
  background terminals; ship workers). `Awake` holds `caffeinate -ims` while
  anything runs and a minute after, and with the sudoers rule
  (`rigd/sudoers`) also `pmset disablesleep` so a closed lid doesn't sleep
  the Mac: only on AC or at 30% battery and up, without thermal pressure,
  for 4 h of lid-closed time at most, cleared when work ends and when rigd
  stops or starts. `Presence` reads lid, lock, and idle time; `Notify` sends
  one ntfy push per agent that finishes (or waits on Billy) while he is
  away, on `NTFY_TOPIC` from `rigd/fnox.toml` (deploy tier, key
  `rig-NTFY_TOPIC`); `RexBadges` marks a tab ⚙ while its idle agent still
  has a background shell. `Fleet` keeps the shared pool of gate Sprites
  that `gate/fleet.json` names golden and leases them to gates on a Unix
  socket (`gate/FLEET.md`). `bin/rigd status` shows what it sees; the
  decisions are tested (`mix check` in `rigd/`).
- `shipyard/` is the ship worker (Elixir; its own `README.md`), moved in
  from github.com/billybjork/shipyard (archived) with its history. Each
  project's ship command runs `~/dev/rig/shipyard/bin/shipyard`; a worker
  runs from its own clone of rig's `main`; the LaunchAgent
  `com.billy.shipyard` polls the queues (`bin/shipyard install`). A ship's
  end pushes on rig's topic (`shipyard/fnox.toml`, `rig-NTFY_TOPIC`) only
  while Billy is away, as rigd's status file says (pushing when rigd is
  not running), and rigd never pushes for a ship.
- `launchd/` holds copies of the LaunchAgents rig owns, as installed in
  `~/Library/LaunchAgents`.

Still to come, in this order (agreed with Billy, 2026-10-28):

1. Skills that are the same everywhere live here (`handoff`). Skills shaped
   by a project (`ship`, `task`, `triage`, `audit-guidance`, `test-audit`)
   stay in its repository: they wrap its notes, gate, and test conventions,
   and Claude Code on the web sees only what a repository commits. What
   their copies share (waiting on a ship in a pane, the handoff) moves here.
2. `rigd/`: one supervised Elixir daemon (a KeepAlive LaunchAgent). Done
   but `Fleet`, which comes with step 3.
   - `Activity`: the one registry of what is running (agents working, per
     Rex program status; background shells; ship workers; Sprite runs).
   - `Presence`: lid, idle time, screen lock.
   - `Awake`: keeps the Mac awake while Activity is not empty; with the lid
     closed it sets `pmset disablesleep` (a sudoers rule for exactly that)
     only above ~30% battery and below thermal pressure, with a time cap,
     and clears it on exit and at boot. Replaces Amphetamine and manual
     `caffeinate -dimsu`.
   - `Notify`: away (lid closed, locked, or idle ~5 min) sends one ntfy
     push per finished task on a single topic; present sends nothing extra.
   - `RexBadges`: the ⚙ mark, driven by Activity.
   - `Fleet`: a DynamicSupervisor with one process per Sprite and a pool
     with a warm minimum and leases.
3. The fleet: one Sprite image for every project (the union of toolchains
   via mise), the repo sent per run as a git bundle with per-project caches,
   parts run detached on the Sprite writing log and exit code to files (no
   long exec streams), restore from a golden checkpoint on failure and
   nightly, parts assigned to any idle Sprite, toolchain bumps rolled across
   the pool instead of failing gates. The gate runner moves here from
   soco's `tooling/` and heaters' `scripts/`, and shipyard moves into rig.
   In slices (agreed with Billy, 2026-10-28):
   1. shipyard moves in (done): history kept, its GitHub repository
      archived, workers run from a clone of rig, ship pushes on rig's topic.
   2. A shared detached-part runner here, on today's per-project pools:
      parts run detached on the Sprite writing log and exit files, real
      timeouts enforced from outside the `sprite` CLI, the dialyzer PLT
      built when `mix.lock` changes rather than inside a part.
   3. The one mise image and golden checkpoint, the shared pool, and rigd's
      `Fleet`.
4. Secrets: Bitwarden (free) for personal passwords and Bitwarden Secrets
   Manager (free: 3 projects, 3 machine accounts) for dev, read through
   fnox. Projects `dev`, `deploy` and `fleet`, each read by its own machine
   account (`laptop`, `shipyard`, `fleet`), so a token reaches only its
   tier. Each repo commits a `fnox.toml` of names and key references,
   never values; commands run under `fnox exec`. No `.env` copies in
   worktrees, no values in agents' context (agents may run `fnox exec`,
   never `fnox get` or `bws secret`), prod keys only in `deploy`. Render
   and Railway keep their env vars, pushed from the store on rotation.
5. Agent sessions on Sprites, then Sprites as Rex hosts.

The audit behind this (Sprite failure modes, duplication, secrets) is in the
session of 2026-10-28; the Sprite gate's open items are in
`~/dev/ops/handoffs/2026-10-28-sprite-gate-open-items.md`.

## Where we are (2026-10-29)

Done: this repository; the shared guide and `handoff` skill; Rex config moved
in; secrets (Bitwarden + fnox in soco, heaters, red-hot-xtra, billybjork.com;
every `.env` deleted, `.env.example` kept; shipyard's worker reads the deploy
tier; agents' deny rules); shells in background terminals (`bin/bg`,
shipyard's watch and workers, the palette's Show and Hide); rigd (step 2) running under
launchd with Activity, Presence, Awake, Notify, and RexBadges. Step 3's
first slice: shipyard lives in `shipyard/` with its history; soco #373 and
heaters #535 point their ship commands at it. The `~/dev/shipyard` symlink
is gone (Billy, 2026-10-29): a branch cut before #373 or #535 (soco's
`claude-node24-security`) ships only once rebased on `main`.

Step 3's slice 2, done: `gate/` (its README) is the shared runner, parts
detached on their Sprites (`gate/bin/gate self-check`); the worker exports
`RIG`, its clone of rig, and reads the queue through GraphQL. soco (#376)
and heaters (#544) gate on it, with its follow-ups live (soco #381, #384,
#385; heaters #548; rig e53a55c keeps a part's cores and prints their
stack).

Node segfaults in about one soco static part in ten on the gate Sprites,
never on soco-dev-1. The first core (soco-gate-1, 2026-10-29) is a `ret`
to a return address holding stale `/proc/meminfo` text: a write the
Sprite's memory lost, Fly's to fix; Billy will not report it (2026-10-29).
The Sprites are disposable, so a bad one is rebuilt, not investigated, and the
runner makes one cost a rerun.

Step 3's slice 3, under way (its plan: `gate/FLEET.md`):

- On main: a part whose Sprite failed or crashed reruns on the spare or,
  once that is taken, on the first Sprite whose own part ends green or red
  (`Gate.Engine`; 25 tests). One image for every project,
  `gate/image/provision.sh`: a `.gate.json` naming `image` (its pin files)
  instead of `stamp` and `provision` gets the apt union, Postgres 17 with
  pgvector and pg_jsonschema, Swift, just and uv, and its own Erlang,
  Elixir and Node from its `.tool-versions` side by side under
  `/opt/gate`. No mise: it would fetch the same builds, and adds a tool.
- The trial Sprite `rig-gate-1` holds both: soco's provision gate green
  (checkpoint v2, after one restart) and heaters' green (v3, its golden
  checkpoint). The trial branches that pointed each project at it are
  gone; their `.gate.json` was the pool `["rig-gate-1"]` and `image`
  (soco: `.tool-versions`, `tooling/runtime-versions.env`; heaters:
  `.tool-versions`) with locks under `~/.cache/rig-gate-trial`.
- soco's pool, stamp 1dfcf3bc7942735c: soco-gate-1 (rebuilt, v2), -3
  (rebuilt, v2), -4 (v17), -5 (v144) and -6 (v28) are ready. soco-gate-2
  is stamped but has no checkpoint: its provision gate lost the Sprite
  twice, and so did the rebuilt one's (a restart, then 180 s unreachable),
  so it gates but cannot be restored; its next rebuild is `Fleet`'s or a
  quiet hour's. Long provision gates are where Sprites fail: of the 15 run
  2026-10-29, 9 lost their Sprite 7 to 26 min into `mix precommit.ci`,
  so `Fleet`'s provision gate runs a project's parts in turn instead.

Billy approved the plan (2026-10-29): a shared pool of 10 Sprites,
`rig-gate-1` to `-10`, and each project's own pool destroyed once it gates
green on the shared one. Next, in the order of `gate/FLEET.md`, "Order":
each project onto the image on its own pool; rigd's `Fleet`; `Gate.Engine`
on leases; the pool built; soco, then heaters, moved; their pools
destroyed.

Then agents on Sprites (step 5).
