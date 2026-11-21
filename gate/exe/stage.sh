#!/bin/bash
# On an exe.dev VM, as `gate`: `bash -c "<this file>" stage.sh <id>`, with a
# tar on stdin (lib/gate/exe.ex). Ends whatever an earlier part left
# running (a VM runs one part at a time: a golden's steps, or a part's
# relaunch), clears the old parts, and unpacks the tar into ~/parts/<id>:
# the part's job.sh, launch.sh, vars, argv, and its git bundle, plus the
# working tree's diff and untracked files for `gate run`. Prints
# "gate-staged" when it did.
set -uo pipefail
id=${1:?usage: stage.sh <id>}
parts=~/parts
for pidfile in "$parts"/*/job.pid; do
  [ -f "$pidfile" ] || continue
  pid=$(cat "$pidfile")
  [ -n "$pid" ] || continue
  kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
done
rm -rf "${parts:?}"/* && mkdir -p "$parts/$id" &&
  tar -xf - -C "$parts/$id" && [ -f "$parts/$id/job.sh" ] && [ -f "$parts/$id/vars" ] ||
  { echo "stage: the upload did not arrive whole" >&2; exit 90; }
echo gate-staged
