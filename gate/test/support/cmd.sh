# A part's command on a fake VM (test_helper.exs): `bash cmd.sh <behavior>`,
# run in ~/proj with HOME the VM's home. A behavior that should happen
# once, whichever VM runs it first, marks $FAKE_VMS/<behavior>.
once() { [ ! -e "$FAKE_VMS/$1" ] && touch "$FAKE_VMS/$1"; }
restart() { # what a VM restarting does to a part: a new life, its processes gone
  echo "life-$RANDOM" >~/.life
  kill -9 -- "-$(cat ~/parts/*/job.pid)"
}
case "$1" in
  green) echo "all good" ;;
  write-cache) mkdir -p cache && echo "$2" >cache/built ;;
  cat-cache) cat cache/built 2>/dev/null || echo "cache empty" ;;
  red)
    printf '  1) test the widget works (WidgetTest)\n     test/widget_test.exs:12\n     Assertion with == failed\n\n'
    echo "3 tests, 1 failure"
    exit 1 ;;
  crash-once)
    if once crashed; then echo "Segmentation fault (core dumped)"; exit 139; fi
    echo fine ;;
  core) # a crash that left a core, as job.sh's core_pattern names it
    mkdir -p ~/cores
    for n in 1 2 3; do touch -t 202601010000 ~/cores/core.old.$n.1; done
    touch ~/cores/'core.!opt!node-20.1!bin!node.42.1761700000'
    exit 1 ;;
  slow-once)
    if once slowed; then sleep 30; echo "never"; fi
    echo fine ;;
  restart-once) if once restarted; then restart; sleep 30; fi; echo fine ;;
  restarts) # the first $2 runs, on any VM
    n=$(cat "$FAKE_VMS/restarts" 2>/dev/null || echo 0)
    if [ "$n" -lt "$2" ]; then echo $((n + 1)) >"$FAKE_VMS/restarts"; restart; sleep 30; fi
    echo built ;;
  vanish-once)
    if once vanished; then touch "$FAKE_VMS/$(basename "$(dirname "$HOME")")/down"; sleep 30; fi
    echo fine ;;
  warm)
    echo "warm run" >>"$FAKE_VMS/warms"
    if once warm-restarted; then restart; sleep 30; fi
    sleep "${2:-0}"
    echo built ;;
  cat) cat "$2" ;;
  exit) exit "$2" ;;
  sleep) sleep "$2"; echo "slept" ;;
esac
