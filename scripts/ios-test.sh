#!/usr/bin/env bash
# Unit tests: every feature/client in LaCarteKit (TCA TestStore + Swift Testing).
# Own DerivedData (LaCarteKit package) and own simulator ($UNIT_SIMULATOR), so it never waits behind an app
# build or a UI suite; only behind another unit-test run.
# --render (or LA_CARTE_RENDER_DIR=dir) also writes logo + gallery PNGs (DesignSystemTests/RenderTests).
# Other args go to xcodebuild, e.g. scripts/ios-test.sh --render -only-testing:DesignSystemTests/RenderTests
# Each finished test prints as it finishes (also into a file), then a `TESTS: …` summary line.
# Exit code = xcodebuild's (65 test failure, 75 lock timeout); the summary only warns if it fails.
set -euo pipefail
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
"$LOCK" "$KIT_BUILD_LOCK" "$LOCK" "$UNIT_SIM_LOCK" \
  xcodebuild test -scheme LaCarteKit -destination "$UNIT_DESTINATION" -skipMacroValidation \
  -resultBundlePath "$RESULT" ${ARGS[@]+"${ARGS[@]}"} 2>&1 \
  | grep --line-buffered -E "^(✔|✘|🔒)|Test [Cc]ase .*(passed|failed|skipped)|error:|TEST (SUCCEEDED|FAILED)"
STATUS=${PIPESTATUS[0]}
set -e
if [ ! -d "$RESULT" ]; then
  echo "TESTS: none run, xcodebuild exited $STATUS"
else  # TESTS: 120 passed, 0 failed, 3 skipped (41.2 s), then one line per failed test.
  python3 -I - "$(xcrun xcresulttool get test-results summary --path "$RESULT")" <<'PY' \
    || echo "⚠️  summary failed (exit code unchanged: $STATUS)" >&2
import json, sys
s = json.loads(sys.argv[1])
t = s["finishTime"] - s["startTime"]
took = f"{t / 60:.1f} min" if t >= 120 else f"{t:.1f} s"
print(f"TESTS: {s['passedTests']} passed, {s['failedTests']} failed, {s['skippedTests']} skipped ({took})")
for f in s.get("testFailures", []):
    print(f"  ✘ {f['testIdentifierString']}: {f['failureText'][:200]}")
PY
fi
if [ -n "${LA_CARTE_RENDER_DIR:-}" ]; then echo "Renders: $LA_CARTE_RENDER_DIR"; fi
exit "$STATUS"
