# gate

The gate runner every project in `~/dev` shares: a project's split gate,
its ad-hoc runs and its pool of Fly Sprites. A project keeps what is its
own in `.gate.json` at its root (`lib/gate/config.ex` names each field):
its Sprites, its parts (a command printing `name<TAB>command` lines), its
provision script and the files whose hash is its stamp, the setup script
that readies a checkout before each part, the build caches `git clean`
keeps, and the caches to warm before a part. Its own scripts
(`check-remote.sh`, `gate-pool.sh`, `sprite-run.sh`, `gate-times.sh`) are
one-line wrappers around `bin/gate`.

```sh
gate check [tier]            # the split gate on HEAD, on the project's pool
gate run <command...>        # a command on the working tree, on a dev Sprite
gate pool status|provision <s>|rebuild <s>|exec <s> <cmd...>|warm [s...]
gate times                   # rewrite the suite's partition weights
gate stamp                   # HEAD's provision stamp
gate self-check              # this runner's gate (compile, format, 22 tests)
```

The ship worker runs a project's gate with `RIG` set to its own clone of
rig, so a ship gates with the runner on rig's `main` as of the worker's
start; elsewhere the wrappers use `~/dev/rig`. The Elixir side runs with
this directory's toolchain (`.tool-versions`) from `bin/gate`, which
compiles it when it changed.

## How a part runs

What the Sprites taught (`~/dev/ops/handoffs/2026-10-28-sprite-gate-open-items.md`,
and the probes of 2026-10-28):

- A long `sprite exec` stream dies with "connection closed", taking its
  part with it. So no part streams: every `sprite` call is short.
- The `sprite` CLI ignores SIGALRM, and SIGTERM for 5 s and more. So every
  call runs under `libexec/deadline`, which holds it to its limit from
  outside, in its own process group: TERM, then KILL.
- A Sprite pauses within seconds once no exec session is attached, freezing
  whatever runs there, and a non-TTY session suspends when its client goes.
  Polling does not keep it awake (the job ran only while each poll's exec
  was attached). A TTY session runs on after its client detaches and, while
  it prints, keeps the Sprite awake.

So a part, on its Sprite:

1. **Stage** (a non-TTY exec, the tar on stdin; `sprite/stage.sh`): ends
   whatever an earlier part left, and unpacks the job, its vars and argv,
   and the git bundle that brings the Sprite to the commit (only the
   commits it lacks).
2. **Launch** (a TTY exec under `script`, since the ship worker's gate has
   no terminal; `sprite/launch.sh`): starts `sprite/job.sh` in a session of
   its own, writing `~/parts/<id>/log`, then prints a keepalive until the
   job ends. The laptop drops the client once it reads `gate-launched
   <life>`.
3. **The job** (`sprite/job.sh`): checks out the commit (keeping the build
   caches), lays `gate run`'s working tree over it, runs the commit's
   provision script when the Sprite's stamp is not the commit's (a
   toolchain bump refreshes each Sprite on its first part), runs the
   project's setup, builds each warm cache whose key changed (the
   dialyzer PLT, keyed by `mix.lock`, `.tool-versions` and the stamp), and
   runs the command with core dumps on (`~/cores`, the newest three kept).
   It writes its phase (`setup`, `warm`, `run`) and, at the end, its status
   to files; a core the command left is named in the part's log
   (`sprite-gate: core <file> (<program>)`), with its stack where the
   Sprite has gdb.
4. **Polls** (`sprite/poll.sh`, every 10 s, one call at a time so parallel
   CLI calls cannot tear `~/.sprites/sprites.json`): the phase, the status,
   the Sprite's life (boot id and PID 1's start), whether the job and its
   keeper run, and the log's new bytes, appended to the part's log here.

The laptop holds each phase to its own limit (setup 30 min, warm 45, run
25, per `.gate.json`'s `limits`), so a provision or a cold PLT never counts
against the command. A part's Sprite failed when the upload or launch
fails, a phase outlasts its limit (the part is ended there), the life
changes (a restart), the job ends outside `run`, or no poll gets through
for 3 min. Such a part reruns once on the pool's last Sprite, the spare,
as does a red part whose log shows a native crash (`Gate.Engine.crashed?/1`);
a restart while warming relaunches it on the same Sprite instead, where
the half-built cache is. A keeper that dies is relaunched. A gate stopped
from outside (a closed terminal, the worker's alarm, passed on by the lock)
ends the parts it launched.

## The contract

`gate check` keeps the one the ship worker reads (`shipyard/README.md`, "A
project"): exit 0 green, 1 red with a digest of 30 lines or fewer on
stdout, 2 no verdict; a row per run in `<logs>/check-remote.tsv`; each
part's log as `<logs>/<sprite>-<run>-<part>.log`, whose last line is
`sprite-gate: exit <status>` when its command ran; Rex program status per
part as `${SHIPYARD_STATUS_ID:-gate}/<part>`.

A gate and every pool command but `status` hold the project's pool lock,
and `gate run` its dev Sprite's (`libexec/lock`, the machine gate lock's
protocol on files under the project's `locks`), so two never share a
Sprite. The projects keep their own `gate-lock.sh` for the machine lock:
their suites run it on the Sprites, where there is no rig.

## Testing

`bin/gate self-check`. The tests run the real Sprite-side scripts against
a fake `sprite` CLI (`test/test_helper.exs`) whose Sprites are
directories: TTY sessions outlive their clients, a Sprite can stop
answering or restart, and the parts' commands (`test/support/cmd.sh`)
crash, hang, restart their Sprite or drop their keeper once.
