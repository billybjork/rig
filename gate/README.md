# gate

The gate runner every project in `~/dev` shares: a project's split gate
and its ad-hoc runs, each part on its own exe.dev VM. A
project keeps what is its own in `.gate.json` at its root
(`lib/gate/config.ex` names each field): its parts (a command printing
`name<TAB>command` lines), its provision script and the files whose hash
is its stamp (or rig's one image and its pins), the setup script that
readies a checkout before each part, the build caches `git clean` keeps,
and the caches to warm before a part. Its own scripts (`check-remote.sh`,
`run-remote.sh`, `gate-times.sh`) are one-line wrappers around `bin/gate`.

```sh
gate check [tier]            # the split gate on HEAD, a fresh exe.dev VM per part
gate run <command...>        # the workbench: a command on the working tree, on its own VM
gate keys <rev>              # what a golden made at <rev> holds: the stamp, each warm key
gate golden <vm>.exe.xyz     # set a golden VM up and warm its caches (rigd's Fleet runs it)
gate times                   # rewrite the suite's partition weights
gate stamp [rev]             # HEAD's (or rev's) provision stamp
gate self-check              # this runner's gate (compile, format, tests)
```

The ship worker runs a project's gate with `RIG` set to its own clone of
rig, so a ship gates with the runner on rig's `main` as of the worker's
start; elsewhere the wrappers use `~/dev/rig`. The Elixir side runs with
this directory's toolchain (`.tool-versions`) from `bin/gate`, which
compiles it when it changed.

## How a part runs

Each part runs on a VM that rigd's `Fleet` leases (`lib/gate/lease.ex`,
on `~/Library/Caches/rigd/fleet.sock`): a fresh `cp` of the golden VM,
behind every ship's part when a session asks, removed as the part ends.
Every call to it is one plain `ssh <vm>.exe.xyz` (`lib/gate/exe.ex`)
under `libexec/deadline`, which holds it to its limit from outside, in
its own process group: TERM, then KILL. No call streams a part's output.
exe's SSH logs in as root, and a part runs as `gate` in a login shell
(`su - gate -c`), whose profile puts Python 3.13 first (`exe/base.sh`);
every VM presents exe's one host key, pinned in `exe/known_hosts` (for a
manual ssh, pass `-o UserKnownHostsFile=~/dev/rig/gate/exe/known_hosts`).

So a part, on its VM:

1. **Stage** (the tar on stdin; `exe/stage.sh`): first `exe/base.sh boot`
   as root (exe-init is PID 1, with no systemd, so a fresh copy or a
   restarted VM lacks `/dev/fd`, and process substitution fails without
   it); then it ends whatever an earlier part left, and unpacks the job,
   its vars and argv, and the git bundle that brings the VM to the commit
   (only the commits it lacks: since its last tip when this checkout has
   it, else since the newest of HEAD's first parents it holds; the whole
   history, about 300 MB for soco, only to a VM holding none). The part's
   log says `gate: uploaded <MB> in <s>`. An upload that outlasts `stage`
   is the laptop's link, not the VM: a big one tries once more with twice
   the time, then reruns as `restarted`, no strike.
2. **Launch** (`exe/launch.sh`, after the boot step): starts `exe/job.sh`
   in a session of its own, writing `~/parts/<id>/log`, prints
   `gate-launched <life>` and returns. The VM runs on with nobody
   connected.
3. **The job** (`exe/job.sh`): turns on 4 GiB of swap
   (`/var/tmp/gate-swap`), checks out the commit (keeping the build
   caches), lays `gate run`'s working tree over it, runs the commit's
   provision script when the VM's stamp is not the commit's (a toolchain
   bump refreshes a copy of the older golden until `Fleet` makes a new
   one), drops an app build that a host dying mid-compile, or a golden
   paused unsynced, left broken, runs the project's setup, builds each
   warm cache whose key changed (the dialyzer PLT, keyed by its files, the
   stamp and its command), and runs the command with core dumps on
   (`~/cores`, the newest three kept). It writes its phase (`setup`,
   `warm`, `run`) and, at the end, its status to files; a core the
   command left is named in the part's log (`sprite-gate: core <file>
   (<program>)`), with its stack where the VM has gdb.
4. **Polls** (`exe/poll.sh`, every 10 s, one call at a time): the phase,
   the status, the VM's life (boot id and PID 1's start), whether the job
   runs, and the log's new bytes, appended to the part's log here.

The laptop holds each phase to its own limit (setup 30 min, warm 45, run
25, per `.gate.json`'s `limits`), so a provision or a cold PLT never counts
against the command. A part's VM failed when the upload or launch fails,
a phase outlasts its limit (the part is ended there), the life changes (a
restart), the job ends outside `run`, or no poll gets through for 3 min.
A restart relaunches the part once on the same VM, where its caches are
warm (and a restart while warming, where the half-built cache is). Any
other failure, a second restart, or a red part whose log shows a native
crash (`Gate.Engine.crashed?/1`) gives the VM back, saying how (`failed`,
`restarted`, `crashed`; else `green` or `red`), and reruns once on the
next VM `Fleet` leases. A rerun that fails too leaves no verdict, as does
`Fleet` going mid-gate for more than 5 minutes (a `bin/rigd install`
drains it, and a waiting part connects again); with rigd down, `gate
check` exits 2. A gate stopped from outside (a closed terminal, the
worker's alarm) ends the parts it launched.

No gate takes a lock: a session's own `gate check` and a ship's run side
by side, and a ship's parts (`SHIPYARD_STATUS_ID` set) lease ahead of
every session's (2026-11-16: a session's gate held soco's worker for 19
minutes). The projects keep their own `gate-lock.sh` for the laptop's
machine lock.

## The image

`image/provision.sh` is the one image for every project: the apt union,
Postgres 17 with pgvector and pg_jsonschema, Swift, just and uv, and each
project's Erlang, Elixir and Node from its own `.tool-versions`, side by
side under `/opt/gate`. Its hash, with the project's pin files (`.gate.json`
`image`), is the project's stamp; a part whose VM holds another stamp runs
it before setup. Leave it be unless the image must change: any edit, a
comment too, changes every stamp and remakes the golden (which is why its
comments still speak of Sprites). `exe/base.sh` adds what a bare
`ubuntu:26.04` exe.dev VM lacks (sudo, curl, git, the user `gate`, Python
3.13 first on a login shell's PATH) and, as `base.sh boot`, the `/dev`
links a fresh copy needs.

## The golden

`gate golden <vm>.exe.xyz`, run in a project's checkout, readies a golden
VM: the tools, the project's setup, and each warm cache, one short step
at a time, each up to three tries; it runs no part. rigd's `Fleet` runs
it for each project on a new `rig-golden-*` VM when `gate keys
origin/main` (the stamp and each warm cache's key) no longer matches the
golden's comment, or `main` has changed many of a project's sources since
the golden, syncs its disk, pauses it, and comments it (rig's
`rigd/README.md`, "Fleet").

## The workbench

`gate run <command...>` (`lib/gate/run.ex`; the projects' `run-remote`)
runs one command on HEAD with the working tree laid over it: the diff
against HEAD and the untracked files Git does not ignore, scanned by
gitleaks first. It leases its own VM from `Fleet` as a part does (a
session's lease, behind every ship's), so runs share no Postgres, ports
or lock; the VM is readied as a gate's part (checkout, setup), the
command's output streams back (polled every 3 s), and the VM is removed
as the run ends: only the output comes back, not the files the command
writes. A VM that fails reruns the command once on another. About 13 s
pass before the command starts (lease, stage, setup).

The exit status is the command's, or 125 when it could not run (`Fleet`
down, a VM failed twice, the working tree would not lay over the commit,
a possible secret, or `$GATE_RUN_TIMEOUT` seconds, 3600); the last line
says which. The log is `<logs>/gate-run-<vm>-<run>-run.log`, and Rex
shows the run as the record `gate-run`. A run needs no warm cache of its
own: the golden's are those of `origin/main`, and a branch that changes
`mix.lock` rebuilds what it uses on the VM.

## Before exe.dev

The gate began on Fly Sprites: each project's pool, then a shared one
(rig's `history/sprite-fleet.md`), with dev Sprites for ad-hoc runs; the
move is `history/exe-move.md`. The Sprites are gone (2026-11-21), and with
them the Sprite backend, `gate pool`, the local disk and the locks. A
commit whose `.gate.json` names a Sprite pool (or `"fleet"`, the shared
one) is refused, saying to rebase; its Sprite keys (`dev`, `local`,
`locks`, `provision_gate`) are ignored. The log lines keep their
`sprite-gate:` and `sprite-health:` prefixes, which the ship worker,
digests and each project's logs read.

## The contract

`gate check` keeps the one the ship worker reads (`shipyard/README.md`, "A
project"): exit 0 green, 1 red with a digest of 30 lines or fewer on
stdout, 2 no verdict; a row per run in `<logs>/check-remote.tsv` (each
part as `name:seconds:<vm>:result`, `vm-failed` for a VM that failed
it); each part's log as `<logs>/<vm>-<run>-<part>.log`, whose last line
is `sprite-gate: exit <status>` when its command ran; Rex program status
per part as `${SHIPYARD_STATUS_ID:-gate}/<part>`.

## Testing

`bin/gate self-check`. The tests run the real host-side scripts (`exe/`)
on fake exe.dev VMs that are directories, reached by a fake `ssh` and `su`
and leased by a fake `Fleet` (`test/test_helper.exs`): a VM can refuse
ssh, stop answering, restart or upload slowly, and the parts' commands
(`test/support/cmd.sh`) crash, hang or restart their VM once.
