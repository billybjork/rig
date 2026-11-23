# rigd

rig's daemon: one supervised Elixir release under the KeepAlive LaunchAgent
`com.billy.rigd` (`launchd/com.billy.rigd.plist`). Its log is
`~/Library/Logs/rigd.log`, its status `~/Library/Caches/rigd/status.json`.

```sh
bin/rigd install     # build the release, drain Fleet, install the LaunchAgent, (re)start it
bin/rigd status      # what it sees: what runs, presence, keep-awake
bin/rigd fleet       # the gate's exe.dev VMs: the golden, its keys, the leases
bin/rigd heavy       # heavy local jobs: who holds a slot, who waits, what was demoted
bin/rigd log | restart | sudoers | uninstall
```

`mix check` here is its gate (compile, format, tests; the decisions are
tested). Run `bin/rigd install` only from the primary checkout, in a
background terminal, and let it finish: it waits for Fleet's leases to
drain (20 minutes at most), and closing its terminal mid-drain kills the
install. The release carries only the applications `mix.exs` names (no
`:crypto`); `release_apps_test` holds the code to them.

## What it runs

Each module's doc says the details; in short:

- **`Activity`**, every few seconds, rebuilds what runs: agents working (the
  status each reports to Rex, read by `priv/probe.lua`), agents' background
  shells, running background terminals, ship workers.
- **`Presence`** reads lid, screen lock and idle time.
- **`Awake`** holds `caffeinate -ims` while anything runs and a minute
  after. With the sudoers rule (`sudoers`, `bin/rigd sudoers`) it also sets
  `pmset disablesleep`, so a closed lid doesn't sleep the Mac: only on AC
  or at 30% battery and up, without thermal pressure, for 4 h of lid-closed
  time at most, cleared when work ends and when rigd stops. macOS decides
  clamshell sleep only as the lid closes, so when it lets go with the lid
  closed and no external display it runs `pmset sleepnow` (Billy,
  2026-11-02: remote access drops a minute after the last agent finishes).
- **`Notify`** sends one ntfy push per agent that finishes (or waits on
  Billy) while he is away, on `NTFY_TOPIC` (`fnox.toml`, deploy tier, key
  `rig-NTFY_TOPIC`). It never pushes for a ship; the ship worker does.
- **`RexBadges`** marks a tab ⚙ while its idle agent still has a background
  shell.
- **`Closed`** records each tab and pane that closes, with its Claude
  session, in `~/.local/state/rig/closed.jsonl` (the palette's "Recently
  Closed"); **`Open`** keeps what is open in `~/.local/state/rig/open.json`
  ("Restore Sessions"), moved to `previous/` when Rex restarts, five kept,
  and restores it by itself when the restarted Rex is still as it opens.
- **`Heavy`** queues heavy local jobs (`bin/heavy cpu|net -- <command>`,
  `bg run --heavy`): 2 CPU slots and 1 for the uplink, on
  `~/Library/Caches/rigd/heavy.sock`. While the 5-minute load is at the
  cores or more it puts any job that keeps 150% CPU without a slot in the
  background (`taskpolicy -b`), and back once the load is under three
  quarters (Billy, 2026-11-16).
- **`Fleet`** leases the gate's exe.dev VMs, below.

## Fleet

Every gate part and workbench run (`gate check`, `gate run`; rig's
`gate/README.md`) runs on its own exe.dev VM, which `Fleet` leases on
`~/Library/Caches/rigd/fleet.sock` (`Rigd.Fleet.Socket` documents the
protocol). Its config is `gate/fleet.json`: the projects, the golden's
name, the VM sizes and the cap.

- **No standing pool.** A lease is a fresh copy of the golden VM (`ssh
  exe.dev cp <golden> rig-part-<time>-<hex> --standalone --cpu=4
  --memory=8GB`, about a second, its caches warm), granted as
  `<vm>.exe.xyz` once its SSH answers. A release removes it whatever the
  result, and so does a holder that goes without one, so a strike is just
  the next lease's fresh copy and a rerun lands on a new VM. At most
  `exe.max` (20) at once; the rest queue, a ship's leases ahead of every
  session's.
  A paused VM bills only its disk (exe.dev support, 2026-11-22), but a
  copy is as fast as a resume, so paused workers would buy nothing.
- **The big size.** A part needing a warm cache whose key (its files, the
  stamp and its command) the golden lacks gets 8 vCPU / 16 GB (`exe.big`):
  soco's cold dialyzer PLT was OOM-killed at 8 GB.
- **The golden** is the newest paused `rig-golden*` VM whose comment reads
  `golden <digest>`: the digest of each project's stamp and warm keys on
  `origin/main` when it was made (`gate keys origin/main`). The keys
  themselves are kept under their digest in
  `~/Library/Application Support/rigd/golden-keys/` (exe.dev caps a comment
  at 200 bytes; naming each key outgrew it at seven). Without that file the
  golden still stands, but every part needing a warm cache gets the big
  size until the next one. Every 10 minutes `Fleet` reads the keys again; when they
  differ it copies the golden to `rig-golden-<time>-<hex>` at the big size,
  runs each project's `gate golden` there, syncs its disk (a `cp` copies
  the disk, not the page cache), pauses it and writes its comment: the
  swap. The keys include `golden <format>` (`@format` in
  `Rigd.Fleet.Exe`), so a change to how a golden is made remakes it. Leases
  go on from the old golden meanwhile; a red `main` keeps it and tries
  again in 30 minutes. Never remove a `rig-golden*` VM by hand.
- **The sweep**, every 10 minutes and at start, removes part VMs nothing
  leases and golden-named VMs that are neither the golden nor the one
  being made.
- **A restart costs no gate anything.** `bin/rigd install` and `restart`
  send `drain` every few seconds, which stops leasing and refreshing for a
  minute past the last one, and restart once nothing is leased. A gate
  whose connection closes before its grant connects again for 5 minutes
  (`GATE_FLEET_RECONNECT`); with rigd down, `gate check` exits 2.

How it came to be: rig's `history/exe-move.md` (the move to exe.dev) and
`history/sprite-fleet.md` (the Sprite pool before it).
