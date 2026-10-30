# The shared pool and rigd's `Fleet` (step 3, slice 3)

The plan for the rest of slice 3, after the one image (`image/provision.sh`,
a project's `.gate.json` `image`) and the reruns on any finished Sprite
(`Gate.Engine`). Written 2026-10-29, from what the per-project pools
taught; approved by Billy the same day with a pool of 10 Sprites
(`rig-gate-1` to `-10`) and each project's own pool destroyed once it gates
green on the shared one.

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
  ended green or red. A part with nowhere to go waits. A part whose Sprite
  restarted is first relaunched on that Sprite, where its caches are warm
  (Billy, 2026-10-30): a restart is a platform event, no likelier there
  than anywhere.
- **The trial Sprite** `rig-gate-1`, provisioned from the image and gated
  green by both projects' provision gates (`gate pool provision` from each
  project's trial branch), then checkpointed: its golden checkpoint.

## Golden checkpoints

`sprite create` takes no source, so a checkpoint cannot seed another
Sprite. "Golden" is each Sprite's own checkpoint, taken after every
project's setup ran on it under the current stamps.

A golden only sets up (`gate golden`, `Gate.Golden`; Billy, 2026-10-30,
after Amp's Orbs): the image and each project's pins, its setup script
(deps), then each warm cache (soco's dialyzer PLT, from the laptop's seed
when the key changed), one short step at a time. It runs no gate part and
does not need `main` green: ship gates are the verification. A step whose
Sprite restarted runs again on the same Sprite, where the disk kept what
the last try built, up to three times. Until then a golden ran every part
of the tier `check` in turn: on 2026-10-29 and 30 that made 16 golden
checkpoints in about 137 provisioning attempts, the long serial run losing
its Sprite to restarts, and a red `main` keeping new Sprites out of the
pool. Its comment names each project's stamp (`golden soco 13545dd5
heaters 7d1c…`), so `Fleet` can tell a current one from a stale one.

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
them when it is idle, else one that served the project since its last
restore, else any idle Sprite.

`result`: `green` or `red` returns the Sprite idle. `restarted` (its
Sprite restarted or went unreachable) and `failed` (the Sprite failed the
part otherwise) end what the part left running and return it idle with
its build caches; neither is a strike, but a `failed` right after a
`failed` is (Billy, 2026-10-30: restarts are platform events, and a
restore threw away the caches the next part needed). `crashed` (a native
crash) is a strike and restores its golden checkpoint (about 30 s) before
it is idle again; three
strikes in a day retire it, and `Fleet` builds a replacement (create,
provision, every project's setup, checkpoint) while the pool runs
one short. Billy's rule: Sprites are disposable, so a retired one is
destroyed, not investigated. So is one whose calls (check, restore,
ending a part's leftovers) have all failed for 15 minutes while `sprite
list` still answers (Billy, 2026-10-30); with `list` failing too, the
laptop is offline, and it waits.

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
origin/main:…`): lease it to itself, run each project's setup,
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

Each step lands on its own, live before the next.

1. **Each project onto the image, on its own pool.** A PR per project,
   through its `ship` skill: `.gate.json` gets `image` (soco:
   `.tool-versions`, `tooling/runtime-versions.env`; heaters:
   `.tool-versions`) and drops `stamp` and `provision`; its
   `provision.sh` goes, and whatever names it (its `AGENTS.md` or docs,
   `gate run`'s dev Sprite) follows. The PR's own gate re-stamps its pool
   (each Sprite installs under `/opt/gate`, about 4 min fresh, and
   rebuilds the PLT, 9 to 15 min, outside the run limit). Until it merges,
   a Sprite that alternates between `main` and the PR refreshes on each
   switch (seconds) and rebuilds the PLT each time, so ship it rather than
   leave it open. Then `gate pool provision` each Sprite to checkpoint it
   under the new stamp (one retry, then a rebuild, per Sprite).
2. **`Fleet` in rigd**, tested against the fake `sprite` CLI of
   `gate/test/test_helper.exs` (copy it into rigd's tests or move it to a
   shared place under `gate/`): `Fleet.CLI`, `Fleet.Sprite`, `Fleet`, the
   socket. The provision gate it runs is the project's gate parts in turn
   (`gate check`'s parts command for the tier `check`), each relaunched
   once after a restart, then `sprite checkpoint create` with the golden
   comment. Pool membership is config in rig (`rigd/config` or a
   `gate/fleet.json`), not in any project.
3. **`Gate.Engine` on leases**, `"pool": "fleet"` in `.gate.json`: the
   initial assignment and every rerun ask `Fleet`; `gate check` no longer
   needs n+1 Sprites, only a free one per part as they come.
   `check-remote.tsv` and the digest keep their format (the worker reads
   them). Keep the list form working until both projects have moved.
4. **The pool**: `rig-gate-2` to `-10` created and made golden by `Fleet`
   one at a time (each holds the Sprite CLI only for its lifecycle calls).
   `rig-gate-1`'s checkpoint v3 predates the comment format; re-golden it.
5. **soco moves** (`"pool": "fleet"`), then **heaters**; each project's own
   Sprites are destroyed after three green ships in a row on the shared
   pool (soco-gate-1 to -6, heaters-gate-1 to -5; the dev Sprites stay).
