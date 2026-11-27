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
# Stall guard (slots only): if the command's whole process tree uses < STALL_CPU s of CPU (default 5) for STALL_MIN
# minutes (default 10; 0 = off), it is killed, the slot is freed and the script exits 124 ("Hung builds" in
# docs/dev-velocity.md). A live build burns minutes of CPU; a hung one (e.g. clang-stat-cache waiting on fseventsd) ~0.
# Off on CI (no hung fseventsd there): it only counts the command's own tree, not the simulator's test processes, so
# a test suite that prints nothing for 10 min (ScreenColorTests, ≈14 min on CI) looked hung (run 45811826958).
set -euo pipefail
if [ -n "${CI:-}" ]; then STALL_MIN="${STALL_MIN:-0}"; fi

source "$(dirname "$0")/_proc.sh"  # bounded ps/pgrep, stall_guard, fseventsd_hung (never a full-table ps)
if [ "${1:-}" = --slots ]; then
  [ $# -ge 4 ] || { echo "usage: $0 --slots <N> <name> <command> [args...]" >&2; exit 64; }
  N="$2"; NAME="$3"; shift 3
  DIR="${LOCK_DIR:-/tmp/la-carte-locks}"; TIMEOUT="${LOCK_TIMEOUT:-3600}"; mkdir -p "$DIR"
  case " ${LACARTE_HELD_LOCKS:-} " in *" $NAME-held "*) exec "$@" ;; esac  # an outer caller already holds a slot
  LABEL="${LACARTE_LOCK_LABEL:-$({ bounded 5 ps -o command= -p $PPID || true; } | cut -c1-120)}"
  # fseventsd hung (state U): Xcode stalls at 0% CPU unless xcodebuild runs through the shim (_fsevents-shim.sh).
  if [ "${LA_CARTE_FSEVENTS_SHIM:-}" != 0 ] && fseventsd_hung; then
    case "${FSEVENTS_SHIM_DIR:-}" in
      "") echo "⚠️  fseventsd is hung (state U): this build will likely stall. See 'Hung builds' in docs/dev-velocity.md" >&2 ;;
      *) echo "⚠️  fseventsd is hung (state U): xcodebuild runs through the no-FSEvents shim. See 'Hung builds' in docs/dev-velocity.md" >&2 ;;
    esac
  fi
  MARK="$(mktemp)"; trap 'rm -f "$MARK"' EXIT
  WAITING=""
  while :; do
    for k in $(seq 1 "$N"); do
      FILE="$DIR/$NAME-$k.lock"
      HOLDER="${LACARTE_AGENT:-unnamed agent} · $LABEL · pid $$ · since $(date +%H:%M:%S)"
      : >"$MARK"; STATUS=0
      # guarded (_proc.sh): stall guard (exit 124), and leftovers of a killed build can't hold our output open.
      # shellcheck disable=SC2016
      guarded "${STALL_MIN:-10}" "${STALL_CPU:-5}" env LACARTE_HELD_LOCKS="${LACARTE_HELD_LOCKS:-} $NAME-held" \
        lockf -s -k -t 0 "$FILE" /bin/sh -c 'rm -f "$1"; printf "%s\n" "$2" >"$3.holder"; shift 3; exec "$@"' \
        sh "$MARK" "$HOLDER" "$FILE" "$@" || STATUS=$?
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
export LACARTE_LOCK_LABEL="${LACARTE_LOCK_LABEL:-$({ bounded 5 ps -o command= -p $PPID || true; } | cut -c1-120)}"  # the calling script
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
