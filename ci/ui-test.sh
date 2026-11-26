#!/usr/bin/env bash
# CI only: run a UI test command (scripts/ios-ui-test.sh or scripts/e2e.sh) and retry it once when no test ran
# at all from prebuilt products (UI_TEST_PRODUCTS, so no build to blame). A refused runner ("preflight checks …
# Busy") is retried inside the scripts themselves (scripts/_ui-retry.sh), never here: their logs mention it even
# when the retry then ran and a test really failed. Test failures: only the full-suite shards retry them
# (xcodebuild -retry-tests-on-failure, set in ci.yml); this script flags each test that passed only on retry.
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
# Tests that failed, then passed on a retry (-retry-tests-on-failure): green, but listed for their owner.
grep -oE "Test Case '-\[LaCarteUITests\.[A-Za-z0-9_]+ [A-Za-z0-9_]+\]' failed" "$LOG" | sort -u | while read -r line; do
  t=$(sed -E "s/.*\.([A-Za-z0-9_]+) ([A-Za-z0-9_]+)\].*/\1\/\2/" <<<"$line")
  grep -qE "Test Case '-\[LaCarteUITests\.${t%/*} ${t#*/}\]' passed" "$LOG" \
    && echo "::warning title=Flaky UI test (passed on retry)::$t — owner qa-validator, see docs/ci-cd.md → Flaky tests"
done
exit "$STATUS"
