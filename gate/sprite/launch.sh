#!/bin/bash
# On a Sprite, in a TTY exec session: `bash ~/parts/<id>/launch.sh <id>
# [keep]` (lib/gate/sprite.ex). Starts the part's job.sh in a session of its
# own, writing ~/parts/<id>/log, then keeps this TTY session busy until the
# job ends. A Sprite pauses within seconds once no session is attached, and
# a non-TTY session suspends when its client goes, freezing what it started;
# a TTY session runs on after the client detaches and, while it prints,
# keeps the Sprite awake. So the laptop reads "gate-launched <life>" and
# drops the client, and the part runs on with no exec stream to lose.
# `keep` starts only this keeper, for a job whose keeper died.
set -uo pipefail
id=${1:?usage: launch.sh <id> [keep]}
d=~/parts/$id
life() {
  if [ -r /proc/sys/kernel/random/boot_id ]; then
    echo "$(cat /proc/sys/kernel/random/boot_id)-$(cut -d' ' -f22 /proc/1/stat)"
  else
    cat ~/.life 2>/dev/null || echo none
  fi
}
cd "$d" || exit 90
if [ "${2:-}" != keep ]; then
  rm -f rc phase
  # setsid, not a fork of it: a background job of a non-interactive shell
  # leads no group, so setsid makes the job's pid its session and group.
  setsid bash "$d/job.sh" "$id" >>"$d/log" 2>&1 </dev/null &
  echo $! >"$d/job.pid"
fi
echo $$ >"$d/keeper.pid"
echo "gate-launched $(life)"
while kill -0 "$(cat "$d/job.pid")" 2>/dev/null; do
  echo .
  sleep 4
done
echo gate-ended
