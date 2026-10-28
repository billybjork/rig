#!/bin/bash
# On a Sprite: `bash -c "<this file>" poll.sh <id> <offset>`
# (lib/gate/sprite.ex). Prints the part's state as header lines (phase, rc,
# life, whether its job and keeper run, the log's size), then
# "gate-poll: log" and the log's bytes from <offset> to that size.
id=${1:?usage: poll.sh <id> <offset>} offset=${2:-0}
d=~/parts/$id
[ -d "$d" ] || { echo "gate-poll: gone"; exit 0; }
up() { kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null && echo up || echo down; }
# In this order: the job's state before its status (a job writes rc and
# then exits, so one seen down has its rc there), and the log's size last,
# so a status comes with every line the job wrote before it.
job=$(up "$d/job.pid")
keeper=$(up "$d/keeper.pid")
rc=$(cat "$d/rc" 2>/dev/null)
phase=$(cut -d' ' -f1 "$d/phase" 2>/dev/null)
if [ -r /proc/sys/kernel/random/boot_id ]; then
  life="$(cat /proc/sys/kernel/random/boot_id)-$(cut -d' ' -f22 /proc/1/stat)"
else
  life=$(cat ~/.life 2>/dev/null || echo none)
fi
size=$(wc -c <"$d/log" 2>/dev/null | tr -d ' ')
size=${size:-0}
echo "phase $phase"
echo "rc $rc"
echo "life $life"
echo "job $job"
echo "keeper $keeper"
echo "size $size"
echo "gate-poll: log"
[ "$size" -le "$offset" ] || tail -c +"$((offset + 1))" "$d/log" | head -c "$((size - offset))"
