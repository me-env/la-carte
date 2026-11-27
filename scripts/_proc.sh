# Process helpers that never block, even when the process table is wedged. Sourced by _lock.sh, _fsevents-shim.sh,
# _sim-pool.sh (via _ios-env.sh) and unstick.sh. Bash 3.2. "Hung ps" in docs/dev-velocity.md.
#
# Rule: no full-table `ps -ax…`. With a process stuck in state U it can hang for good (2026-11-26: every repo test
# script froze before its first line for hours), and `alarm` can't stop it: a U-state process ignores signals.
# Ask per pid (`ps -o … -p <pid>`, `pgrep -x <name>`, `pgrep -P <pid>`) and run every call through `bounded`.

# bounded <secs> <command> [args...]: run the command in the background and print its output. After <secs> give up
# (exit 124) and leave the hung call behind instead of waiting on it. Otherwise exits with the command's code.
bounded() {
  local secs="$1" out pid i=0 status=0; shift
  out="$(mktemp "${TMPDIR:-/tmp}/la-carte-bounded.XXXXXX")"
  "$@" >"$out" 2>/dev/null </dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge $((secs * 20)) ]; then
      kill -9 "$pid" 2>/dev/null; disown "$pid" 2>/dev/null; rm -f "$out"; return 124
    fi
    sleep 0.05; i=$((i + 1))
  done
  wait "$pid" || status=$?
  cat "$out"; rm -f "$out"; return "$status"
}

# proc_field <ps-field> <pid>: one ps field of one process, trimmed ("" if gone or ps hung). `time` includes the CPU of
# its exited children (ps -S), so a tree's total doesn't drop when a compiler process ends.
proc_field() { { bounded "${PROC_SECS:-5}" ps -S -o "$1=" -p "$2" || true; } | sed 's/^ *//; s/ *$//'; }

# to_seconds <ps time or etime>: [[dd-]hh:]mm:ss[.cc] -> centiseconds
to_cs() {
  echo "${1:-0}" | awk '{ t = $1; d = 0; if (index(t, "-")) { split(t, a, "-"); d = a[1]; t = a[2] }
    n = split(t, f, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + f[i]; print int((s + d * 86400) * 100) }'
}

# proc_tree <pid>: the pid and all its descendants, one per line (one bounded `pgrep -P` per tree level).
proc_tree() {
  local level="$1"
  while [ -n "$level" ]; do
    echo "$level" | tr ',' '\n'
    level="$({ bounded "${PROC_SECS:-5}" pgrep -P "$level" || true; } | paste -sd, -)"
  done
}

# tree_cpu <pid>: CPU centiseconds used by the pid and its descendants (exited ones included once reaped).
tree_cpu() {
  local p sum=0
  for p in $(proc_tree "$1"); do sum=$((sum + $(to_cs "$(proc_field time "$p")"))); done
  echo "$sum"
}

# fseventsd_hung: fseventsd is in state U (uninterruptible wait). Only a reboot clears it ("Hung builds").
fseventsd_hung() {
  local p
  for p in $({ bounded "${PROC_SECS:-5}" pgrep -x fseventsd || true; }); do
    case "$(proc_field stat "$p")" in U*) return 0 ;; esac
  done
  return 1
}

# stall_guard <pid> <flag-file> <minutes> <cpu-seconds>: background watchdog. Once <pid>'s whole tree has used less
# than <cpu-seconds> of CPU for <minutes> (0 = off), print why, touch <flag-file> and kill the tree (TERM, KILL 5 s
# later). Locks it held are dropped by the kernel when lockf exits.
stall_guard() {
  local pid="$1" flag="$2" window=$(( $3 * 60 )) min_cs=$(( $4 * 100 )) base since cpu tree
  [ "$window" -gt 0 ] || return 0
  base=$(tree_cpu "$pid"); since=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    sleep 15 </dev/null >/dev/null 2>&1
    cpu=$(tree_cpu "$pid")
    if [ $((cpu - base)) -ge "$min_cs" ] || [ "$cpu" -lt "$base" ]; then base=$cpu; since=$SECONDS
    elif [ $((SECONDS - since)) -ge "$window" ]; then
      tree=$(proc_tree "$pid" | tr '\n' ' ')
      echo "🔒 no progress for $3 min (process tree used <$4 s CPU): killing it and freeing its locks." \
        "Likely a hung clang-stat-cache / fseventsd / simulator: see 'Hung builds' in docs/dev-velocity.md" >&2
      : >"$flag"
      # shellcheck disable=SC2086
      kill $tree 2>/dev/null; sleep 5; kill -9 $tree 2>/dev/null
      return 0
    fi
  done
}

# guarded <minutes> <cpu-seconds> <command> [args...]: run the command under stall_guard (0 minutes = no guard).
# Returns the command's exit code, or 124 if the guard killed it. Its stdout/stderr reach ours through two relays
# (FIFO + cat) that we stop once the command is gone: a leftover that kept the output open (a child stuck in state U,
# or one that left the tree) otherwise blocks the caller's `| grep` for as long as it lives (2026-11-26: a run killed
# at 15 min held ios-test.sh until 72 min, "still waiting" all along). Safe under set -e.
guarded() {
  local min="$1" cpu="$2" dir child guard out err status=0 i=0; shift 2
  dir="$(mktemp -d "${TMPDIR:-/tmp}/la-carte-guard.XXXXXX")"
  mkfifo "$dir/out" "$dir/err"
  cat "$dir/out" & out=$!
  cat "$dir/err" >&2 & err=$!
  "$@" >"$dir/out" 2>"$dir/err" & child=$!
  trap 'kill $child 2>/dev/null' INT TERM
  stall_guard "$child" "$dir/stalled" "$min" "$cpu" & guard=$!
  wait "$child" || status=$?
  trap - INT TERM
  kill "$guard" 2>/dev/null || true; wait "$guard" 2>/dev/null || true
  # Normally both relays end at once (EOF). Give them 2 s to drain, then cut them.
  while { kill -0 "$out" || kill -0 "$err"; } 2>/dev/null && [ "$i" -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
  kill "$out" "$err" 2>/dev/null || true; wait "$out" "$err" 2>/dev/null || true
  [ ! -e "$dir/stalled" ] || status=124
  rm -rf "$dir"
  return "$status"
}

# stage <text>: log "▶ <text>"; if the script is still at that step STAGE_WARN_SECS (120) later, warn "still waiting
# at <text>" (again every 10 min), so a hang shows in the log instead of an empty file. The watcher ends with the script.
stage() {
  if [ -z "${STAGE_FILE:-}" ]; then
    STAGE_FILE="$(mktemp "${TMPDIR:-/tmp}/la-carte-stage.XXXXXX")"
    ( owner=$$; seen=""
      while kill -0 "$owner" 2>/dev/null; do
        sleep 1 </dev/null >/dev/null 2>&1
        read -r at text <"$STAGE_FILE" 2>/dev/null || continue
        [ "$at" = "$seen" ] || { seen="$at"; next=$((at + ${STAGE_WARN_SECS:-120})); }
        now=$(date +%s)
        if [ "$now" -ge "$next" ]; then
          echo "⏳ $(date +%H:%M:%S) still waiting at: $text ($(( (now - at) / 60 )) min)" >&2
          next=$((next + 600))
        fi
      done
      rm -f "$STAGE_FILE" ) </dev/null >/dev/null &
  fi
  printf '%s %s\n' "$(date +%s)" "$*" >"$STAGE_FILE"
  echo "▶ $(date +%H:%M:%S) $*" >&2
}
