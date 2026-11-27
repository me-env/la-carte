#!/usr/bin/env bash
# Split one UI test run across several UI pool simulators (scripts/_sim-pool.sh), so it finishes sooner.
#
#   scripts/ios-ui-test.sh --split [N] [--wait] [--record] <run-name> [-only-testing:LaCarteUITests/<Class>[/<test>] ...]
#
# Builds for testing once (same lock and private products copy as ios-ui-test.sh), lists the selected test
# methods from the built bundle (xcodebuild -enumerate-tests: it launches the runner, so it runs on a pool slot under
# its lock; no filter or a bare -only-testing:LaCarteUITests = all UI tests), deals them into N shards balanced by
# the last measured durations ($RESULTS_DIR/ui-test-durations.tsv, rewritten after each split run; test count
# otherwise), then runs every shard at once with test-without-building on its own pool slot and result bundle.
# Tests with no result in any shard bundle (a crash can end a shard early) are retried once, in one extra
# run on a free slot (lines prefixed [retry]).
# N defaults to the number of free UI slots and is capped by it and by the test count; at 1 this simply
# runs scripts/ios-ui-test.sh, so a bare N never waits for a busy pool.
# --wait: N (default UI_POOL_SIZE) is capped only by UI_POOL_SIZE and the test count; shards that find no free slot
# wait for one in scripts/_sim-pool.sh (up to LOCK_TIMEOUT). A shard that gets none is reported "not run (no simulator
# within <s>s)", exit 75, and is not retried. A caller already holding a simulator always gets 1 shard.
# --record (or UI_RECORD=1): every shard keeps passing tests' screen recordings too (ios-ui-test.sh --record), merged
# into qa/screenshots/<run-name>/recordings/ (same test name in two classes: <Class>-<test>.mp4).
# A shard whose simulator refuses the test runner before any test ran is run once more (scripts/_ui-retry.sh,
# `infra-retry: yes` in the TESTS line); refused again, its tests are "not run (simulator refused the runner)".
# Results: screenshots merged into qa/screenshots/<run-name>/, runner output in its logs/ (<shard>-console.txt per
# shard incl. retry, <Class>_<test>.txt per test), shard bundles merged into <run-name>.xcresult, one
# `TESTS: …` line (wall time, "not run" count) plus the failed and not-run tests.
# Exit code = first failing shard's code (xcodebuild's, 75 for no simulator) or the build's, else 65 if a test was
# still not run; log export/merge/summary failures only warn.
set -euo pipefail
source "$(dirname "$0")/_ios-env.sh"
source "$(dirname "$0")/_ui-retry.sh"
N=""; WAIT=""
while :; do  # leading options, any order: --split, N, --wait, --record
  case "${1:-}" in
    --split) shift ;;
    --wait) WAIT=1; shift ;;
    --record) export UI_RECORD=1; shift ;;
    *) if [ -z "$N" ] && [[ "${1:-}" =~ ^[0-9]+$ ]]; then N="$1"; shift; else break; fi ;;
  esac
done
RUN="${1:-$(date +%Y%m%d-%H%M%S)}"; shift || true
ONLY=(); PASS=()
for a in "$@"; do case "$a" in -only-testing:*) ONLY+=("${a#-only-testing:}") ;; *) PASS+=("$a") ;; esac; done
plain() { exec "$ROOT/scripts/ios-ui-test.sh" "$RUN" "$@"; }

# 1. How many shards: free UI slots now (same lock names as _sim-pool.sh), at most N; with --wait, the pool size.
DIR="${LOCK_DIR:-/tmp/la-carte-locks}"; mkdir -p "$DIR"
free_slots() {
  local k name free=0
  for k in $(seq 1 "$UI_POOL_SIZE"); do
    if [ "$k" -eq 1 ]; then name="$SIM_LOCK"; else name="sim-la-carte-ui-$k-$LOCK_OS"; fi
    lockf -s -k -t 0 "$DIR/$name.lock" true 2>/dev/null && free=$((free + 1))
  done
  echo "$free"
}
FREE="$(free_slots)"
case " ${LACARTE_HELD_LOCKS:-} " in *" sim-"*) FREE=1; WAIT="" ;; esac  # a caller holds a simulator: stay on it
CAP="$FREE"; [ -z "$WAIT" ] || CAP="$UI_POOL_SIZE"
N="${N:-$CAP}"; [ "$N" -le "$CAP" ] || N="$CAP"
if [ "$N" -le 1 ]; then echo "🔀 1 shard (free UI simulators: $FREE): plain run" >&2; plain "$@"; fi

# 2. Prepare, then build.
OUT="$ROOT/qa/screenshots/$RUN"
RESULT="$RESULTS_DIR/$RUN.xcresult"
PRODUCTS="$RESULTS_DIR/$RUN.xctestproducts"
WORK="$RESULTS_DIR/$RUN.split"   # shard lists, logs and bundles; removed on exit
DURATIONS="$RESULTS_DIR/ui-test-durations.tsv"
mkdir -p "$RESULTS_DIR"; rm -rf "$OUT" "$RESULT" "$PRODUCTS" "$WORK"; mkdir -p "$OUT" "$WORK"
trap 'rm -rf "$PRODUCTS" "$WORK"' EXIT
cd "$ROOT/ios"
# Keeps errors plus located notes: an error inside #expect/#require points at the test file only in its note.
FILTER="Test [Cc]ase .*(passed|failed|skipped)|error:|\.swift:[0-9]+:[0-9]+: note:|TEST( EXECUTE)? (SUCCEEDED|FAILED)|^🔒"
export NSUnbufferedIO=YES
START=$SECONDS
set +e
# Build once under the app's DerivedData lock, into this run's own products copy.
"$LOCK" "$APP_BUILD_LOCK" $BUILD_SLOT xcodebuild build-for-testing $BUILD_JOBS_FLAGS -project LaCarte.xcodeproj -scheme LaCarte \
  -destination "$DESTINATION" -skipMacroValidation -testProductsPath "$PRODUCTS" -quiet 2>&1 | grep --line-buffered -E "$FILTER"
STATUS=${PIPESTATUS[0]}
set -e
[ "$STATUS" -eq 0 ] || { echo "TESTS: none run (exit $STATUS: build failed or lock timeout)"; exit "$STATUS"; }
# --record: every shard tests these products, so one edit covers them all.
[ -z "$UI_RECORD" ] || ui_keep_recordings "$PRODUCTS" || { echo "TESTS: none run (--record: could not keep the recordings)"; exit 1; }

# 3. List the selected tests from the built bundle (catches tests declared in extensions) and deal them into N shards.
# Listing launches the test runner on the destination, so it takes a pool slot like a shard: on a simulator another
# run is using, it listed nothing.
ENUM="$WORK/tests.json"
set +e
SIM_POOL=ui "$ROOT/scripts/_sim-pool.sh" /bin/sh -c 'exec xcodebuild test-without-building -destination "$POOL_DESTINATION" "$@" >/dev/null 2>&1' \
  sh -testProductsPath "$PRODUCTS" -enumerate-tests -test-enumeration-style flat -test-enumeration-format json \
  -test-enumeration-output-path "$ENUM" 2>&1 | grep --line-buffered "^🔒" >&2
S=${PIPESTATUS[0]}
set -e
[ "$S" -eq 0 ] || { echo "TESTS: none run (exit $S: could not list the tests in the built bundle)"; exit "$S"; }
N="$(python3 -I - "$ENUM" "$DURATIONS" "$WORK" "$N" "${ONLY[@]+"${ONLY[@]}"}" <<'PY'
import json, os, sys
src, durations, work, n, only = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5:]
# {"errors": [], "values": [{"testPlan": "LaCarte", "enabledTests": [{"identifier": "LaCarteUITests/DeckUITests/testX()"}, …]}]}
# Methods only: a test-less base class is listed as "LaCarteUITests/SettingsTestCase"; a failed listing as "LaCarteUITests".
enum = json.load(open(src))
if enum.get("errors"): sys.exit(f"ERROR: listing the tests failed: {str(enum['errors'])[:500]}")
tests = [e["identifier"].removeprefix("LaCarteUITests/").removesuffix("()")
         for v in enum["values"] for e in v["enabledTests"]
         if e["identifier"].startswith("LaCarteUITests/") and e["identifier"].count("/") == 2]
if not tests: sys.exit("ERROR: the built bundle lists no LaCarteUITests tests")
if any(" " in o for o in only): sys.exit(f"ERROR: pass each -only-testing: as its own argument, got: {only[0][:200]}")
whole = any(o.rstrip("/") == "LaCarteUITests" for o in only)  # -only-testing:LaCarteUITests[/] = the whole target
sel = [] if whole else [o.removeprefix("LaCarteUITests/").removesuffix("()") for o in only]
total = len(tests)
tests = [t for t in tests if not sel or any(t == s or t.startswith(s + "/") for s in sel)]
if not tests: sys.exit("ERROR: 0 UI tests matched " + (" ".join(only) or "(no filter)") + f" among {total} tests in the built bundle")
known = {}
if os.path.exists(durations):
    for line in open(durations):
        secs, _, test = line.rstrip("\n").partition("\t"); known[test] = float(secs)
guess = sorted(known.values())[len(known) // 2] if known else 1.0  # unmeasured test: median
shards = [[0.0, []] for _ in range(min(n, len(tests)))]
for t in sorted(tests, key=lambda t: -known.get(t, guess)):  # longest first, onto the lightest shard
    s = min(shards, key=lambda s: s[0]); s[0] += known.get(t, guess); s[1].append(t)
for i, (secs, ts) in enumerate(shards, 1):
    open(os.path.join(work, f"{i}.args"), "w").write("".join(f"-only-testing:LaCarteUITests/{t}\n" for t in ts))
    print(f"🔀 shard {i}: {len(ts)} tests" + (f", ~{secs:.0f} s measured" if known else ""), file=sys.stderr)
print(len(shards))
PY
)"
BUSY=$(( N - $(free_slots) )); [ "$BUSY" -gt 0 ] || BUSY=0
echo "🔀 $N shards, $BUSY waiting for a free UI simulator" >&2

# 4. Every shard at once, each on its own free pool slot with its own result bundle.
shard() {  # <name>: runs the tests in $WORK/<name>.args into $WORK/<name>.xcresult, log lines prefixed [<name>]
  ARGS=(); while IFS= read -r a; do ARGS+=("$a"); done <"$WORK/$1.args"
  set +e
  ui_test_with_retry "shard $1" "$WORK/$1.xcresult" \
    env TEST_RUNNER_LA_CARTE_API_URL="${LA_CARTE_API_URL:-}" TEST_RUNNER_LA_CARTE_API_TOKEN="${LA_CARTE_API_TOKEN:-}" TEST_RUNNER_CI="${CI:-}" \
    SIM_POOL=ui "$ROOT/scripts/_sim-pool.sh" /bin/sh -c 'exec xcodebuild test-without-building -destination "$POOL_DESTINATION" "$@"' \
    sh -testProductsPath "$PRODUCTS" -collect-test-diagnostics never -resultBundlePath "$WORK/$1.xcresult" \
    "${ARGS[@]}" "${PASS[@]+"${PASS[@]}"}" | grep --line-buffered -E "$FILTER" | sed -l "s/^/[$1] /"
  exit "${PIPESTATUS[0]}"
}
PIDS=()
for k in $(seq 1 "$N"); do ( shard "$k" ) & PIDS+=($!); done
trap 'kill "${PIDS[@]}" 2>/dev/null; rm -rf "$PRODUCTS" "$WORK"' INT TERM
NOSIM="no simulator within ${LOCK_TIMEOUT:-3600}s"
REFUSED="simulator refused the runner"
for k in $(seq 1 "$N"); do
  wait "${PIDS[$((k - 1))]}" && S=0 || S=$?
  [ "$STATUS" -ne 0 ] || STATUS=$S
  # _sim-pool.sh gave up waiting (75, no bundle): its tests are "not run", never retried (that would wait again)
  if [ "$S" -eq 75 ] && [ ! -d "$WORK/$k.xcresult" ]; then mv "$WORK/$k.args" "$WORK/$k.nosim"; fi
  # refused the runner twice (scripts/_ui-retry.sh): "not run" too, its empty bundle dropped
  if [ "$(cat "$WORK/$k.xcresult.infra" 2>/dev/null)" = refused ]; then rm -rf "$WORK/$k.xcresult"; mv "$WORK/$k.args" "$WORK/$k.refused"; fi
done
BUNDLES=(); for k in $(seq 1 "$N"); do [ -d "$WORK/$k.xcresult" ] && BUNDLES+=("$WORK/$k.xcresult"); done
cat "$WORK"/*.nosim >"$WORK/nosim.list" 2>/dev/null || true
cat "$WORK"/*.refused >"$WORK/refused.list" 2>/dev/null || true
if [ ${#BUNDLES[@]} -eq 0 ] && [ -s "$WORK/refused.list" ] && [ ! -s "$WORK/nosim.list" ]; then
  echo "TESTS: infra failure ($REFUSED)"; exit "$STATUS"
fi
[ ${#BUNDLES[@]} -gt 0 ] || { echo "TESTS: none run (exit $STATUS: no shard produced results$([ -s "$WORK/nosim.list" ] && echo ", $NOSIM"))"
  [ "$STATUS" -ne 0 ] || STATUS=66; exit "$STATUS"; }

# 5. Selected tests with no result in any bundle (a crash ends a shard early): retry them once, in one run.
not_run() {  # writes the not-run tests as -only-testing args to $WORK/$1.args; true if there are any
  python3 -I - "$WORK" "$WORK/$1.args" <<'PY'
import glob, json, subprocess, sys
work, out = sys.argv[1], sys.argv[2]
expected = [l.strip() for f in sorted(glob.glob(f"{work}/[0-9]*.args")) for l in open(f)]
seen = set()
for b in glob.glob(f"{work}/*.xcresult"):
    r = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", b], capture_output=True)
    stack = json.loads(r.stdout)["testNodes"] if r.returncode == 0 else []
    while stack:
        node = stack.pop()
        if node.get("nodeType") == "Test Case": seen.add("-only-testing:LaCarteUITests/" + node["nodeIdentifier"].removesuffix("()"))
        stack += node.get("children", [])
missing = [t for t in expected if t not in seen]
open(out, "w").write("".join(t + "\n" for t in missing))
sys.exit(0 if missing else 1)
PY
}
RETRIED=0; : >"$WORK/still.args"
if not_run retry; then
  RETRIED=$(wc -l <"$WORK/retry.args" | tr -d ' ')
  echo "🔁 retrying $RETRIED not-run tests" >&2
  ( shard retry ) && S=0 || S=$?
  [ "$STATUS" -ne 0 ] || STATUS=$S
  if [ "$(cat "$WORK/retry.xcresult.infra" 2>/dev/null)" = refused ]; then rm -rf "$WORK/retry.xcresult"; fi
  [ -d "$WORK/retry.xcresult" ] && BUNDLES+=("$WORK/retry.xcresult")
  not_run still && { [ "$STATUS" -ne 0 ] || STATUS=65; }
fi
WALL=$((SECONDS - START))
INFRA_RETRY=""; grep -qx retried "$WORK"/*.infra 2>/dev/null && INFRA_RETRY=1

# 6. Merge: screenshots, one xcresult, durations, summary.
warn() { echo "⚠️  $1 failed (exit code unchanged: $STATUS)" >&2; }
for b in "${BUNDLES[@]}"; do
  EXP="$OUT/.export"; rm -rf "$EXP"   # same volume as $OUT: renames, not copies
  xcrun xcresulttool export attachments --path "$b" --output-path "$EXP" >/dev/null || { warn "screenshot export"; continue; }
  python3 -I - "$EXP" "$OUT" <<'PY' || warn "screenshot rename"
import json, os, re, sys
src_dir, out = sys.argv[1], sys.argv[2]
manifest = os.path.join(src_dir, "manifest.json")
for test in json.load(open(manifest)) if os.path.exists(manifest) else []:
    test_name = re.sub(r"\W", "", test["testIdentifier"].split("/")[-1])
    for a in test.get("attachments", []):
        src = os.path.join(src_dir, a["exportedFileName"])
        ext = os.path.splitext(src)[1]
        name = os.path.splitext(a["suggestedHumanReadableName"])[0]
        if name.startswith("Screen Recording"):  # Xcode records each UI test
            os.makedirs(os.path.join(out, "recordings"), exist_ok=True)
            dest = os.path.join(out, "recordings", test_name + ext)
            if os.path.exists(dest):  # same test name in another class or shard: "<Class>-<test>.mp4"
                dest = os.path.join(out, "recordings", re.sub(r"\W", "", test["testIdentifier"].split("/")[-2]) + "-" + test_name + ext)
            os.rename(src, dest)
        else:  # "home-dark_0_<UUID>" → "home-dark"
            os.rename(src, os.path.join(out, re.sub(r"_\d+_[0-9A-F-]{36}$", "", name) + ext))
PY
  rm -rf "$EXP"
  ui_export_logs "$b" "$OUT/logs" "$(basename "$b" .xcresult)-console"  # per shard, before the merge
done
if [ -f "$ROOT/scripts/contact-sheet.py" ] && command -v uv >/dev/null; then
  uv run "$ROOT/scripts/contact-sheet.py" "$OUT" || warn "contact sheet"
fi
if [ ${#BUNDLES[@]} -eq 1 ]; then mv "${BUNDLES[0]}" "$RESULT"; BUNDLES=("$RESULT")
else xcrun xcresulttool merge "${BUNDLES[@]}" --output-path "$RESULT" >/dev/null || warn "xcresult merge"; fi
echo "📸 screenshots: $OUT  (xcresult: $RESULT)"
ui_logs_summary "$OUT"
ls -R "$OUT" || true
ui_recordings_summary "$OUT"
# TESTS: 22 passed, 0 failed, 1 skipped, 1 not run, 4 not run (no simulator within 3600s) (3.1 min wall, 3 shards,
# 2 retried[, infra-retry: yes]), then one line per failed and per not-run test.
python3 -I - "$WALL" "$N" "$RETRIED" "$WORK/still.args" "$WORK/nosim.list" "$NOSIM" "$DURATIONS" "$WORK/refused.list" \
  "$REFUSED" "$INFRA_RETRY" "${BUNDLES[@]}" <<'PY' || warn "summary"
import json, os, subprocess, sys
wall, n, retried = float(sys.argv[1]), sys.argv[2], int(sys.argv[3])
still, nosim_list, nosim, durations, refused_list, refused, infra_retry, bundles = *sys.argv[4:11], sys.argv[11:]
strip = lambda path: [l.strip().removeprefix("-only-testing:LaCarteUITests/") for l in open(path)]
not_run, no_sim, no_runner = strip(still), strip(nosim_list), strip(refused_list)
get = lambda kind, b: json.loads(subprocess.run(["xcrun", "xcresulttool", "get", "test-results", kind, "--path", b],
                                                capture_output=True, check=True).stdout)
passed = failed = skipped = 0; failures = []
known = {}
if os.path.exists(durations):
    for line in open(durations):
        secs, _, test = line.rstrip("\n").partition("\t"); known[test] = secs
for b in bundles:
    s = get("summary", b)
    passed += s["passedTests"]; failed += s["failedTests"]; skipped += s["skippedTests"]
    failures += s.get("testFailures", [])
    stack = list(get("tests", b)["testNodes"])
    while stack:
        node = stack.pop()
        if node.get("nodeType") == "Test Case" and "durationInSeconds" in node:
            known[node["nodeIdentifier"].removesuffix("()")] = f"{node['durationInSeconds']:.1f}"
        stack += node.get("children", [])
with open(durations, "w") as f:
    f.writelines(f"{secs}\t{test}\n" for test, secs in sorted(known.items()))
took = f"{wall / 60:.1f} min" if wall >= 120 else f"{wall:.0f} s"
print(f"TESTS: {passed} passed, {failed} failed, {skipped} skipped" + (f", {len(not_run)} not run" if not_run else "")
      + (f", {len(no_sim)} not run ({nosim})" if no_sim else "")
      + (f", {len(no_runner)} not run ({refused})" if no_runner else "")
      + f" ({took} wall, {n} shards" + (f", {retried} retried" if retried else "")
      + (", infra-retry: yes" if infra_retry else "") + ")")
for f in failures:
    print(f"  ✘ {f['testIdentifierString']}: {f['failureText'][:200]}")
for t in not_run:
    print(f"  ⊘ {t}: not run")
for t in no_sim:
    print(f"  ⊘ {t}: not run ({nosim})")
for t in no_runner:
    print(f"  ⊘ {t}: not run ({refused})")
PY
exit "$STATUS"
