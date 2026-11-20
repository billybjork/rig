# exe.dev: the gate pool and the workbench

The plan to move rig's remote compute from Fly Sprites to exe.dev, and to
use it beyond the gate. Written 2026-11-20 after a day's trial; Billy agreed
to the direction the same day ("this may be enough evidence to just move
forward"). Supersedes the Sprite parts of `gate/FLEET.md` as each step lands.

## Why

What the Sprites cost us is mostly their platform: a Sprite pauses ~20 s
after its last exec session (hence the keeper and TTY launch), its root disk
is a cache over object storage (400 to 1800 ms cold reads, hence
`local.sh`), long parts lose the Sprite about half the time, a checkpoint
cannot seed another Sprite (hence a golden per Sprite and pool rebuilds that
take hours), and an account holds 10. Fly's forum reports the same
(unresponsive Sprites, checkpoint trouble, a storage rewrite under way).

Measured on exe.dev (2026-11-20, trial VMs `rig-trial-1`, `rig-trial-2`;
memory `exe-dev-trial`):

| | exe.dev | Sprites |
|---|---|---|
| create | 1.5 s | minutes |
| `cp` (whole disk, a new VM) | 0.5 s, no cold reads after | none |
| pause / resume (RAM kept) | 2.8 s / 1.1 s | n/a |
| 4 KB read, data never touched | 0.1 ms (local NVMe) | 400 to 1800 ms |
| a job with nobody connected | runs (75+ min, no gap) | freezes in ~20 s |
| provision the image | 65 s | ~4 min |
| heaters static | 178 s on 2 vCPU | 212 to 288 s on 8 |
| heaters test-1 | 1696 s on 2 vCPU | ~744 s on 8 |

A core there does about twice a Sprite core's work. Not yet known: restarts
over days (the soak below), and part times at 4 and 8 vCPU.

## Billy's answers (2026-11-20)

- Fly's Sprite bill runs about $95 a month (Nov 1 to 19: $63; CPU $42, RAM
  $17, storage $4).
- Activate Personal ($15/mo) to finish the checks; its shared capacity does
  not matter, since gate VMs are standalone VMs metered by the second on
  top of it.
- No GitHub coupling, no keys on the VMs: see "Code and credentials".
- Secrets on VMs and agent sessions on VMs: open to either, not urgent.
- 2 to about 12 agent sessions at once, about 3 on average.

## Principles

- **The laptop is where Billy works**: agents, Rex, the editor, and what
  must be on the Mac (heaters' desk and downloads, the Simulator and Chrome
  checks, heaters-studio's MPS work, beancount by policy, rigd and the ship
  worker). Heavy CPU work goes to exe.dev; GPU and ML stay on Modal;
  production stays on Railway and Render.
- **One image, one golden VM.** Every other VM is a `cp` of the golden, so a
  fresh VM is warm in seconds and a broken one is replaced, not repaired
  (the Sprite rule, now cheap).
- **No credentials on a VM.** The golden holds every project's full
  history, so a copy needs only the commits it lacks, sent from the laptop
  as today's bundle (usually well under 1 MB).
- **Reruns stay host-agnostic.** exe.dev has incidents too (17 in a year on
  its status page, among them VM disks Sep 5 to 9 and a 12-minute global
  outage); a bad VM costs a rerun, never a ship.

## Costs

Standalone VMs: $0.105 per 2 vCPU / 4 GiB hour, by the second, nothing for
CPU and memory while stopped. The gates used about 400 to 600 part-hours a
month in November (`check-remote.tsv`), fewer once parts run faster: about
$100 a month at 4 vCPU or $200 at 8, plus $15, plus disk beyond the 100 GB
allowance. Whether a paused VM counts as stopped is check 0a.

## Order

Each step lands on its own and is live before the next.

### 0. Paid checks (Personal activated)

a. A standalone VM paused for an hour: billed or not (`billing usage`
   before and after; else ask support@exe.dev).
b. Disk: the largest disk a VM may have on Personal (the trial's cap is 25
   GB; the image plus both repos used ~15), and whether ten copies of the
   golden count ten times against the allowance.
c. Ten VMs resumed at once: time, and any rate limit on `ssh exe.dev`.
d. soco's and heaters' parts at 4 and at 8 vCPU against the pool's logs;
   pick the size.
e. The soak on `rig-trial-2` (below): any change of boot id in
   `~/trial/results.tsv`, any gap in `rig-trial-1:~/tick`.

Then the numbers go to Billy for go or no-go.

### 1. The image on exe.dev

`gate/image/provision.sh` runs on `ubuntu:26.04` (`new --image`), as a user
`gate` with passwordless sudo (Postgres will not run as root; exe's SSH logs
every user in as the image's default user, so `su - gate` or a runner-side
`sudo -u gate`). What Fly's base image supplied and ours must now carry:
Python 3.13 first on PATH (heaters' `uv run` scripts failed on 3.14's
missing pydantic-core wheels), and whatever else in `/.sprite/bin` a part
uses (rust, go, bun: check each project's suite). A bare image lacks
`/dev/fd` and `/dev/std*`, so a boot step links them (process substitution
fails otherwise). Then a golden VM `rig-golden`: the image, each project's
setup and warm caches, full histories.

### 2. A host backend in `gate/`

The runner talks to a host through stage, launch, poll and end. On exe.dev
each is a plain `ssh`: stage takes the tar on stdin; launch is `setsid
nohup job.sh` with no keeper or TTY; poll reads the same files; life is
still the boot id. `local.sh` is off there (the disk is local). The Sprite
backend stays until the last project leaves it.

### 3. `Fleet` on exe.dev

The pool is `rig-gate-1..N`, standalone copies of `rig-golden`, N about 12
(two or three ships at once, five parts each). Idle is paused; a lease
resumes, a release pauses. A strike or a stale golden replaces the VM (`rm`,
`cp`), which takes the place of restoring a checkpoint. A golden refresh
(a stamp change) provisions `rig-golden` once and recopies the idle VMs.
heaters moves first, then soco, each by its `.gate.json`; the Sprite pool is
destroyed after a few green ships on the new one (Billy's call).

### 4. The workbench

One command for agents (`gate run`, pointed at exe.dev, or `rig run`):
copy the golden (or resume a pooled workbench VM), bring it to the working
tree as `gate run` does now, run the command with its log streamed back,
then pause or remove it. Each run has its own VM, so no shared Postgres or
ports. It replaces `soco-dev-1` and `heaters-dev-1`, and becomes the default
for broad test runs, dialyzer and CPU media work (soco `docs/agent-ops.md`,
heaters `docs/workflow.md`, rig's `AGENTS.md`), leaving Heavy slots for what
must run locally. The demotions in `rigd.log` are mostly soco agents'
unslotted `mix test` and compiles, and heaters' and heaters-studio's media
scripts.

### 5. Later (not urgent, Billy)

- Secrets on the workbench through fnox's `fleet` tier, dev values only.
- Agent sessions on VMs as Rex hosts (`rex server install ssh://…`), for
  long delegated work (rig README step 5).

## The trial's leftovers

`rig-trial-2` soaks heaters test-2 and soco test-1 in turn
(`~/trial/loop.sh`; stop with `rm ~/trial/loop.on`); `rig-trial-1` writes a
tick a second. Delete both (`ssh exe.dev rm`) once step 0 is done.
