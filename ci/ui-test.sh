#!/usr/bin/env bash
# CI only: run a UI test command (scripts/ios-ui-test.sh or scripts/e2e.sh) and retry it once when the simulator,
# not a test, failed: the runner could not be launched ("Application failed preflight checks … Busy" on a freshly
# booted simulator), or no test ran at all from prebuilt products (UI_TEST_PRODUCTS, so no build to blame).
# A retry is flagged as a warning; a test failure is never retried (flaky tests get fixed, docs/ci-cd.md).
#
#   ci/ui-test.sh scripts/ios-ui-test.sh ci-deck -only-testing:…
set -uo pipefail
LOG="${RUNNER_TEMP:-/tmp}/ui-test-$$.log"
infra() {
  grep -qE "preflight checks|reason: Busy" "$LOG" ||
    { [ -n "${UI_TEST_PRODUCTS:-}" ] && grep -q "^TESTS: none run" "$LOG"; }
}
"$@" 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
if [ "$STATUS" -ne 0 ] && infra; then
  echo "::warning title=CI infra (not a test failure)::the simulator refused the test runner; retrying once"
  sleep 30
  "$@"
  STATUS=$?
fi
exit "$STATUS"
