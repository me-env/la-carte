#!/usr/bin/env bash
# UI / end-to-end tests (XCUITest) + screenshot export.
#
#   scripts/ios-ui-test.sh [run-name] [-only-testing:LaCarteUITests/LaCarteUITests/testX ...]
#
# Screenshots (XCTAttachments named in the tests) land in qa/screenshots/<run-name>/.
# Builds under the app's DerivedData lock into a private copy of the test products, then tests that copy
# on the first free UI simulator of a pool (scripts/_sim-pool.sh), so other builds and UI runs go meanwhile
# (docs/dev-velocity.md).
# Extra env forwarded to the test runner: LA_CARTE_API_URL, LA_CARTE_API_TOKEN (see scripts/e2e.sh).
# Each finished test prints as it finishes (also into a file), then a `TESTS: …` summary line.
# Exit code = xcodebuild's (65 test failure, 75 lock timeout); export/summary/contact-sheet failures only warn.
set -euo pipefail
source "$(dirname "$0")/_ios-env.sh"
RUN="${1:-$(date +%Y%m%d-%H%M%S)}"; shift || true
OUT="$ROOT/qa/screenshots/$RUN"
RESULT="$RESULTS_DIR/$RUN.xcresult"   # qa/.results, or $LA_CARTE_SCRATCH/qa-results/<checkout>
PRODUCTS="$RESULTS_DIR/$RUN.xctestproducts"  # this run's own app + runner; removed on exit
trap 'rm -rf "$PRODUCTS"' EXIT
rm -rf "$OUT" "$RESULT" "$PRODUCTS"; mkdir -p "$OUT" "$(dirname "$RESULT")"

cd "$ROOT/ios"
FILTER="Test [Cc]ase .*(passed|failed|skipped)|error:|TEST( EXECUTE)? (SUCCEEDED|FAILED)|^🔒"
export NSUnbufferedIO=YES  # xcodebuild writes each line as it happens, even into a pipe
set +e
# 1. Build under the app's DerivedData lock, copying the products out so a later build can't replace them.
"$LOCK" "$APP_BUILD_LOCK" xcodebuild build-for-testing -project LaCarte.xcodeproj -scheme LaCarte \
  -destination "$DESTINATION" -skipMacroValidation -testProductsPath "$PRODUCTS" -quiet 2>&1 | grep --line-buffered -E "$FILTER"
STATUS=${PIPESTATUS[0]}
# 2. Test the copy on the first free UI simulator ($POOL_DESTINATION), under its lock only.
if [ "$STATUS" -eq 0 ]; then
  TEST_RUNNER_LA_CARTE_API_URL="${LA_CARTE_API_URL:-}" \
  TEST_RUNNER_LA_CARTE_API_TOKEN="${LA_CARTE_API_TOKEN:-}" \
  SIM_POOL=ui "$ROOT/scripts/_sim-pool.sh" /bin/sh -c 'exec xcodebuild test-without-building -destination "$POOL_DESTINATION" "$@"' \
    sh -testProductsPath "$PRODUCTS" -collect-test-diagnostics never -resultBundlePath "$RESULT" "$@" 2>&1 \
    | grep --line-buffered -E "$FILTER"
  STATUS=${PIPESTATUS[0]}
fi
set -e
warn() { echo "⚠️  $1 failed (exit code unchanged: $STATUS)" >&2; }
if [ ! -d "$RESULT" ]; then echo "TESTS: none run (exit $STATUS: build failed or lock timeout)"; exit "$STATUS"; fi

xcrun xcresulttool export attachments --path "$RESULT" --output-path "$OUT" >/dev/null || warn "screenshot export"
# Screenshots → <name>-<light|dark>.png; Xcode's screen recordings → recordings/<test>.mp4
python3 -I - "$OUT" <<'PY' || warn "screenshot rename"
import json, os, re, sys
out = sys.argv[1]
manifest = os.path.join(out, "manifest.json")
for test in json.load(open(manifest)) if os.path.exists(manifest) else []:
    test_name = re.sub(r"\W", "", test["testIdentifier"].split("/")[-1])
    for a in test.get("attachments", []):
        src = os.path.join(out, a["exportedFileName"])
        ext = os.path.splitext(src)[1]
        name = os.path.splitext(a["suggestedHumanReadableName"])[0]
        if name.startswith("Screen Recording"):  # Xcode records each UI test
            os.makedirs(os.path.join(out, "recordings"), exist_ok=True)
            os.rename(src, os.path.join(out, "recordings", test_name + ext))
        else:  # "home-dark_0_<UUID>" → "home-dark"
            os.rename(src, os.path.join(out, re.sub(r"_\d+_[0-9A-F-]{36}$", "", name) + ext))
if os.path.exists(manifest):
    os.remove(manifest)
PY
if [ -f "$ROOT/scripts/contact-sheet.py" ] && command -v uv >/dev/null; then
  uv run "$ROOT/scripts/contact-sheet.py" "$OUT" || warn "contact sheet"  # → $OUT/contact-sheet.png
fi
echo "📸 screenshots: $OUT  (xcresult: $RESULT)"
ls -R "$OUT" || true
# TESTS: 69 passed, 0 failed, 6 skipped (49.3 min), then one line per failed test.
python3 -I - "$(xcrun xcresulttool get test-results summary --path "$RESULT")" "$STATUS" 2>/dev/null <<'PY' || warn "summary"
import json, sys
s = json.loads(sys.argv[1])
t = s["finishTime"] - s["startTime"]
took = f"{t / 60:.1f} min" if t >= 120 else f"{t:.1f} s"
if s["totalTestCount"] == 0:
    print(f"TESTS: none run (exit {sys.argv[2]}: build failed or no test matched)")
else:
    print(f"TESTS: {s['passedTests']} passed, {s['failedTests']} failed, {s['skippedTests']} skipped ({took})")
for f in s.get("testFailures", []):
    print(f"  ✘ {f['testIdentifierString']}: {f['failureText'][:200]}")
PY
exit "$STATUS"
