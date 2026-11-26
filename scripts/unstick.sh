#!/usr/bin/env bash
# Watchdog for stuck la-carte test runs (hourly cron in the manager session). "Stuck runs" in docs/dev-velocity.md.
#
#   scripts/unstick.sh [--dry-run]
#
# 1. Finds la-carte runs: xcodebuild, xctest, lockf, our scripts (_lock/_sim-pool/ios-*/e2e) and simulator test
#    runners (*-Runner), only when their args or cwd mention la-carte/LaCarte (repo, worktrees, /Volumes/*/la-carte,
#    the scratchpad, /tmp/la-carte-locks). Other projects' Xcode work is never touched.
# 2. Samples each run's whole process tree twice, UNSTICK_WINDOW s (60) apart. Stuck = running > 15 min and the tree
#    gained < 1 s of CPU. A lock waiter (lockf queued, or a slot/pool poller) is stuck only when its holder is.
# 3. Kills stuck trees: TERM, KILL 5 s later (lockf exits, so the kernel frees their locks). --dry-run only lists.
# 4. Survivors (state U) are "unkillable, needs reboot", remembered in $LOCK_DIR/unstick.unkillable: not signalled
#    again. 5. Checks fseventsd, filecoordinationd, SimAudioProcessorService and Xcode for a hang (state U in both
#    samples; SimAudio: a stuck read of a simulator audio plist).
# Prints at most 5 lines; always exits 0. Cron-safe: no full-table ps (it can hang for good), every ps/pgrep/lsof is
# bounded (_proc.sh), the run gives up after UNSTICK_MAX s (200). No sudo, no simctl, no ~/Library.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/_proc.sh"
DRY=""; case "${1:-}" in --dry-run) DRY=1 ;; "") ;; *) echo "usage: $0 [--dry-run]" >&2; exit 64 ;; esac
WINDOW="${UNSTICK_WINDOW:-60}"; MIN_AGE="${UNSTICK_MIN_AGE:-900}"; MIN_CS=100
KNOWN="${LOCK_DIR:-/tmp/la-carte-locks}/unstick.unkillable"; mkdir -p "$(dirname "$KNOWN")"; touch "$KNOWN"
T="$(mktemp -d "${TMPDIR:-/tmp}/la-carte-unstick.XXXXXX")"
( sleep "${UNSTICK_MAX:-200}" & s=$!; trap 'kill $s; exit' TERM; wait $s; kill -TERM $$ ) </dev/null >/dev/null 2>&1 &
BUDGET=$!
trap 'echo "unstick: gave up after ${UNSTICK_MAX:-200} s (a call hung); reboot needed: unknown"; exit 0' TERM
trap 'kill $BUDGET 2>/dev/null; rm -rf "$T"' EXIT

# info <pid> -> "ppid stat cpu_cs age_s comm" (cached per sample in $T/i<sample>.<pid>; empty if gone or ps hung)
info() {
  local f="$T/i$SAMPLE.$1" l
  if [ ! -e "$f" ]; then
    l="$(bounded 5 ps -S -o ppid=,stat=,time=,etime=,comm= -p "$1" || true)"
    [ -n "$l" ] && echo "$l" | awk '{ c = $5; for (i = 6; i <= NF; i++) c = c " " $i
      print $1, $2, cs($3), int(cs($4) / 100), c }
      function cs(t,  a, f, n, s, d, i) { d = 0; if (index(t, "-")) { split(t, a, "-"); d = a[1]; t = a[2] }
        n = split(t, f, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + f[i]; return int((s + d * 86400) * 100) }' >"$f"
    [ -e "$f" ] || : >"$f"
  fi
  cat "$f"
}
field() { info "$2" | cut -d' ' -f"$1"; }          # field <n> <pid>: 1 ppid 2 stat 3 cpu 4 age 5- comm
args() { [ -e "$T/a.$1" ] || { bounded 5 ps -o args= -p "$1" || true; } >"$T/a.$1"; cat "$T/a.$1"; }
short() { local c; c="$(field 5- "$1")"; echo "${c##*/}"; }
is_ours() {  # args or cwd mention la-carte
  args "$1" | grep -Eq 'la-carte|LaCarte' && return 0
  { bounded 5 lsof -a -p "$1" -d cwd -Fn || true; } | grep -Eq '^n.*la-carte'
}

# 1. Candidates and their roots (a candidate with no candidate ancestor).
SAMPLE=0
{ for n in xcodebuild xcodebuild.bin xctest lockf; do bounded 5 pgrep -x "$n"; done
  bounded 5 pgrep -f 'scripts/(_lock|_sim-pool|ios-ui-test|ios-ui-test-split|ios-test|ios-build|e2e)\.sh'
  bounded 5 pgrep -f -- '-Runner( |$)'
} 2>/dev/null | sort -un >"$T/all"
: >"$T/cands"
while read -r p; do
  [ "$p" = $$ ] && continue
  c="$(short "$p")"; [ -n "$c" ] || continue
  case "$c" in zsh|-zsh|fish|claude|node) continue ;; esac   # agents' shells that merely mention a script
  is_ours "$p" && echo "$p" >>"$T/cands"
done <"$T/all"
: >"$T/roots"
while read -r p; do
  q="$(field 1 "$p")"; root=1
  while [ -n "$q" ] && [ "$q" -gt 1 ]; do
    grep -qx "$q" "$T/cands" && { root=0; break; }
    q="$(field 1 "$q")"
  done
  [ "$root" = 1 ] && echo "$p" >>"$T/roots"
done <"$T/cands"

# 2. Two samples of every root's tree, plus the system daemons' state.
daemons() {  # one "name pid stat" line per daemon process
  local n p
  for n in fseventsd filecoordinationd Xcode; do
    for p in $(bounded 5 pgrep -x "$n"); do echo "$n $p $(field 2 "$p")"; done
  done
  for p in $(bounded 5 pgrep -U "$(id -u)" -f 'SimAudioProcessorService.xpc/Contents/MacOS/SimAudioProcessorService'); do
    echo "SimAudioProcessorService $p $(field 2 "$p")"
  done
}
sample() {  # sample <n>: $T/s<n> = "root cpu age"; $T/t<n>.<root> = tree pids
  SAMPLE="$1"; local r p sum
  : >"$T/s$1"
  while read -r r; do
    proc_tree "$r" >"$T/t$1.$r"; sum=0
    while read -r p; do sum=$((sum + $(field 3 "$p" | grep -E '^[0-9]+$' || echo 0))); done <"$T/t$1.$r"
    echo "$r $sum $(field 4 "$r")" >>"$T/s$1"
  done <"$T/roots"
  daemons >"$T/d$1"
}
sample 1
if [ -s "$T/roots" ] || [ -s "$T/d1" ]; then sleep "$WINDOW"; fi
sample 2

# Which roots are stuck. Idle = alive in both samples, older than MIN_AGE, CPU gain in [0, 1 s).
idle() { awk -v r="$1" -v age="$MIN_AGE" -v min="$MIN_CS" 'FNR == NR { if ($1 == r) c1 = $2; next }
  $1 == r && $3 != "" && $3 >= age && c1 != "" && $2 - c1 >= 0 && $2 - c1 < min { f = 1 } END { exit !f }' "$T/s1" "$T/s2"; }
root_of() { local r; while read -r r; do grep -qx "$1" "$T/t2.$r" 2>/dev/null && { echo "$r"; return; }; done <"$T/roots"; }
lock_file() { args "$1" | tr ' ' '\n' | grep -E '\.lock$' | head -1; }
has_kids() { [ -n "$({ bounded 5 pgrep -P "$1" || true; })" ]; }
# waits_on <root>: the lock-file regex its tree is queued for ("" if it isn't waiting on a lock)
waits_on() {
  local p a
  while read -r p; do
    case "$(short "$p")" in
      lockf) has_kids "$p" || { lock_file "$p" | sed 's/[.]/[.]/g'; return; } ;;
      bash|sh)
        a="$(args "$p")"
        case "$a" in
          *"_lock.sh --slots "*) echo "/$(echo "${a#*_lock.sh --slots }" | cut -d' ' -f2)-[0-9]+[.]lock$"; return ;;
          *_sim-pool.sh*--on-slot*) ;;
          *_sim-pool.sh*) bounded 5 pgrep -x -P "$p" lockf >/dev/null || { echo '/sim-[^/]*[.]lock$'; return; } ;;
        esac ;;
    esac
  done <"$T/t2.$1"
}
: >"$T/stuck"; : >"$T/waiters"
while read -r r; do
  idle "$r" || continue
  if grep -Eq "$(printf '%s|' xcodebuild xctest -Runner | sed 's/|$//')" < <(while read -r p; do short "$p"; done <"$T/t2.$r"); then
    echo "$r" >>"$T/stuck"
  else
    w="$(waits_on "$r")"
    if [ -n "$w" ]; then echo "$r $w" >>"$T/waiters"; else echo "$r" >>"$T/stuck"; fi
  fi
done <"$T/roots"
for _ in 1 2; do  # a waiter is stuck when every holder of what it waits on is stuck (twice: nested waits)
  while read -r r w; do
    grep -qx "$r" "$T/stuck" && continue
    holders=""; all=1
    for p in $(grep -x '[0-9]*' "$T/cands"); do
      [ "$(short "$p")" = lockf ] && lock_file "$p" | grep -Eq "$w" && has_kids "$p" || continue
      h="$(root_of "$p")"; [ -n "$h" ] && [ "$h" != "$r" ] || continue
      holders="$holders $h"; grep -qx "$h" "$T/stuck" || all=0
    done
    [ -n "$holders" ] && [ "$all" = 1 ] && echo "$r" >>"$T/stuck"
  done <"$T/waiters"
done

# 3-4. Kill (TERM, then KILL) every process of every stuck tree, except known-unkillable ones.
label() { echo "$1 $(short "$1")"; }
key() { echo "$1 $({ bounded 5 ps -o lstart= -p "$1" || true; } | tr -s ' ')" | sed 's/ *$//'; }  # pid + start time
: >"$T/targets"
while read -r r; do cat "$T/t2.$r"; done <"$T/stuck" | sort -un | while read -r p; do
  kill -0 "$p" 2>/dev/null && echo "$p"; done >"$T/targets"
KILLED=""; UNKILL=""
if [ -n "$DRY" ]; then
  while read -r p; do
    if grep -qxF "$(key "$p")" "$KNOWN"; then continue  # reported below
    elif case "$(field 2 "$p")" in U*) true ;; *) false ;; esac; then
      UNKILL="$UNKILL, $(label "$p") (state $(field 2 "$p"))"
    else KILLED="$KILLED, $(label "$p")"; fi
  done <"$T/targets"
else
  SAMPLE=3; : >"$T/signalled"
  while read -r p; do
    if ! grep -qxF "$(key "$p")" "$KNOWN"; then label "$p" >>"$T/signalled"; key "$p" >"$T/k.$p"; kill -TERM "$p" 2>/dev/null; fi
  done <"$T/targets"
  if [ -s "$T/signalled" ]; then
    sleep 5; cut -d' ' -f1 "$T/signalled" | while read -r p; do kill -KILL "$p" 2>/dev/null; done; sleep 2
  fi
  while read -r p name; do
    if kill -0 "$p" 2>/dev/null && [ "$(key "$p")" = "$(cat "$T/k.$p")" ]; then
      UNKILL="$UNKILL, $p $name (state $(field 2 "$p"))"; cat "$T/k.$p" >>"$KNOWN"
    else KILLED="$KILLED, $p $name"; fi
  done <"$T/signalled"
fi
# Earlier runs' unkillable processes: report the ones still alive (a reboot is still needed), forget the rest.
while read -r l; do [ "$(key "${l%% *}")" = "$l" ] && echo "$l"; done <"$KNOWN" >"$T/known"; cp "$T/known" "$KNOWN"
while read -r p _; do case "$UNKILL, " in *", $p "*) ;; *) UNKILL="$UNKILL, $(label "$p") (up $(field 4 "$p" | awk '{ printf "%dh%02dm", $1 / 3600, $1 % 3600 / 60 }'))" ;; esac
done <"$T/known"

# 5. System daemons: hung = state U in both samples (or ps hung on it); SimAudio also via its stuck plist read.
SYS=""; HUNG=""
for n in fseventsd filecoordinationd SimAudioProcessorService Xcode; do
  s="ok"
  if ! grep -q "^$n " "$T/d2"; then s="not running"
  else
    while read -r _ p st; do
      if [ -z "$st" ] || { case "$st" in U*) grep -q "^$n $p U" "$T/d1" ;; *) false ;; esac; }; then s="hung"; fi
      if [ "$n" = SimAudioProcessorService ] && { bounded 10 lsof -p "$p" -Fn || true; } \
        | grep -F 'com.apple.coresimulator.audio.plist' >/dev/null; then s="hung"; fi
    done < <(grep "^$n " "$T/d2")
  fi
  SYS="$SYS; $n $s"; [ "$s" = hung ] && HUNG="$HUNG, $n"
done

cap() { local s="${1#, }"; [ -n "$s" ] || { echo none; return; }
  echo "$s" | tr ',' '\n' | sed 's/^ //' | awk 'NR <= 6 { o = o (NR > 1 ? ", " : "") $0 } END { print o (NR > 6 ? ", +" NR - 6 " more" : "") }'; }
REASON="${HUNG#, }"; [ -n "$UNKILL" ] && REASON="${REASON:+$REASON, }unkillable processes"
echo "unstick $(date +%H:%M)${DRY:+ (dry run)}: $(wc -l <"$T/roots" | tr -d ' ') la-carte run(s) checked, $(wc -l <"$T/stuck" | tr -d ' ') stuck"
echo "${DRY:+would be }killed: $(cap "$KILLED")"
echo "unkillable, needs reboot: $(cap "$UNKILL")"
echo "system: ${SYS#; }"
if [ -n "$REASON" ]; then echo "reboot needed: yes ($REASON)"; else echo "reboot needed: no"; fi
exit 0
