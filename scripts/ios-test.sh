#!/usr/bin/env bash
# Unit tests: every feature/client in LaCarteKit (TCA TestStore + Swift Testing).
# Own DerivedData (LaCarteKit package) and the first free unit-test simulator of a small pool (_sim-pool.sh),
# so it never waits behind an app build or a UI suite, and only waits when $UNIT_POOL_SIZE unit runs are going.
# --render (or LA_CARTE_RENDER_DIR=dir) also writes logo + gallery PNGs (DesignSystemTests/RenderTests).
# Other args go to xcodebuild, e.g. scripts/ios-test.sh --render -only-testing:DesignSystemTests/RenderTests
# Real StudyView screens: scripts/ios-test.sh --render -only-testing:ScreenColorTests/StudyRenders (screen-study-*.png)
# Each finished test prints as it finishes (also into a file), then a `TESTS: …` summary line.
# Exit code = xcodebuild's (65 test failure, 70 no such simulator, 75 lock timeout, 124 stalled and killed); 0 only if
# tests ran: a 0 with no result bundle, 0 tests or an unreadable summary becomes 66, with "Unable to find a device" 70.
set -euo pipefail
source "$(dirname "$0")/_proc.sh"; stage "ios-test: setup"  # stage lines + "still waiting at" warnings
source "$(dirname "$0")/_ios-env.sh"
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--render" ]; then
    LA_CARTE_RENDER_DIR="${LA_CARTE_RENDER_DIR:-${LA_CARTE_SCRATCH:-$ROOT/build}/renders}"
  else
    ARGS+=("$arg")
  fi
done
# xcodebuild strips TEST_RUNNER_ and passes the rest to the test process.
if [ -n "${LA_CARTE_RENDER_DIR:-}" ]; then export TEST_RUNNER_LA_CARTE_RENDER_DIR="$LA_CARTE_RENDER_DIR"; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
RESULT="$TMP/unit.xcresult"   # only for the summary line
cd "$ROOT/ios/LaCarteKit"
export NSUnbufferedIO=YES  # xcodebuild writes each line as it happens, even into a pipe
set +e
# First free unit-test simulator of the pool ($POOL_DESTINATION). No failure diagnostics: `simctl diagnose`
# kept the simulator for up to 10 min after a failing run (measured 2026-11-21, docs/dev-velocity.md).
# Keeps errors plus located notes: an error inside #expect/#require points at the test file only in its note.
# fseventsd hung (FSEVENTS_SHIM_DIR, _fsevents-shim.sh): `xcodebuild test` can't run, so build-for-testing (shim) then
# test-without-building (Apple's xcodebuild); the products copy costs ~500 MB in $TMP for the run.
if [ -n "${FSEVENTS_SHIM_DIR:-}" ]; then
  export KIT_PRODUCTS="$TMP/unit.xctestproducts"
  RUN='$BUILD_SLOT xcodebuild build-for-testing $BUILD_JOBS_FLAGS -scheme LaCarteKit-Package -destination "$POOL_DESTINATION" -skipMacroValidation -testProductsPath "$KIT_PRODUCTS" -quiet && exec xcodebuild test-without-building -destination "$POOL_DESTINATION" -testProductsPath "$KIT_PRODUCTS" "$@"'
else
  RUN='exec $BUILD_SLOT xcodebuild test $BUILD_JOBS_FLAGS -scheme LaCarteKit-Package -destination "$POOL_DESTINATION" -skipMacroValidation "$@"'
fi
stage "ios-test: build + unit tests (DerivedData lock, pool simulator, xcodebuild)"
"$LOCK" "$KIT_BUILD_LOCK" "$ROOT/scripts/_sim-pool.sh" /bin/sh -c "$RUN" sh \
  -collect-test-diagnostics never -resultBundlePath "$RESULT" ${ARGS[@]+"${ARGS[@]}"} 2>&1 \
  | grep --line-buffered -E "^(✔|✘|🔒|⚠️|❌|📱|🧹|🌗|🔄|✅ CoreSim|StudyRenders:)|Test [Cc]ase .*(passed|failed|skipped)|error:|\.swift:[0-9]+:[0-9]+: note:|TEST( EXECUTE)? (SUCCEEDED|FAILED)" \
  | tee "$TMP/out.log"
STATUS=${PIPESTATUS[0]}
set -e
stage "ios-test: summary (xcresulttool)"
# A 0 must mean tests ran (a caller trusts it): never pass on a missing destination, bundle or test count.
if grep -q "Unable to find a device matching the provided destination" "$TMP/out.log"; then
  echo "❌ xcodebuild found no simulator for the destination" >&2; [ "$STATUS" -ne 0 ] || STATUS=70
fi
if [ ! -d "$RESULT" ]; then
  echo "TESTS: none run (exit $STATUS: build failed, lock timeout or no result bundle)"; [ "$STATUS" -ne 0 ] || STATUS=66
else  # TESTS: 120 passed, 0 failed, 3 skipped (41.2 s), then one line per failed test. Exits 3 if no test ran.
  S=0; python3 -I - "$(xcrun xcresulttool get test-results summary --path "$RESULT")" "$STATUS" 2>/dev/null <<'PY' || S=$?
import json, sys
s = json.loads(sys.argv[1])
t = s["finishTime"] - s["startTime"]
took = f"{t / 60:.1f} min" if t >= 120 else f"{t:.1f} s"
if s["totalTestCount"] == 0:
    print(f"TESTS: none run (exit {sys.argv[2]}: build failed or no test matched)")
    sys.exit(3)
else:
    print(f"TESTS: {s['passedTests']} passed, {s['failedTests']} failed, {s['skippedTests']} skipped ({took})")
for f in s.get("testFailures", []):
    print(f"  ✘ {f['testIdentifierString']}: {f['failureText'][:200]}")
PY
  if [ "$S" -ne 0 ] && [ "$S" -ne 3 ]; then echo "⚠️  summary failed: can't tell whether any test ran" >&2; fi
  if [ "$S" -ne 0 ] && [ "$STATUS" -eq 0 ]; then STATUS=66; fi
fi
if [ -n "${LA_CARTE_RENDER_DIR:-}" ]; then echo "Renders: $LA_CARTE_RENDER_DIR"; fi
exit "$STATUS"
