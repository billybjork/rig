#!/bin/bash
# On an exe.dev VM, as `gate`: `bash ~/parts/<id>/launch.sh <id>`
# (lib/gate/exe.ex). Starts the part's job.sh in a session of its own,
# writing ~/parts/<id>/log, prints "gate-launched <life>" and returns. The
# VM runs on with nobody connected, so unlike a Sprite's launch.sh nothing
# stays behind to keep it awake.
set -uo pipefail
id=${1:?usage: launch.sh <id>}
d=~/parts/$id
cd "$d" || exit 90
rm -f rc phase
# setsid, not a fork of it: a background job of a non-interactive shell
# leads no group, so setsid makes the job's pid its session and group.
setsid bash "$d/job.sh" "$id" >>"$d/log" 2>&1 </dev/null &
echo $! >"$d/job.pid"
if [ -r /proc/sys/kernel/random/boot_id ]; then
  echo "gate-launched $(cat /proc/sys/kernel/random/boot_id)-$(cut -d' ' -f22 /proc/1/stat)"
else
  echo "gate-launched $(cat ~/.life 2>/dev/null || echo none)"
fi
