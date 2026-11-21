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
CPU and memory while stopped. Nov 1 to 20 ran 389 heaters gates (194
part-hours) and 709 soco gates (187): about 580 and 1060 a month. At 4
vCPU a heaters gate holds VMs about 0.45 h and a soco gate 0.2 h, so about
480 VM-hours, **about $100 a month, plus $15** (at 8 vCPU about $170);
disk stays inside the 100 GB with no idle VMs. Sprites: about $95.

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

Measured 2026-11-20 (Personal active):

a. **Not answerable from the CLI.** `billing usage` and `billing invoices`
   show no metered compute at all (the upcoming invoice read $15 after
   ~3 standalone VM-hours), and there is no `stop`: `pause` ("free its
   CPU and memory") is the only stopped state, and the docs say a stopped
   standalone VM is not billed for CPU and memory. The pool below keeps no
   idle VMs, so it does not depend on the answer; the workbench's pooled
   VMs would (ask support, or read December's invoice).
b. A VM's disk goes to 1024 GB (`resize --disk`; above that support
   reviews it). Every copy counts in full: 15 VMs of ~15 GB read 229 GB.
   Over the 100 GB allowance, disk is $0.08/GiB-month, averaged over the
   cycle; bandwidth over 200 GB is $0.05/GiB.
c. Ten standalone copies of `rig-trial-2` made at once in 2.3 s, paused
   together in 2.9 s, resumed together and answering SSH in 3.3 s, each
   with its boot id unchanged. 30 parallel `ssh exe.dev ls` took 0.7 s with
   no refusals.
d. One part per VM, each part's run alone (setup 1 to 6 s, staging not
   counted), the pool's file lists, warm caches. Pool: Nov 20's green gates
   (`check-remote.tsv`, which includes staging and setup).

   | part | Sprite (8) | exe 2 vCPU | exe 4 / 8 GB | exe 8 / 16 GB |
   |---|---|---|---|---|
   | heaters static | 208 to 288 | 212 | 164 | 150 |
   | heaters test-1 | 627 to 818 | | 467 | 507 |
   | heaters test-2 | 366 to 797 | 549 to 556 | 422 | 380 |
   | heaters test-3 | 338 to 533 | | 475 | 356 |
   | soco static-1 | 195 to 245 | 244 | 162 | 144 |
   | soco static-2 | 143 to 291 | 195 | 115 | 95 |
   | soco static-3 | 80 to 131 | 82 | 47 | 39 |
   | soco test-1 | 131 to 224 | 204 to 213 | 149 | 118 |
   | soco test-2 | 159 to 365 | 203 | 146 | 111 |

   A gate's wall is its longest part: heaters about 8 min at 4 vCPU (8 at
   8) against 11 to 14 on the pool, soco under 3 against 3.5 to 6.5. The
   suites do not scale past 4 vCPU (a sync half and max_cases 8), so **4
   vCPU / 8 GB is the size**. One exception: soco's cold dialyzer PLT
   build was OOM-killed at 8 GB (beam at 7.7 GB RSS with 4 GB of swap; it
   passed at 2 and at 8 vCPU). The golden carries warm PLTs, so this bites
   only a ship that changes `mix.lock` or `.tool-versions`: a `warm` part
   whose key misses runs on 8 vCPU / 16 GB.
   Reds seen, none exe's: soco `DevGateTest` "inner-loop commands run
   beside a held gate" once (cold, 8 vCPU, a 10 s timeout); the trial's
   first command files lacked the file lists, so each test part ran the
   whole suite (1782 tests green in each).
e. No restart: `rig-trial-2` kept one life (`500af940`) through 3.5 h of
   parts, and `rig-trial-1`'s tick has no gap over 2 s in 3.7 h. The soak
   continues (`~/trial/loop.sh`).

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

Done 2026-11-20 (Billy's go the same day): `gate/exe/base.sh` carries what
the bare image lacks (sudo, curl, git; user `gate`; Python 3.13 from uv
under `/opt/gate/python`, first on a login shell's PATH through
`/etc/profile.d/gate.sh`, so parts run in a login shell: `su - gate -c`).
`provision.sh` is unchanged, since its hash is the Sprite pool's stamp.
The trial's parts all ran green with nothing from `/.sprite/bin` but
Python. exe-init is PID 1 (no systemd, and `--setup-script` runs only at
first boot), so `bash base.sh boot` (the `/dev` links) is the backend's to
run on each fresh copy before it stages. `rig-golden` is a standalone
8 vCPU / 16 GB VM with a 60 GB disk (16 GB for the cold PLT): base 16 s,
both projects' toolchains 82 s, and each repo's full `origin/main` history
from a bundle (soco 320 MB, heaters 10 MB) at `~gate/<name>`. Its setup and
warm caches wait for step 2: `gate golden` runs them through the exe
backend unchanged.

### 2. A host backend in `gate/`

The runner talks to a host through stage, launch, poll and end. On exe.dev
each is a plain `ssh`: stage takes the tar on stdin; launch is `setsid
nohup job.sh` with no keeper or TTY; poll reads the same files; life is
still the boot id. `local.sh` is off there (the disk is local). The Sprite
backend stays until the last project leaves it.

Done 2026-11-20: `gate/lib/gate/exe.ex`, chosen by `gate/lib/gate/host.ex`
for any host named `<vm>.exe.xyz` (gate/README.md, "On exe.dev"). The
stage and launch run `base.sh boot` as root first, then everything runs
as `gate` through `su - gate -c`; `exe/launch.sh` starts the job and
returns (no keeper, no TTY); the job's swap is a plain 4 GiB file
(`/var/tmp/gate-swap`, `HOST=exe` in the part's vars) and the local disk
is off. Every VM presents exe's one RSA host key, so it is pinned for
`*.exe.xyz` in `gate/exe/known_hosts`, and a copy made a second ago is
known with `StrictHostKeyChecking=yes`. A gate stopped from outside ends
its exe parts over `ssh` (`bin/gate`). `gate golden rig-golden.exe.xyz`
set the golden up and warmed it: heaters setup 12 s and PLT 280 s (stamp
`773ce604…`, `ae718087`), soco setup 23 s and PLT 454 s from the laptop's
seed (stamp `486ccc69…`, `1a90154b`). A copy of it at 4 vCPU / 8 GB
(`cp rig-golden rig-part-test --standalone --cpu=4 --memory=8GB`, 1 s)
ran soco test-1 green in 141 s through the engine, the fresh copy's
missing `/dev/fd` linked by the stage.

### 3. `Fleet` on exe.dev

There is no standing pool (check 0: a copy costs about 1.5 s and is warm,
and an idle VM would cost disk and maybe compute). A lease is `cp
rig-golden --standalone --cpu=4 --memory=8GB` and a release is `rm`; up to
about 15 at once (two or three ships, five parts each). A strike is just
the next lease's fresh copy, which takes the place of restoring a
checkpoint. A golden refresh (a stamp change) provisions a new golden
once (on 8 vCPU / 16 GB, which the cold PLT needs) and swaps it in.
heaters moves first, then soco, each by its `.gate.json`; the Sprite pool is
destroyed after a few green ships on the new one (Billy's call).

Built 2026-11-20 (`rigd/lib/rigd/fleet/exe.ex`, `gate/FLEET.md` "On
exe.dev"): `Rigd.Fleet.Exe` beside the Sprite pool, on the same socket,
when `gate/fleet.json` has `exe`. A `.gate.json` with `"pool": "exe"`
leases `rig-part-<time>-<hex>` copies, granted once SSH answers, removed
on release or when the holder goes; 8 / 16 when a part's warm key is not
the golden's. The golden is the newest paused `rig-golden*` VM with a
`golden <name> <hex> ...` comment (each project's stamp and warm keys,
`gate keys origin/main`); a change makes a new one at 8 / 16 and swaps it
in, and a sweep removes what nothing holds. The first refresh, from the
seed `rig-golden`, took 7 min (soco's PLT rebuilt in 356 s) and made
`rig-golden-1120-235625-94ffec`; a heaters gate through a trial `Fleet`
on it was green in 534 s (static 172, test-1 524, test-2 423, test-3
398), its four VMs removed after.
Live 2026-11-20 (rig 3a663fa: the first live lease crashed on
`:crypto`, which rigd's release lacks, and took the whole Fleet down for
25 min; a test now holds rigd to its release's applications). heaters
gates on it since #871 (green in 559 s on four copies). soco since #895
(2026-11-21, green in 669 s: static-1 656 with its PLT built cold on the
big size, the others 80 to 179). Its trial gate before that had static-1
red after 747 s: soco's dialyzer runs in `MIX_ENV=dev` but its warm
command built the PLT in test, so every copy rebuilt it for `_build/dev`
(4.5 min after a dev compile) and dialyzer then failed on 8 GB; a Sprite
had paid that once and kept it. #895 warms in dev (on a copy of the
golden, dialyzer then passed in 2m17s), and rig 0a08630 puts a warm's
command in its key, so the golden refreshed for it. On the refreshed
golden soco's `main` gated green in 232 s (static-1 213, static-2 155,
test-1 145, test-2 141, static-3 60; the Sprite pool's last soco gates
took 246 to 280).

Open: soco's `DevGateTest` "inner-loop commands run beside a held gate"
(an async test; a spawned child BEAM must reach the gate's admission
within 10 s while the suite holds every core) went red on test-2 in 3 of
soco's first 7 gates on exe (7cc5f69, and `main` d73cdff6 and 1ef7d6ac
on 2026-11-21), against once on the Sprites since Nov 4; the child's
output lands just after the bound. Making it synchronous passed test-2
twice but is barred by soco's `AsyncTestDisciplineTest` ratchet ("make
the new files async-safe instead of raising the ratchet"). Left to
Billy: raise the bound (a blocked command never enters, so any finite
bound still catches one) or give soco's test parts 8 vCPU.

Step 3 done 2026-11-21 (Billy's go): the Sprite pool is retired.
`rig-gate-1` to `-10` are destroyed, `gate/fleet.json` names no Sprites,
and rigd's Sprite side of `Fleet` (`Rigd.Fleet`, `Fleet.Sprite`,
`Fleet.CLI`, the nightly restore) is removed; `Fleet` is now
`Rigd.Fleet.Exe` and the socket. A `"pool": "fleet"` gate (a branch cut
before its project moved) is refused by `gate check` and by `Fleet`,
saying to rebase. What stays for step 4: the Sprite backend
(`gate/lib/gate/sprite.ex`, `sprite/*.sh`, `local.sh`) and `gate pool`,
which `gate run` uses on the dev Sprites `soco-dev-1` and
`heaters-dev-1`, and the `sprite` login; the workbench replaces them,
and then they go.

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

Built 2026-11-21 (Billy chose the name: `run-remote` in each project,
over `gate run`): `gate run` on a project with `"pool": "exe"` leases its
own VM from `Fleet` as a session's part does, lays the working tree over
HEAD (gitleaks first), streams the output (polled every 3 s), and the
release removes the VM; a VM that fails reruns it once on another. No
pooled VMs, so nothing hangs on the paused-VM billing question (0a).
Live: heaters `mix test` of one file in 13 s wall, soco's in 39 s (31 of
them compiling the commit's changes). `gate/README.md`, "The workbench".
`exe.max` went from 15 to 20 (Billy) since runs share the cap with
gates, ships first.

Found on the way (rig 4119749): the golden of 2026-11-21 02:38 had been
paused straight after `gate golden`, and a `cp` copies the disk, not the
page cache, so 17 of heaters' test beams were empty on every copy and
each heaters test part red since (check-fast at 04:45 and 04:53).
`Fleet` now syncs before the pause, and a golden's keys include `golden
<format>` so the unsynced one was remade. A remade golden is a copy of
the old one, so it kept the empty files; mix does not rebuild a module
whose .beam alone is missing, so a part now drops the build of any app
holding an empty .beam before setup (`sprite/job.sh`; heaters' test
build recompiles in about 100 s), and format 3 remade the golden on
that.

### 5. Later (not urgent, Billy)

- Secrets on the workbench through fnox's `fleet` tier, dev values only.
- Agent sessions on VMs as Rex hosts (`rex server install ssh://…`), for
  long delegated work (rig README step 5).

## The trial's leftovers

`rig-trial-2` soaks heaters test-2 and soco test-1 in turn
(`~/trial/loop.sh`; stop with `rm ~/trial/loop.on`); `rig-trial-1` writes a
tick a second. Delete both (`ssh exe.dev rm`) on Billy's go (the soak runs
until then); the check copies are deleted.
