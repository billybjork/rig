# The shared pool and rigd's `Fleet` (step 3, slice 3)

The plan for the rest of slice 3, after the one image (`image/provision.sh`,
a project's `.gate.json` `image`) and the reruns on any finished Sprite
(`Gate.Engine`). Written 2026-10-29, from what the per-project pools
taught; nothing here runs yet.

## What exists

- **The image.** One provision script for every project: the apt union,
  Postgres 17 with pgvector and pg_jsonschema, Swift, just and uv pinned in
  rig, and each project's Erlang, Elixir and Node from its own
  `.tool-versions`, side by side under `/opt/gate`. A Sprite carries a stamp
  per project (`~/<name>-stamp`); a part whose commit pins other versions
  installs them beside the old ones, so a branch with a bump and `main`
  without one both gate on the same Sprite (the second switch takes
  seconds). It does not use mise: mise would fetch the same hex.pm and
  nodejs.org builds for Elixir and Node, and by default compiles Erlang
  from source (kerl), so it adds a tool without adding a version
  the script cannot already hold side by side.
- **Reruns.** A part whose Sprite failed, or whose command crashed, reruns
  once: on the spare while unused, then on the first Sprite whose own part
  ended green or red. A part with nowhere to go waits.
- **The trial Sprite** `rig-gate-1`, provisioned from the image and gated
  green by both projects' provision gates (`gate pool provision` from each
  project's trial branch), then checkpointed: its golden checkpoint.

## Golden checkpoints

`sprite create` takes no source, so a checkpoint cannot seed another
Sprite. "Golden" is each Sprite's own checkpoint, taken after every
project's provision gate passed on it under the current stamps. Its comment
names each project's stamp (`golden soco 13545dd5 heaters 7d1c…`), so
`Fleet` can tell a current one from a stale one.

## `Rigd.Fleet`

A part of rigd (step 2's last piece), supervised like the rest:

- `Fleet.CLI`: the one process that runs `sprite`. Every call from rigd
  goes through it, one at a time, under `deadline`, which ends the
  `sprites.json` tearing at its cause rather than repairing it after.
  Gates keep calling the CLI for their own parts' stage, launch and polls
  (each short); only lifecycle calls (create, destroy, restore, checkpoint)
  move here.
- `Fleet.Sprite` (a DynamicSupervisor child per `rig-gate-N`): its state
  (`idle`, `leased`, `restoring`, `provisioning`, `retired`), its golden
  checkpoint, its lease holder, and its strikes. It answers `lease` when
  idle and golden.
- `Fleet` (the pool): its size, the warm minimum (Sprites golden under the
  current stamps), the lease queue, and the nightly restore.

Gates reach it on a Unix socket (`~/Library/Caches/rigd/fleet.sock`, one
JSON line per message):

    → {"lease": {"project": "soco", "part": "static-1", "prefer": ["rig-gate-3"]}}
    ← {"granted": "rig-gate-3"}              (when one is idle; the call waits)
    → {"release": {"sprite": "rig-gate-3", "result": "green"}}

A lease lives as long as its connection: a gate that dies (a closed
terminal, the worker's alarm) closes it, and `Fleet` ends the part's
process groups on that Sprite before it leases it again (today's TERM trap
in `bin/gate`, moved to where it cannot be skipped). `prefer` names the
Sprites that already hold the project's tree at a recent commit, so the
git bundle stays small and the build caches warm; `Fleet` grants one of
them when it is idle and any idle Sprite otherwise.

`result`: `green` or `red` returns the Sprite idle. `failed` (the Sprite
failed the part) and `crashed` (a native crash) restore its golden
checkpoint (about 30 s) before it is idle again and count a strike; three
strikes in a day retire it, and `Fleet` builds a replacement (create,
provision, every project's provision gate, checkpoint) while the pool runs
one short. Billy's rule: Sprites are disposable, so a retired one is
destroyed, not investigated.

`Gate.Engine` changes little: where it now takes the spare or a finished
Sprite from its own list, it asks for a lease, so a crashed part reruns on
whichever Sprite in the whole pool frees first, any project's. A project's
`.gate.json` names the pool as `"pool": "fleet"`; a list keeps today's
per-project pool and its lock. With rigd down, a fleet gate exits 2 (no
verdict) saying so, and the ship worker retries as it does a pool outage.

## Stamps and rolling

A pin change in a project, or a change to the image script, makes every
golden checkpoint stale for that project. Gates keep working (each part
installs what it lacks), but a restore would go back to the old tools. So
`Fleet` re-goldens idle Sprites one at a time when `main`'s stamps change
(it reads them from each project's primary checkout, `git show
origin/main:…`): lease it to itself, run each project's provision gate,
checkpoint. The dialyzer PLT is keyed by the stamp, so this is where its
9 to 15 min rebuild happens, not in a ship's gate. Nightly, every idle
Sprite restores its golden checkpoint, which drops whatever the day left.

## Moving the projects

One at a time, each its own PR: `.gate.json` gets `"image"` (soco:
`.tool-versions`, `tooling/runtime-versions.env`; heaters: `.tool-versions`)
and drops `stamp` and `provision`, and its `provision.sh` goes; then
`"pool": "fleet"`. Once a project has gated green on the shared pool for a
few ships, its own Sprites are destroyed (Billy's call).

## Order

1. Ship the image and the reruns (this branch), then the image move of
   each project on its own pool (`image` in `.gate.json`, its own
   Sprites re-stamped once).
2. `Fleet.CLI`, `Fleet.Sprite`, `Fleet` and the socket in rigd, with the
   fake `sprite` CLI of `gate/test` for its tests.
3. `Gate.Engine` on leases; `"pool": "fleet"`.
4. The pool built to its size (Billy's call), soco moved, then heaters;
   the old pools destroyed.
