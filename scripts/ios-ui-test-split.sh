#!/usr/bin/env bash
# Split one UI test run across several UI pool simulators (scripts/_sim-pool.sh), so it finishes sooner.
#
#   scripts/ios-ui-test.sh --split [N] <run-name> [-only-testing:LaCarteUITests/<Class>[/<test>] ...]
#
# Builds for testing once (same lock and private products copy as ios-ui-test.sh), lists the selected test
# methods (grep of `func test` in ios/LaCarteUITests), deals them into N shards balanced by the last measured
# durations ($RESULTS_DIR/ui-test-durations.tsv, rewritten after each split run; test count otherwise), then
# runs every shard at once with test-without-building on its own pool slot and result bundle.
# N defaults to the number of free UI slots and is capped by it and by the test count; at 1 this simply
# runs scripts/ios-ui-test.sh. Results: screenshots merged into qa/screenshots/<run-name>/, shard bundles
# merged into <run-name>.xcresult, one `TESTS: …` line (wall time) plus the failed tests.
# Exit code = first failing shard's xcodebuild code (or the build's); merge/summary failures only warn.
set -euo pipefail
source "$(dirname "$0")/_ios-env.sh"
[ "${1:-}" = --split ] && shift
N=""; if [[ "${1:-}" =~ ^[0-9]+$ ]]; then N="$1"; shift; fi
RUN="${1:-$(date +%Y%m%d-%H%M%S)}"; shift || true
ONLY=(); PASS=()
for a in "$@"; do case "$a" in -only-testing:*) ONLY+=("${a#-only-testing:}") ;; *) PASS+=("$a") ;; esac; done
plain() { exec "$ROOT/scripts/ios-ui-test.sh" "$RUN" "$@"; }

# 1. How many shards: free UI slots now (same lock names as _sim-pool.sh), at most N.
DIR="${LOCK_DIR:-/tmp/la-carte-locks}"; mkdir -p "$DIR"
FREE=0
for k in $(seq 1 "$UI_POOL_SIZE"); do
  if [ "$k" -eq 1 ]; then NAME="$SIM_LOCK"; else NAME="sim-la-carte-ui-$k-$LOCK_OS"; fi
  lockf -s -k -t 0 "$DIR/$NAME.lock" true 2>/dev/null && FREE=$((FREE + 1))
done
case " ${LACARTE_HELD_LOCKS:-} " in *" sim-"*) FREE=1 ;; esac  # a caller holds a simulator: stay on it
N="${N:-$FREE}"; [ "$N" -le "$FREE" ] || N="$FREE"
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
FILTER="Test [Cc]ase .*(passed|failed|skipped)|error:|TEST( EXECUTE)? (SUCCEEDED|FAILED)|^🔒"
export NSUnbufferedIO=YES
START=$SECONDS
set +e
# Build once under the app's DerivedData lock, into this run's own products copy.
"$LOCK" "$APP_BUILD_LOCK" xcodebuild build-for-testing -project LaCarte.xcodeproj -scheme LaCarte \
  -destination "$DESTINATION" -skipMacroValidation -testProductsPath "$PRODUCTS" -quiet 2>&1 | grep --line-buffered -E "$FILTER"
STATUS=${PIPESTATUS[0]}
set -e
[ "$STATUS" -eq 0 ] || { echo "TESTS: none run (exit $STATUS: build failed or lock timeout)"; exit "$STATUS"; }

# 3. List the selected tests from the built bundle (catches tests declared in extensions) and deal them into N shards.
ENUM="$WORK/tests.json"
xcodebuild test-without-building -testProductsPath "$PRODUCTS" -destination "$DESTINATION" -enumerate-tests \
  -test-enumeration-style flat -test-enumeration-format json -test-enumeration-output-path "$ENUM" >/dev/null 2>&1 \
  || { echo "ERROR: could not enumerate tests in the built bundle" >&2; exit 1; }
N="$(python3 -I - "$ENUM" "$DURATIONS" "$WORK" "$N" "${ONLY[@]+"${ONLY[@]}"}" <<'PY'
import json, os, sys
src, durations, work, n, only = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5:]
tests = [e["identifier"].removeprefix("LaCarteUITests/").removesuffix("()")
         for v in json.load(open(src))["values"] for e in v["enabledTests"] if e["identifier"].startswith("LaCarteUITests/")]
sel = [o.removeprefix("LaCarteUITests/").removesuffix("()") for o in only]
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


# 4. Every shard at once, each on its own free pool slot with its own result bundle.
PIDS=()
for k in $(seq 1 "$N"); do
  ARGS=(); while IFS= read -r a; do ARGS+=("$a"); done <"$WORK/$k.args"
  (
    set +e
    TEST_RUNNER_LA_CARTE_API_URL="${LA_CARTE_API_URL:-}" TEST_RUNNER_LA_CARTE_API_TOKEN="${LA_CARTE_API_TOKEN:-}" \
    SIM_POOL=ui "$ROOT/scripts/_sim-pool.sh" /bin/sh -c 'exec xcodebuild test-without-building -destination "$POOL_DESTINATION" "$@"' \
      sh -testProductsPath "$PRODUCTS" -collect-test-diagnostics never -resultBundlePath "$WORK/$k.xcresult" \
      "${ARGS[@]}" "${PASS[@]+"${PASS[@]}"}" 2>&1 | grep --line-buffered -E "$FILTER" | sed -l "s/^/[$k] /"
    exit "${PIPESTATUS[0]}"
  ) &
  PIDS+=($!)
done
trap 'kill "${PIDS[@]}" 2>/dev/null; rm -rf "$PRODUCTS" "$WORK"' INT TERM
for p in "${PIDS[@]}"; do
  wait "$p" && S=0 || S=$?
  [ "$STATUS" -ne 0 ] || STATUS=$S
done
WALL=$((SECONDS - START))

# 5. Merge: screenshots, one xcresult, durations, summary.
warn() { echo "⚠️  $1 failed (exit code unchanged: $STATUS)" >&2; }
BUNDLES=(); for k in $(seq 1 "$N"); do [ -d "$WORK/$k.xcresult" ] && BUNDLES+=("$WORK/$k.xcresult"); done
[ ${#BUNDLES[@]} -gt 0 ] || { echo "TESTS: none run (exit $STATUS: no shard produced results)"; exit "$STATUS"; }
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
            os.rename(src, os.path.join(out, "recordings", test_name + ext))
        else:  # "home-dark_0_<UUID>" → "home-dark"
            os.rename(src, os.path.join(out, re.sub(r"_\d+_[0-9A-F-]{36}$", "", name) + ext))
PY
  rm -rf "$EXP"
done
if [ -f "$ROOT/scripts/contact-sheet.py" ] && command -v uv >/dev/null; then
  uv run "$ROOT/scripts/contact-sheet.py" "$OUT" || warn "contact sheet"
fi
if [ ${#BUNDLES[@]} -eq 1 ]; then mv "${BUNDLES[0]}" "$RESULT"
else xcrun xcresulttool merge "${BUNDLES[@]}" --output-path "$RESULT" >/dev/null || warn "xcresult merge"; fi
echo "📸 screenshots: $OUT  (xcresult: $RESULT)"
ls -R "$OUT" || true
# TESTS: 22 passed, 0 failed, 1 skipped (3.1 min wall, 3 shards), then one line per failed test.
python3 -I - "$WALL" "$N" "$DURATIONS" "${BUNDLES[@]}" <<'PY' || warn "summary"
import json, os, subprocess, sys
wall, n, durations, bundles = float(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4:]
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
print(f"TESTS: {passed} passed, {failed} failed, {skipped} skipped ({took} wall, {n} shards)")
for f in failures:
    print(f"  ✘ {f['testIdentifierString']}: {f['failureText'][:200]}")
PY
exit "$STATUS"
