#!/usr/bin/env bash
# Bound a command's run time (macOS has no `timeout`):
#
#   scripts/_timeout.sh <seconds> <command> [args...]      e.g. scripts/_timeout.sh 1800 scripts/ios-ui-test.sh run
#
# The command runs in its own process group; after <seconds> the whole group (xcodebuild included) gets TERM,
# then KILL 10 s later, and this exits 124. Otherwise it exits with the command's code. Locks the command held
# are dropped by the kernel when it dies.
set -uo pipefail
[ $# -ge 2 ] || { echo "usage: $0 <seconds> <command> [args...]" >&2; exit 64; }
SECS="$1"; shift
FIRED="$(mktemp)"; rm -f "$FIRED"
set -m   # background jobs get their own process group, so one kill reaches all of the command's children
"$@" &
PID=$!
( sleep "$SECS"; : >"$FIRED"; echo "⏱️  timed out after ${SECS}s: $*" >&2
  kill -TERM -- -"$PID" 2>/dev/null; sleep 10; kill -KILL -- -"$PID" 2>/dev/null ) &
WATCH=$!
set +m   # no job-status chatter
trap 'kill -TERM -- -"$PID" 2>/dev/null' INT TERM
wait "$PID"; STATUS=$?
kill -- -"$WATCH" 2>/dev/null
if [ -e "$FIRED" ]; then rm -f "$FIRED"; exit 124; fi
exit "$STATUS"
