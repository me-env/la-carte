#!/usr/bin/env bash
# Unit tests: every feature/client in LaCarteKit (TCA TestStore + Swift Testing). `LaCarteKit-Package` is the
# scheme SwiftPM generates once the package has more than one product (AppFeature, DeckWidget).
# Own DerivedData (LaCarteKit package) and own simulator ($UNIT_SIMULATOR), so it never waits behind an app
# build or a UI suite; only behind another unit-test run.
# --render (or LA_CARTE_RENDER_DIR=dir) also writes logo + gallery PNGs (DesignSystemTests/RenderTests).
# Other args go to xcodebuild, e.g. scripts/ios-test.sh --render -only-testing:DesignSystemTests/RenderTests
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
cd "$ROOT/ios/LaCarteKit"
set +e
"$LOCK" "$KIT_BUILD_LOCK" "$LOCK" "$UNIT_SIM_LOCK" \
  xcodebuild test -scheme LaCarteKit-Package -destination "$UNIT_DESTINATION" -skipMacroValidation ${ARGS[@]+"${ARGS[@]}"} 2>&1 \
  | grep -E "^(✔|✘|🔒)|error:|TEST (SUCCEEDED|FAILED)"
STATUS=${PIPESTATUS[0]}
set -e
if [ -n "${LA_CARTE_RENDER_DIR:-}" ]; then echo "Renders: $LA_CARTE_RENDER_DIR"; fi
exit "$STATUS"
