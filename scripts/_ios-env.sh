# Shared iOS settings. Override with env vars, e.g. SIMULATOR="iPhone 17" OS=27.0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIMULATOR="${SIMULATOR:-iPhone 17 Pro}"
OS="${OS:-latest}"
DESTINATION="platform=iOS Simulator,name=$SIMULATOR,OS=$OS"
# Unit tests get their own simulator so they never wait behind a UI suite (docs/dev-velocity.md).
# CI boots only $SIMULATOR, so it keeps using that one.
if [ -n "${CI:-}" ]; then UNIT_SIMULATOR="${UNIT_SIMULATOR:-$SIMULATOR}"; else UNIT_SIMULATOR="${UNIT_SIMULATOR:-iPhone 17}"; fi
UNIT_DESTINATION="platform=iOS Simulator,name=$UNIT_SIMULATOR,OS=$OS"
# Unit tests take the first free device of a small pool (scripts/_sim-pool.sh): slot 1 is $UNIT_SIMULATOR, slots 2..N
# are "la-carte-unit-<n>" clones created on first use. 1 = no pool (CI boots only one simulator).
if [ -n "${CI:-}" ]; then UNIT_POOL_SIZE="${UNIT_POOL_SIZE:-1}"; else UNIT_POOL_SIZE="${UNIT_POOL_SIZE:-3}"; fi
# UI tests (ios-ui-test.sh, e2e.sh) take the first free device of their own pool: slot 1 is $SIMULATOR, slots 2..N
# are "la-carte-ui-<n>", same model and runtime, so screenshots stay pixel-identical. 1 = no pool (CI).
if [ -n "${CI:-}" ]; then UI_POOL_SIZE="${UI_POOL_SIZE:-1}"; else UI_POOL_SIZE="${UI_POOL_SIZE:-5}"; fi
# Parallel-testing workers inside one UI run. Each worker is one more simulator (Xcode clones it), so the default is 1;
# raise it only when UI slots are idle. Budget: about 8 booted simulators in all (docs/dev-velocity.md).
UI_WORKERS="${UI_WORKERS:-1}"

# Locks (scripts/_lock.sh, rules in docs/dev-velocity.md). Always take the DerivedData lock before the
# simulator lock, so two scripts can never deadlock. DerivedData is per checkout (Xcode hashes the path).
LOCK="$ROOT/scripts/_lock.sh"
CHECKOUT_ID="$(printf %s "$ROOT" | cksum | cut -d' ' -f1)"
APP_BUILD_LOCK="build-LaCarte-$CHECKOUT_ID"        # ios/LaCarte.xcodeproj DerivedData (app + UI tests)
KIT_BUILD_LOCK="build-LaCarteKit-$CHECKOUT_ID"     # ios/LaCarteKit DerivedData (unit tests)
# Simulator locks are global (all checkouts and worktrees share the devices), keyed on name + OS. An explicit
# OS equal to the newest iOS runtime is the same device as "latest", so it gets the same lock name.
LOCK_OS="$OS"
if [ "$OS" != latest ] && [ "$OS" = "$(xcrun simctl list runtimes 2>/dev/null | sed -n 's/^iOS \([0-9.]*\) .*/\1/p' | sort -t. -k1,1n -k2,2n | tail -1)" ]; then
  LOCK_OS=latest
fi
SIM_LOCK="sim-${SIMULATOR// /-}-$LOCK_OS"
UNIT_SIM_LOCK="sim-${UNIT_SIMULATOR// /-}-$LOCK_OS"   # same name as SIM_LOCK when both are one device

# Machine-wide build cap: at most BUILD_SLOTS xcodebuild build / build-for-testing steps at once, across ALL checkouts
# and worktrees (lock dir LOCK_DIR, default /tmp/la-carte-locks). Each build gets cores / BUILD_SLOTS jobs.
# Wrap a build as: "$BUILD_SLOT" xcodebuild build ... $BUILD_JOBS_FLAGS   (docs/dev-velocity.md)
BUILD_SLOTS="${BUILD_SLOTS:-2}"
BUILD_JOBS="${BUILD_JOBS:-$(( $(sysctl -n hw.ncpu 2>/dev/null || echo 4) / BUILD_SLOTS ))}"
[ "$BUILD_JOBS" -ge 1 ] || BUILD_JOBS=1
BUILD_JOBS_FLAGS="-jobs $BUILD_JOBS"
BUILD_SLOT="$ROOT/scripts/_lock.sh --slots $BUILD_SLOTS xcodebuild-slot"  # unquoted on purpose: expands to 4 words
export BUILD_SLOT BUILD_JOBS_FLAGS

# Big, regenerable outputs (xcresults now; per-agent DerivedData/worktrees later) go to $LA_CARTE_SCRATCH, e.g. an
# external SSD. Set it per machine in scripts/.local.env (gitignored, never read on CI). If its volume isn't
# mounted, everything falls back to the in-repo paths.
# A git worktree reads the main checkout's .local.env; results are kept per checkout so worktrees never collide.
MAIN_ROOT="$(cd "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "$ROOT/.git")/.." && pwd)"
for f in "$ROOT/scripts/.local.env" "$MAIN_ROOT/scripts/.local.env"; do
  if [ -z "${CI:-}" ] && [ -f "$f" ]; then source "$f"; break; fi
done
if [ -n "${LA_CARTE_SCRATCH:-}" ] && [ -d "$(dirname "$LA_CARTE_SCRATCH")" ] && mkdir -p "$LA_CARTE_SCRATCH" 2>/dev/null; then
  RESULTS_DIR="$LA_CARTE_SCRATCH/qa-results/$(basename "$ROOT")-$CHECKOUT_ID"
else
  LA_CARTE_SCRATCH=""
  RESULTS_DIR="$ROOT/qa/.results"
fi
