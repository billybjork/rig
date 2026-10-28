# rig

The development environment shared by every project in `~/dev`: agent rules
and skills, the Rex config, the ship worker and its Sprite fleet, keeping the
Mac awake, notifications, and secrets. A project keeps only what is its own
(its gate parts, its roll, its package list); everything that would otherwise
be copied between repositories lives here.

## Layout

- `rex/` is Rex's config; `~/.config/rex` links here (`rex config reload`
  after a change). `bg-shells.lua` marks tabs with a background shell (⚙)
  until rigd takes it over.
- `agents/AGENTS.md` is the guide every project shares, linked as
  `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`.
- `launchd/` holds copies of the LaunchAgents rig owns, as installed in
  `~/Library/LaunchAgents`.

Still to come, in this order (agreed with Billy, 2026-10-28):

1. `agents/skills/`: the shared skills (handoff, ship, task, triage,
   audit-guidance, test-audit), linked into `~/.claude/skills` and
   `~/.agents/skills`. A skill reads a project's specifics from its config
   and its own `AGENTS.md`.
2. `rigd/`: one supervised Elixir daemon (a KeepAlive LaunchAgent).
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
