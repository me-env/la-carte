# Shared iOS settings. Override with env vars, e.g. SIMULATOR="iPhone 17" OS=27.0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIMULATOR="${SIMULATOR:-iPhone 17 Pro}"
OS="${OS:-latest}"
DESTINATION="platform=iOS Simulator,name=$SIMULATOR,OS=$OS"
# Unit tests get their own simulator so they never wait behind a UI suite (docs/dev-velocity.md).
# CI boots only $SIMULATOR, so it keeps using that one.
if [ -n "${CI:-}" ]; then UNIT_SIMULATOR="${UNIT_SIMULATOR:-$SIMULATOR}"; else UNIT_SIMULATOR="${UNIT_SIMULATOR:-iPhone 17}"; fi
UNIT_DESTINATION="platform=iOS Simulator,name=$UNIT_SIMULATOR,OS=$OS"

# Locks (scripts/_lock.sh, rules in docs/dev-velocity.md). Always take the DerivedData lock before the
# simulator lock, so two scripts can never deadlock. DerivedData is per checkout (Xcode hashes the path).
LOCK="$ROOT/scripts/_lock.sh"
CHECKOUT_ID="$(printf %s "$ROOT" | cksum | cut -d' ' -f1)"
APP_BUILD_LOCK="build-LaCarte-$CHECKOUT_ID"        # ios/LaCarte.xcodeproj DerivedData (app + UI tests)
KIT_BUILD_LOCK="build-LaCarteKit-$CHECKOUT_ID"     # ios/LaCarteKit DerivedData (unit tests)
SIM_LOCK="sim-${SIMULATOR// /-}-$OS"
UNIT_SIM_LOCK="sim-${UNIT_SIMULATOR// /-}-$OS"   # same name as SIM_LOCK when both are one device

# Big, regenerable outputs (xcresults now; per-agent DerivedData/worktrees later) go to $LA_CARTE_SCRATCH, e.g. an
# external SSD. Set it per machine in scripts/.local.env (gitignored, never read on CI). If its volume isn't
# mounted, everything falls back to the in-repo paths.
if [ -z "${CI:-}" ] && [ -f "$ROOT/scripts/.local.env" ]; then source "$ROOT/scripts/.local.env"; fi
if [ -n "${LA_CARTE_SCRATCH:-}" ] && [ -d "$(dirname "$LA_CARTE_SCRATCH")" ] && mkdir -p "$LA_CARTE_SCRATCH" 2>/dev/null; then
  RESULTS_DIR="$LA_CARTE_SCRATCH/qa-results"
else
  LA_CARTE_SCRATCH=""
  RESULTS_DIR="$ROOT/qa/.results"
fi
