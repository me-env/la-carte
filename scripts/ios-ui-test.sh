#!/usr/bin/env bash
# UI / end-to-end tests (XCUITest) + screenshot export.
#
#   scripts/ios-ui-test.sh [run-name] [-only-testing:LaCarteUITests/LaCarteUITests/testX ...]
#
# Screenshots (XCTAttachments named in the tests) land in qa/screenshots/<run-name>/.
# Waits for the app's DerivedData lock to build, then the simulator lock to test (docs/dev-velocity.md).
# Extra env forwarded to the test runner: LA_CARTE_API_URL, LA_CARTE_API_TOKEN (see scripts/e2e.sh).
set -euo pipefail
source "$(dirname "$0")/_ios-env.sh"
RUN="${1:-$(date +%Y%m%d-%H%M%S)}"; shift || true
OUT="$ROOT/qa/screenshots/$RUN"
RESULT="$RESULTS_DIR/$RUN.xcresult"   # qa/.results, or $LA_CARTE_SCRATCH/qa-results
rm -rf "$OUT" "$RESULT"; mkdir -p "$OUT" "$(dirname "$RESULT")"

cd "$ROOT/ios"
FILTER="Test Case .*(passed|failed|skipped)|error:|TEST (SUCCEEDED|FAILED)|^🔒"
set +e
# 1. Build under the app's DerivedData lock only (ios-build.sh may run again once this is done).
"$LOCK" "$APP_BUILD_LOCK" xcodebuild build-for-testing -project LaCarte.xcodeproj -scheme LaCarte \
  -destination "$DESTINATION" -skipMacroValidation -quiet 2>&1 | grep -E "$FILTER"
STATUS=${PIPESTATUS[0]}
# 2. Run under the simulator lock only.
if [ "$STATUS" -eq 0 ]; then
  TEST_RUNNER_LA_CARTE_API_URL="${LA_CARTE_API_URL:-}" \
  TEST_RUNNER_LA_CARTE_API_TOKEN="${LA_CARTE_API_TOKEN:-}" \
  "$LOCK" "$SIM_LOCK" xcodebuild test-without-building -project LaCarte.xcodeproj -scheme LaCarte \
    -destination "$DESTINATION" -collect-test-diagnostics never -resultBundlePath "$RESULT" "$@" 2>&1 \
    | grep -E "$FILTER"
  STATUS=${PIPESTATUS[0]}
fi
set -e
[ -d "$RESULT" ] || exit "$STATUS"  # build failed: nothing to export

xcrun xcresulttool export attachments --path "$RESULT" --output-path "$OUT" >/dev/null
# Screenshots → <name>-<light|dark>.png; Xcode's screen recordings → recordings/<test>.mp4
python3 -I - "$OUT" <<'PY'
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
echo "📸 screenshots: $OUT  (xcresult: $RESULT)"
ls -R "$OUT"
exit "$STATUS"
