#!/usr/bin/env bash
# CI only: run a UI test command (scripts/ios-ui-test.sh or scripts/e2e.sh) and retry it once when no test ran
# at all from prebuilt products (UI_TEST_PRODUCTS, so no build to blame). A refused runner ("preflight checks …
# Busy") is retried inside the scripts themselves (scripts/_ui-retry.sh), never here: their logs mention it even
# when the retry then ran and a test really failed. A test failure is never retried (docs/ci-cd.md).
#
#   ci/ui-test.sh scripts/ios-ui-test.sh ci-deck -only-testing:…
set -uo pipefail
LOG="${RUNNER_TEMP:-/tmp}/ui-test-$$.log"
infra() { [ -n "${UI_TEST_PRODUCTS:-}" ] && grep -q "^TESTS: none run" "$LOG"; }
"$@" 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
if [ "$STATUS" -ne 0 ] && infra; then
  echo "::warning title=CI infra (not a test failure)::prebuilt products ran no test; retrying once"
  sleep 30
  "$@"
  STATUS=$?
fi
exit "$STATUS"
