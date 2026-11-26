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
set -euo pipefail

# Total CPU time (centiseconds) of process $1 and all its descendants.
tree_cpu() {
  ps -axo pid=,ppid=,time= | awk -v root="$1" '
    { t = $3; d = 0; if (index(t, "-")) { split(t, a, "-"); d = a[1]; t = a[2] }
      n = split(t, f, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + f[i]
      parent[$1] = $2; cs[$1] = int((s + d * 86400) * 100) }
    END { for (p in parent) { q = p; while (q != "" && q != root && q != 1 && q != 0) q = parent[q]
            if (q == root) sum += cs[p] }
          print sum + 0 }'
}

# Background watchdog: kill $1's tree once it stalls; touch $2 so the caller can report it.
stall_guard() {
  local pid="$1" flag="$2" window=$(( ${STALL_MIN:-10} * 60 )) min_cs=$(( ${STALL_CPU:-5} * 100 ))
  [ "$window" -gt 0 ] || return 0
  local base since now cpu tree
  base=$(tree_cpu "$pid"); since=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    sleep 15 </dev/null >/dev/null 2>&1
    cpu=$(tree_cpu "$pid")
    if [ $((cpu - base)) -ge "$min_cs" ]; then base=$cpu; since=$SECONDS
    elif [ $((SECONDS - since)) -ge "$window" ]; then
      tree=$(ps -axo pid=,ppid= | awk -v root="$pid" '{ parent[$1] = $2 }
        END { for (p in parent) { q = p; while (q != "" && q != root && q != 1 && q != 0) q = parent[q]; if (q == root) print p } }')
      echo "🔒 no progress for ${STALL_MIN:-10} min (process tree used <${STALL_CPU:-5}s CPU): killing it and freeing the slot." \
        "Likely a hung clang-stat-cache / fseventsd: see 'Hung builds' in docs/dev-velocity.md" >&2
      : >"$flag"
      # shellcheck disable=SC2086
      kill $tree "$pid" 2>/dev/null; sleep 5; kill -9 $tree "$pid" 2>/dev/null
      return 0
    fi
  done
}
if [ "${1:-}" = --slots ]; then
  [ $# -ge 4 ] || { echo "usage: $0 --slots <N> <name> <command> [args...]" >&2; exit 64; }
  N="$2"; NAME="$3"; shift 3
  DIR="${LOCK_DIR:-/tmp/la-carte-locks}"; TIMEOUT="${LOCK_TIMEOUT:-3600}"; mkdir -p "$DIR"
  case " ${LACARTE_HELD_LOCKS:-} " in *" $NAME-held "*) exec "$@" ;; esac  # an outer caller already holds a slot
  LABEL="${LACARTE_LOCK_LABEL:-$(ps -o command= -p $PPID | cut -c1-120)}"
  MARK="$(mktemp)"; trap 'rm -f "$MARK" "$MARK.stalled"' EXIT
  WAITING=""
  while :; do
    for k in $(seq 1 "$N"); do
      FILE="$DIR/$NAME-$k.lock"
      HOLDER="${LACARTE_AGENT:-unnamed agent} · $LABEL · pid $$ · since $(date +%H:%M:%S)"
      : >"$MARK"; rm -f "$MARK.stalled"; set +e
      # shellcheck disable=SC2016
      LACARTE_HELD_LOCKS="${LACARTE_HELD_LOCKS:-} $NAME-held" lockf -s -k -t 0 "$FILE" \
        /bin/sh -c 'rm -f "$1"; printf "%s\n" "$2" >"$3.holder"; shift 3; exec "$@"' sh "$MARK" "$HOLDER" "$FILE" "$@" &
      CHILD=$!; trap 'kill $CHILD 2>/dev/null' INT TERM
      stall_guard "$CHILD" "$MARK.stalled" & GUARD=$!
      wait "$CHILD"; STATUS=$?; trap - INT TERM
      kill "$GUARD" 2>/dev/null; wait "$GUARD" 2>/dev/null; set -e
      if [ -e "$MARK.stalled" ]; then rm -f "$MARK.stalled"; exit 124; fi
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
