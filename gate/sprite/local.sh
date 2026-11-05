# On a Sprite, sourced by job.sh: a part's hot files on the local disk.
#
# The root disk (nbd0, and with it /opt/gate and the repos) is Fly's SBD, a
# cache over object storage: a 4 KB read takes 0.1 to 2 ms warm and 400 to
# 1800 ms cold, and a suite's run turns warm blocks cold, which stalls small
# tests for seconds (2026-11-05). /tmp is vdb, a real local disk. So what a
# project's `.gate.json` names under `local` is copied there and bind-mounted
# over the original: the same paths, read and written locally.
#
# The root disk stays the source of truth, and everything here is a cache
# that can go at any time, which it does:
#
#   - A restart drops the mounts and keeps vdb, so the next part mounts again.
#   - A restore rolls the root disk back and leaves vdb alone, so a project's
#     copies would outlive the restore that was meant to drop them. A token
#     decides: one on each disk, written with the copies. A golden checkpoint
#     holds none (local_off), so after a restore they differ, and the copies
#     go.
#   - A host move empties vdb (each Sprite's files there date from its last
#     move), and then the token differs too.
#   - A golden runs on the root disk, without these mounts, since a checkpoint
#     holds only that disk.
#
# Tools are immutable once installed, so their copies carry no token and
# survive a restore; only what no project's env script names any more goes.
#
# None of this may fail a part: whatever does not copy, fit or mount stays on
# the root disk, and the log says so.
#
# What fits: vdb is 20 GB, of which our swap file takes 8 and something outside
# /tmp grows to about 5.4 (`df` minus `du`, on every Sprite that has worked for
# a while), so the budget leaves room for a suite's scratch whatever that has
# grown to. The floor is for a disk fuller than that.
local_root=${GATE_LOCAL_ROOT:-/tmp/gate-local}
local_opt=${GATE_LOCAL_OPT:-/opt/gate}
local_budget=${GATE_LOCAL_BUDGET_MB:-5000}
local_floor=${GATE_LOCAL_FLOOR_MB:-1000}

# A cluster's data must not change under it: stops the one in a directory about
# to be mounted over or unmounted, and any one directory down (heaters' .local/pg).
local_stop_postgres() { # dir
  local pidfile data pgbin
  pgbin=$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)
  for pidfile in "$1/postmaster.pid" "$1"/*/postmaster.pid; do
    [ -f "$pidfile" ] || continue
    data=${pidfile%/postmaster.pid}
    [ -n "$pgbin" ] && "$pgbin/pg_ctl" -D "$data" -m fast -w -t 30 stop >/dev/null 2>&1 && continue
    kill -KILL "$(head -1 "$pidfile")" 2>/dev/null
  done
  return 0
}

local_unmount() {
  local target
  [ -f "$local_root/mounts" ] || return 0
  while IFS= read -r target; do
    mountpoint -q "$target" 2>/dev/null || continue
    local_stop_postgres "$target"
    # Lazily when busy: epmd stays alive between parts, running from a tool's copy.
    sudo -n umount "$target" 2>/dev/null || sudo -n umount -l "$target" 2>/dev/null ||
      say "local disk: could not unmount $target"
  done <"$local_root/mounts"
  rm -f "$local_root/mounts"
}

# Before a golden: its setup and its checkpoint are the root disk's.
local_off() {
  local_unmount
  rm -rf ~/.gate-local "$local_root/projects"
}

# After a provision, the only thing that changes which tools are in use.
local_prune_tools() {
  local copy
  for copy in "$local_root/tools"/*/; do
    [ -d "$copy" ] || continue
    copy=${copy%/}
    cat ~/*-env.sh 2>/dev/null | grep -qF "$local_opt/${copy##*/}" || rm -rf "$copy" "$copy.ok"
  done
}

# Copies `src` to `dest` unless it is there whole, and mounts it over `src`.
local_mount() { # src dest
  local src=$1 dest=$2 size used avail
  mountpoint -q "$src" 2>/dev/null && return 0
  local_stop_postgres "$src"
  if [ ! -f "$dest.ok" ]; then
    rm -rf "$dest"
    mkdir -p "$src" "$dest" || { say "local disk: $src stays on the root disk (no directory)"; return 0; }
    size=$(du -sm "$src" 2>/dev/null | cut -f1)
    used=$(du -sm "$local_root" 2>/dev/null | cut -f1)
    avail=$(df -m "$local_root" 2>/dev/null | tail -1 | awk '{print $4}')
    if [ $((${used:-0} + ${size:-0})) -gt "$local_budget" ] || [ $((${avail:-0} - ${size:-0})) -lt "$local_floor" ]; then
      rm -rf "$dest"
      say "local disk: $src stays on the root disk (${size} MB; ${used} MB of the ${local_budget} MB budget used, ${avail} MB free)"
      return 0
    fi
    if ! cp -a "$src/." "$dest/"; then
      rm -rf "$dest"
      say "local disk: $src stays on the root disk (the copy failed)"
      return 0
    fi
    touch "$dest.ok"
    local_copied=$((local_copied + 1))
  fi
  if sudo -n mount --bind "$dest" "$src"; then
    echo "$src" >>"$local_root/mounts"
    local_mounted=$((local_mounted + 1))
  else
    say "local disk: $src stays on the root disk (the mount failed)"
  fi
}

# LOCAL_PATHS: in the checkout, or under the home as ~/<path>. LOCAL_TOOLS: the
# names of the tools this project's PATH holds (`swift` for /opt/gate/swift-6.4.0).
# In the order given, so what matters most fits first.
local_on() {
  local path src dir dirs tool token saved
  local_copied=0 local_mounted=0
  [ $((${#LOCAL_PATHS[@]} + ${#LOCAL_TOOLS[@]})) -gt 0 ] || return 0
  sudo -n true 2>/dev/null || { say "local disk: no sudo here, so all of it stays on the root disk"; return 0; }
  mkdir -p "$local_root/tools" "$local_root/projects" ~/.gate-local ||
    { say "local disk: no room for it, so all of it stays on the root disk"; return 0; }

  saved=$local_root/projects/$NAME
  token=$(cat ~/.gate-local/"$NAME" 2>/dev/null)
  if [ -z "$token" ] || [ "$token" != "$(cat "$saved/token" 2>/dev/null)" ]; then
    # Nothing of this project's on vdb is known to follow this root disk.
    local_unmount
    rm -rf "$saved"
    mkdir -p "$saved"
    token=$(date +%s)-$RANDOM
    echo "$token" >"$saved/token" && echo "$token" >~/.gate-local/"$NAME"
  fi

  for path in ${LOCAL_PATHS[@]+"${LOCAL_PATHS[@]}"}; do
    case $path in
      "~/"*) src=$HOME/${path#"~/"} ;;
      *) src=$repo/$path ;;
    esac
    local_mount "$src" "$saved/${path//\//%}"
  done
  IFS=: read -ra dirs <<<"$PATH"
  for tool in ${LOCAL_TOOLS[@]+"${LOCAL_TOOLS[@]}"}; do
    # This project's own, of the versions side by side there.
    for dir in "${dirs[@]}"; do
      case $dir in
        "$local_opt/$tool"-*)
          dir=${dir#"$local_opt"/}
          dir=${dir%%/*}
          local_mount "$local_opt/$dir" "$local_root/tools/$dir"
          break
          ;;
      esac
    done
  done
  lap "local disk: copied $local_copied, mounted $local_mounted new, $(du -sm "$local_root" 2>/dev/null | cut -f1) MB of the $local_budget MB budget"
}
