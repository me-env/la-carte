#!/usr/bin/env bash
# Run a command while holding an exclusive, named lock, so agents queue for a shared simulator / DerivedData
# instead of colliding or polling `pgrep`.
#
#   scripts/_lock.sh <name> <command> [args...]      (nest for several locks: _lock.sh a _lock.sh b cmd)
#
# Uses macOS /usr/bin/lockf: the kernel drops the lock when the command exits or crashes (no stale locks).
# While waiting it prints who holds the lock. Env: LACARTE_AGENT (your name, shown to waiters),
# LOCK_TIMEOUT (seconds to wait, default 3600; exits 75 when it gives up), LOCK_DIR (default /tmp/la-carte-locks).
# Already holding <name> (an outer _lock.sh on the same name)? The command just runs.
#
# Semaphore mode: scripts/_lock.sh --slots <N> <name> <command> [args...]  runs the command in one of N slots
# (locks <name>-1 .. <name>-N), polling every 2 s while all are busy. Used for the machine-wide build cap.
set -euo pipefail
if [ "${1:-}" = --slots ]; then
  [ $# -ge 4 ] || { echo "usage: $0 --slots <N> <name> <command> [args...]" >&2; exit 64; }
  N="$2"; NAME="$3"; shift 3
  DIR="${LOCK_DIR:-/tmp/la-carte-locks}"; TIMEOUT="${LOCK_TIMEOUT:-3600}"; mkdir -p "$DIR"
  case " ${LACARTE_HELD_LOCKS:-} " in *" $NAME-held "*) exec "$@" ;; esac  # an outer caller already holds a slot
  LABEL="${LACARTE_LOCK_LABEL:-$(ps -o command= -p $PPID | cut -c1-120)}"
  MARK="$(mktemp)"; trap 'rm -f "$MARK"' EXIT
  WAITING=""
  while :; do
    for k in $(seq 1 "$N"); do
      FILE="$DIR/$NAME-$k.lock"
      HOLDER="${LACARTE_AGENT:-unnamed agent} · $LABEL · pid $$ · since $(date +%H:%M:%S)"
      : >"$MARK"; set +e
      # shellcheck disable=SC2016
      LACARTE_HELD_LOCKS="${LACARTE_HELD_LOCKS:-} $NAME-held" lockf -s -k -t 0 "$FILE" \
        /bin/sh -c 'rm -f "$1"; printf "%s\n" "$2" >"$3.holder"; shift 3; exec "$@"' sh "$MARK" "$HOLDER" "$FILE" "$@"
      STATUS=$?; set -e
      [ -e "$MARK" ] || exit "$STATUS"
    done
    if [ -z "$WAITING" ]; then
      WAITING=$SECONDS
      H=""; for k in $(seq 1 "$N"); do H="$H"$'\n'"  $k: $(cat "$DIR/$NAME-$k.lock.holder" 2>/dev/null || echo '?')"; done
      echo "🔒 waiting for build slot (all $N '$NAME' slots busy, up to ${TIMEOUT}s), held by:$H" >&2
    elif [ $((SECONDS - WAITING)) -ge "$TIMEOUT" ]; then
      echo "🔒 gave up after ${TIMEOUT}s waiting for a build slot" >&2; exit 75
    fi
    sleep 2
  done
fi
[ $# -ge 2 ] || { echo "usage: $0 <lock-name> <command> [args...]" >&2; exit 64; }
NAME="$1"; shift
DIR="${LOCK_DIR:-/tmp/la-carte-locks}"
FILE="$DIR/$NAME.lock"
TIMEOUT="${LOCK_TIMEOUT:-3600}"
mkdir -p "$DIR"

case " ${LACARTE_HELD_LOCKS:-} " in *" $NAME "*) exec "$@" ;; esac
export LACARTE_HELD_LOCKS="${LACARTE_HELD_LOCKS:-} $NAME"

if ! lockf -s -k -t 0 "$FILE" true 2>/dev/null; then
  echo "🔒 waiting for '$NAME' (up to ${TIMEOUT}s), held by: $(cat "$FILE.holder" 2>/dev/null || echo '?')" >&2
fi
export LACARTE_LOCK_LABEL="${LACARTE_LOCK_LABEL:-$(ps -o command= -p $PPID | cut -c1-120)}"  # the calling script
HOLDER="${LACARTE_AGENT:-unnamed agent} · $LACARTE_LOCK_LABEL · pid $$ · since $(date +%H:%M:%S)"
set +e
# shellcheck disable=SC2016  # $1/$2 expand inside the child shell
lockf -s -k -t "$TIMEOUT" "$FILE" /bin/sh -c 'printf "%s\n" "$1" >"$2.holder"; shift 2; exec "$@"' \
  sh "$HOLDER" "$FILE" "$@"
STATUS=$?
set -e
# 75 is lockf's timeout code; a wrapped command exiting 75 itself is reported the same way (none of ours does).
if [ "$STATUS" -eq 75 ]; then
  echo "🔒 gave up after ${TIMEOUT}s waiting for '$NAME', held by: $(cat "$FILE.holder" 2>/dev/null || echo '?')" >&2
fi
exit "$STATUS"
