#!/bin/sh
# Runs bg-shells.lua and restarts it (by exiting; launchd relaunches) when its
# heartbeat stops updating.
hb="$HOME/Library/Caches/rex-bg-shells.heartbeat"
touch "$hb"
"/Users/billy/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex" do "$HOME/.config/rex/bg-shells.lua" & pid=$!
trap 'kill $pid 2>/dev/null' EXIT
while sleep 15; do
  kill -0 $pid 2>/dev/null || exit 1
  age=$(( $(date +%s) - $(stat -f %m "$hb") ))
  if [ $age -gt 60 ]; then
    echo "$(date +%T) no tick for ${age}s, restarting"
    exit 1
  fi
done
