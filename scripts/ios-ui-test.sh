#!/usr/bin/env bash
# UI / end-to-end tests (XCUITest) + screenshot export.
#
#   scripts/ios-ui-test.sh [--record] [run-name] [--smoke] [-only-testing:LaCarteUITests/LaCarteUITests/testX ...]
#
# --smoke: only the SMOKE tests below (one per screen/flow, for PR feedback).
# --record (or UI_RECORD=1): keep Xcode's screen recordings of passing tests too (default: failed tests only), in
# qa/screenshots/<run-name>/recordings/; the run ends with their count and size.
# Screenshots (XCTAttachments named in the tests) land in qa/screenshots/<run-name>/.
# Builds under the app's DerivedData lock into a private copy of the test products, then tests that copy
# on the first free UI simulator of a pool (scripts/_sim-pool.sh), so other builds and UI runs go meanwhile
# (docs/dev-velocity.md).
# UI_WORKERS=N>1 (default 1) runs as `--split N` over warm pool simulators; Xcode's own parallel clones are never
# used (they boot cold and crash PosterBoard, one macOS crash pop-up each).
# Extra env forwarded to the test runner: LA_CARTE_API_URL, LA_CARTE_API_TOKEN (see scripts/e2e.sh).
# Each finished test prints as it finishes (also into a file), then a `TESTS: …` summary line.
# If the simulator refuses the test runner before any test ran ("preflight checks … Busy"), the test step runs once
# more after UI_INFRA_RETRY_WAIT s (scripts/_ui-retry.sh): `infra-retry: yes` in the TESTS line, or
# `TESTS: infra failure (simulator refused the runner)` if refused again.
# Exit code = xcodebuild's (65 test failure, 75 lock timeout); export/summary/contact-sheet failures only warn.
set -euo pipefail
REST=(); for a in "$@"; do if [ "$a" = --record ]; then export UI_RECORD=1; else REST+=("$a"); fi; done
set -- ${REST[@]+"${REST[@]}"}
if [ "${1:-}" = --split ]; then  # --split [N] [--wait] <run> …: one run over several pool simulators (ios-ui-test-split.sh)
  exec "$(dirname "$0")/ios-ui-test-split.sh" "$@"
fi
source "$(dirname "$0")/_ios-env.sh"
source "$(dirname "$0")/_ui-retry.sh"
RUN="${1:-$(date +%Y%m%d-%H%M%S)}"; shift || true
SMOKE=(
  StudyUITests/testStudy_frontRevealRateNext
  DeckUITests/testDeck_addFromDeck
  SetupUITests/testSetup_connectFromStudy
  ThemeUITests/testTheme_forcedSchemesAndBackToSystem
  RefreshUITests/testStudy_foregroundReload
  LaCarteUITests/testDesignSystem_tapEachButton
)
ARGS=()
for a in "$@"; do
  if [ "$a" = --smoke ]; then for t in "${SMOKE[@]}"; do ARGS+=("-only-testing:LaCarteUITests/$t"); done
  else ARGS+=("$a"); fi
done
if [ "$UI_WORKERS" -gt 1 ]; then  # full parallel run = split over the warm pool; the split falls back here with 1
  UI_WORKERS=1 exec "$ROOT/scripts/ios-ui-test-split.sh" "$UI_WORKERS" "$RUN" ${ARGS[@]+"${ARGS[@]}"}
fi
OUT="$ROOT/qa/screenshots/$RUN"
RESULT="$RESULTS_DIR/$RUN.xcresult"   # qa/.results, or $LA_CARTE_SCRATCH/qa-results/<checkout>
# UI_TEST_PRODUCTS=<dir>.xctestproducts: test these prebuilt products, no build (CI builds once: ci/build-ui-tests.sh).
PREBUILT="${UI_TEST_PRODUCTS:-}"
OWN="$RESULTS_DIR/$RUN.xctestproducts"  # this run's own app + runner (or --record's copy of the prebuilt); removed on exit
PRODUCTS="${PREBUILT:-$OWN}"
trap 'rm -rf "$OWN"' EXIT; rm -rf "$OWN"
rm -rf "$OUT" "$RESULT"; mkdir -p "$OUT" "$(dirname "$RESULT")"

cd "$ROOT/ios"
# Keeps errors plus located notes: an error inside #expect/#require points at the test file only in its note.
FILTER="Test [Cc]ase .*(passed|failed|skipped)|error:|preflight checks|\.swift:[0-9]+:[0-9]+: note:|TEST( EXECUTE)? (SUCCEEDED|FAILED)|^🔒"
export NSUnbufferedIO=YES  # xcodebuild writes each line as it happens, even into a pipe
set +e
# 1. Build under the app's DerivedData lock, copying the products out so a later build can't replace them.
[ -n "$PREBUILT" ] || "$LOCK" "$APP_BUILD_LOCK" $BUILD_SLOT xcodebuild build-for-testing $BUILD_JOBS_FLAGS -project LaCarte.xcodeproj -scheme LaCarte \
  -destination "$DESTINATION" -skipMacroValidation -testProductsPath "$PRODUCTS" -quiet 2>&1 | grep --line-buffered -E "$FILTER"
STATUS=${PIPESTATUS[0]}
# --record: keep every test's attachments, set in this run's products only (a prebuilt copy is cloned first).
if [ "$STATUS" -eq 0 ] && [ -n "$UI_RECORD" ]; then
  if [ "$PRODUCTS" != "$OWN" ]; then
    cp -cR "$PRODUCTS" "$OWN" 2>/dev/null || { rm -rf "$OWN"; cp -R "$PRODUCTS" "$OWN"; }  # APFS clone: no extra disk
    PRODUCTS="$OWN"
  fi
  ui_keep_recordings "$PRODUCTS" || { echo "TESTS: none run (--record: could not keep the recordings)"; exit 1; }
fi
# 2. Test the copy on the first free UI simulator ($POOL_DESTINATION), under its lock only.
# Serial run: classes in alphabetical order, which e2e.sh's live tests rely on (parallel testing
# reorders classes even with a single worker).
PARALLEL=(-parallel-testing-enabled NO)
if [ "$STATUS" -eq 0 ]; then
  ui_test_with_retry "$RUN" "$RESULT" env TEST_RUNNER_LA_CARTE_API_URL="${LA_CARTE_API_URL:-}" \
    TEST_RUNNER_LA_CARTE_API_TOKEN="${LA_CARTE_API_TOKEN:-}" \
    SIM_POOL=ui "$ROOT/scripts/_sim-pool.sh" /bin/sh -c 'exec xcodebuild test-without-building -destination "$POOL_DESTINATION" "$@"' \
    sh -testProductsPath "$PRODUCTS" "${PARALLEL[@]}" \
    -collect-test-diagnostics never -resultBundlePath "$RESULT" ${ARGS[@]+"${ARGS[@]}"} \
    | grep --line-buffered -E "$FILTER"
  STATUS=${PIPESTATUS[0]}
fi
set -e
warn() { echo "⚠️  $1 failed (exit code unchanged: $STATUS)" >&2; }
INFRA="$(cat "$RESULT.infra" 2>/dev/null || true)"; rm -f "$RESULT.infra"  # scripts/_ui-retry.sh: retried / refused
if [ "$INFRA" = refused ]; then echo "TESTS: infra failure (simulator refused the runner)"; exit "$STATUS"; fi
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
            dest = os.path.join(out, "recordings", test_name + ext)
            if os.path.exists(dest):  # same test name in another class: "<Class>-<test>.mp4"
                dest = os.path.join(out, "recordings", re.sub(r"\W", "", test["testIdentifier"].split("/")[-2]) + "-" + test_name + ext)
            os.rename(src, dest)
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
ui_recordings_summary "$OUT"
# TESTS: 69 passed, 0 failed, 6 skipped (49.3 min[, infra-retry: yes]), then one line per failed test.
python3 -I - "$(xcrun xcresulttool get test-results summary --path "$RESULT")" "$STATUS" "$INFRA" 2>/dev/null <<'PY' || warn "summary"
import json, sys
s = json.loads(sys.argv[1])
t = s["finishTime"] - s["startTime"]
took = f"{t / 60:.1f} min" if t >= 120 else f"{t:.1f} s"
took += ", infra-retry: yes" if sys.argv[3] == "retried" else ""
if s["totalTestCount"] == 0:
    print(f"TESTS: none run (exit {sys.argv[2]}: build failed or no test matched)")
else:
    print(f"TESTS: {s['passedTests']} passed, {s['failedTests']} failed, {s['skippedTests']} skipped ({took})")
for f in s.get("testFailures", []):
    print(f"  ✘ {f['testIdentifierString']}: {f['failureText'][:200]}")
PY
exit "$STATUS"
