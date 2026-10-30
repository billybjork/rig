#!/bin/bash
# On a Sprite: one part's run, `bash ~/parts/<id>/job.sh <id>`, started by
# launch.sh in a session of its own, with its output in ~/parts/<id>/log.
# ~/parts/<id>/vars names the project (NAME), the commit (SHA), the
# provision stamp it wants (STAMP), the provision command (PROVISION; with
# `@image` first, rig's image script, staged as ~/parts/<id>/image.sh), the
# project's setup script (SETUP), the build caches `git clean` keeps (KEEP),
# and the caches to warm first (WARM_NAMES, WARM_KEYS, WARM_CMDS); argv
# holds the command, NUL-separated.
#
# Its phases go to ~/parts/<id>/phase ("setup", "warm", "run", each with
# the time it began), so the laptop holds each to its own limit: the
# provision a stale stamp needs and a cold cache's build never count
# against the command's. When it ends, ~/parts/<id>/rc holds its status.
# The command's status is the part's only when the phase is "run" (the
# log's last line is then "sprite-gate: exit <status>"); anything else is
# the Sprite failing: 89 its tools would not refresh, 90 to 92 checkout and
# setup, 125 the working tree would not lay over the commit (`gate run`).
set -uo pipefail
id=${1:?usage: job.sh <id>}
d=~/parts/$id
NAME= SHA= STAMP= SETUP=
KEEP=() PROVISION=() WARM_NAMES=() WARM_KEYS=() WARM_CMDS=()
. "$d/vars"
cmd=()
while IFS= read -r -d '' arg; do cmd+=("$arg"); done <"$d/argv"

say() { echo "sprite-gate: $*"; }
t0=$(date +%s)
lap() { say "$(printf '%5ss' $(($(date +%s) - t0))) $*"; }
phase() { echo "$1 $(date +%s)" >"$d/phase.tmp" && mv "$d/phase.tmp" "$d/phase"; }
finish() { # status
  echo "$1" >"$d/rc.tmp" && mv "$d/rc.tmp" "$d/rc"
  exit "$1"
}
exec 2>&1
phase setup

# The Sprite's life (the boot id and PID 1's start time; a Sprite can
# restart its processes without a reboot), which the laptop compares with
# the current one, and the host's CPU, so crashes can be grouped by host.
if [ -r /proc/sys/kernel/random/boot_id ]; then
  say "life $(cat /proc/sys/kernel/random/boot_id)-$(cut -d' ' -f22 /proc/1/stat)"
  say "cpu $(awk -F'\t*: ' '$1 == "cpu family" {f = $2} $1 == "model" {m = $2} END {print "family " f " model " m}' /proc/cpuinfo)"
fi
# Pressure and memory every 30 s, to read a part that died or crawled by.
health() {
  [ -r /proc/pressure/io ] || return 0
  echo "sprite-health: $(date -u +%FT%TZ)"
  for resource in cpu io memory; do sed "s/^/sprite-health: $resource /" "/proc/pressure/$resource"; done
  grep -E '^(MemAvailable|SwapFree):' /proc/meminfo | sed 's/^/sprite-health: /'
  [ ! -r /sys/fs/cgroup/memory.events ] || sed 's/^/sprite-health: cgroup /' /sys/fs/cgroup/memory.events
}
(while sleep 30; do health; done) &
beat=$!
trap 'kill $beat 2>/dev/null' EXIT

# A Sprite has 16 GiB and no swap, and a cold dialyzer PLT (soco's
# static-1) took it down mid-build on every try (2026-10-30). 8 GiB of swap
# on the scratch disk, through a loop device: swapon refuses a file on the
# root's overlayfs. A restart drops it, so each part checks.
if [ -r /proc/swaps ] && [ "$(wc -l </proc/swaps)" -le 1 ] && sudo -n true 2>/dev/null; then
  swap=/tmp/gate-swap
  if [ -f "$swap" ] || sudo fallocate -l 8G "$swap"; then
    sudo chmod 600 "$swap" && loop=$(sudo losetup -f --show "$swap") && sudo chmod 660 "$loop" &&
      sudo mkswap "$loop" >/dev/null && sudo swapon "$loop" && say "swap: 8 GiB on $loop" ||
      say "swap: could not turn it on"
  fi
fi

repo=~/$NAME
[ -d "$repo/.git" ] || git init -q "$repo"
cd "$repo" || finish 90
# An empty bundle means this Sprite already has the commit.
if [ -s "$d/in.bundle" ]; then
  git fetch -q "$d/in.bundle" "+HEAD:refs/laptop/gate" || { say "bundle fetch failed"; finish 90; }
fi
git cat-file -e "$SHA^{commit}" 2>/dev/null || { say "the bundle did not bring $SHA"; finish 90; }
excludes=()
for path in ${KEEP[@]+"${KEEP[@]}"}; do excludes+=(-e "$path"); done
git checkout -q --force "$SHA" && git clean -qfdx ${excludes[@]+"${excludes[@]}"} || finish 91
lap "checked out $(git log -1 --format='%h %s')"

# `gate run`: the working tree's changes over the commit, before setup, so
# deps and Node trees follow the working tree's lockfiles.
if [ -f "$d/untracked.tar" ]; then
  if [ -s "$d/tree.patch" ]; then
    git apply --binary --whitespace=nowarn "$d/tree.patch" ||
      { say "cannot overlay: the working tree's diff did not apply"; finish 125; }
  fi
  tar -xf "$d/untracked.tar" || { say "cannot overlay: the untracked files did not unpack"; finish 125; }
  say "working tree laid over ${SHA:0:8}: $(git status --porcelain | wc -l | tr -d ' ') changed path(s)"
fi

# The tools come from the commit's own provision script and pins, so a
# toolchain bump refreshes each Sprite on its first gate instead of failing
# them all (the spare could not cover a pin change either).
have=$(cat ~/"$NAME-stamp" 2>/dev/null || echo none)
if [ "$have" != "$STAMP" ]; then
  say "provision stamp $have, want $STAMP; refreshing tools"
  # Absolute paths: a provision script may cd (to /tmp, to download).
  provision=()
  for path in "${PROVISION[@]}"; do provision+=("$repo/$path"); done
  if [ "${PROVISION[0]}" = @image ]; then
    bash "$d/image.sh" "$STAMP" "$NAME" "${provision[@]:1}" || { say "tool refresh failed"; finish 89; }
  else
    bash "${provision[0]}" "$STAMP" "${provision[@]:1}" || { say "tool refresh failed"; finish 89; }
  fi
  [ "$(cat ~/"$NAME-stamp" 2>/dev/null)" = "$STAMP" ] || { say "tool refresh did not stamp the Sprite"; finish 89; }
  lap "tools refreshed"
fi
[ ! -f ~/"$NAME-env.sh" ] || . ~/"$NAME-env.sh"
# `sprite exec` sets no SHELL, and erlexec's port program exits 4 without one.
export SHELL=${SHELL:-/bin/bash}
# Mix's build locks live in /tmp. A Sprite that restarts while Mix writes
# one leaves an empty lock file that every later Mix command fails reading;
# parts run one at a time per Sprite, so no lock here is live.
rm -rf /tmp/mix_lock_*
# A Sprite that dies while Mix compiles leaves .beam files its manifest
# calls current but that carry no debug info, and the next Dialyzer fails on
# them ("Could not get Core Erlang code"). The marker outlives only a part
# that never finished, and then the app's build (not the deps') goes. The
# marker and the warm keys are the project's (several share an image
# Sprite); a Sprite that ran one project before keeps its unnamed ones.
unfinished=~/gate-unfinished-$NAME
[ ! -e ~/gate-unfinished ] || mv ~/gate-unfinished "$unfinished"
if [ -e "$unfinished" ]; then
  say "the last part here did not finish; dropping the app's build"
  rm -rf "$repo"/_build/*/lib/"$NAME"
fi
bash "$SETUP" || { say "setup failed ($SETUP)"; finish 92; }
lap "setup"

# A cache whose key (the laptop's hash of its inputs and the stamp) is not
# the one last built here is built before the command, outside its limit:
# a cold dialyzer PLT takes about 15 min. A build that fails is tried once
# more (it resumes from what the first left) and then left to the command,
# which reports it.
if [ ${#WARM_NAMES[@]} -gt 0 ]; then
  phase warm
  mkdir -p ~/.gate-warm
  for i in "${!WARM_NAMES[@]}"; do
    name=${WARM_NAMES[i]} key=${WARM_KEYS[i]}
    keyfile=~/.gate-warm/$NAME-$name
    [ ! -e ~/.gate-warm/"$name" ] || mv ~/.gate-warm/"$name" "$keyfile"
    [ "$(cat "$keyfile" 2>/dev/null)" != "$key" ] || continue
    # A golden run's seed (gate/lib/gate/engine.ex, seed/2): whole where
    # this Sprite's may be half built, so the build then only checks it.
    if [ -f "$d/seed-$name.tar" ]; then
      tar -xf "$d/seed-$name.tar" -C ~ && say "seeded $name" || say "seeding $name failed"
    fi
    say "warming $name (key $key)"
    touch "$unfinished"
    if bash -c "${WARM_CMDS[i]}" || { say "warming $name failed; once more" && bash -c "${WARM_CMDS[i]}"; }; then
      echo "$key" >"$keyfile"
      lap "warmed $name"
    else
      lap "warming $name failed; the command will say why"
    fi
    rm -f "$unfinished"
  done
fi

phase run
touch "$unfinished"
# A native crash keeps its core, so a part's SIGSEGV can be read rather
# than guessed at: Node died at startup in about one soco static part in
# ten on the gate Sprites (2026-10), never on the dev Sprite, and each
# Sprite's restart takes its kernel log. ~/cores keeps the newest three.
cores=~/cores
if [ -e /proc/sys/kernel/core_pattern ] && mkdir -p "$cores" &&
  echo "$cores/core.%E.%p.%t" | sudo -n tee /proc/sys/kernel/core_pattern >/dev/null 2>&1; then
  ulimit -c unlimited 2>/dev/null || true
fi
touch "$d/run-began"
"${cmd[@]}"
rc=$?
kill $beat 2>/dev/null
wait $beat 2>/dev/null
health
# Each core the command left: its program (%E, the path with / as !) and,
# where gdb is, the crashing thread's stack.
for core in $(find "$cores" -maxdepth 1 -name 'core.*' -newer "$d/run-began" 2>/dev/null); do
  exe=${core##*/core.}
  exe=$(echo "${exe%.*.*}" | tr '!' /)
  say "core $core ($exe)"
  if command -v gdb >/dev/null; then
    gdb -q -batch -ex 'bt 30' -ex 'p $_siginfo._sifields._sigfault.si_addr' -ex 'x/4i $pc' "$exe" "$core" 2>&1 | grep -v '^\[New LWP' | head -50 | sed 's/^/sprite-core: /'
  fi
done
ls -t "$cores"/core.* 2>/dev/null | tail -n +4 | while IFS= read -r old; do rm -f "$old"; done
# A command killed by a signal (a Bus error as the Sprite fails) may have
# been compiling, so its marker stays.
[ "$rc" -ge 128 ] || rm -f "$unfinished"
# A suite part names its test files; the lap keeps the command before them.
command="${cmd[*]}"
lap "${command%% test/*}"
say "exit $rc"
finish "$rc"
