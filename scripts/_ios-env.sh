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
# A pool device grown past this many GB is erased (and booted once) when a run releases it (_sim-pool.sh).
SIM_TRIM_GB="${SIM_TRIM_GB:-8}"

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
# SDK_STAT_CACHE_ENABLE=NO: clang-stat-cache reuses its cache by replaying FSEvents history and waits forever (0% CPU)
# when fseventsd is stuck; it only saves clang a few stat()s. See "Hung builds" in docs/dev-velocity.md.
BUILD_JOBS_FLAGS="-jobs $BUILD_JOBS SDK_STAT_CACHE_ENABLE=NO"
BUILD_SLOT="$ROOT/scripts/_lock.sh --slots $BUILD_SLOTS xcodebuild-slot"  # unquoted on purpose: expands to 4 words
export BUILD_SLOT BUILD_JOBS_FLAGS
# fseventsd hung (state U)? xcodebuild then runs through a shim that skips FSEvents (local only, see that file).
source "$ROOT/scripts/_fsevents-shim.sh"

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

# Simulator devices on another volume (docs/dev-velocity.md): set LA_CARTE_SIM_DEVICES in scripts/.local.env. Each device
# is an APFS disk image there, <UDID>.sparsebundle, mounted AT its own folder ~/Library/Developer/CoreSimulator/Devices/<UDID>.
# Not a symlink: through a link the simulator sees one folder under two paths, and a preference written through one
# (XCUIDevice.appearance, by testmanagerd) never reaches the process reading the other (SpringBoard): dark mode stayed
# light. Images are mounted here when missing (after a reboot or replug). Fail fast if that volume isn't mounted,
# rather than let a script recreate devices on the internal disk. Never on CI.
SIM_DEVICES_DIR="$HOME/Library/Developer/CoreSimulator/Devices"
if [ -n "${CI:-}" ]; then LA_CARTE_SIM_DEVICES=""; fi
if [ -n "${LA_CARTE_SIM_DEVICES:-}" ] && ! [ -d "$LA_CARTE_SIM_DEVICES" ]; then
  echo "❌ The simulators live in $LA_CARTE_SIM_DEVICES (LA_CARTE_SIM_DEVICES, scripts/.local.env) and that disk is not mounted. Plug it in and rerun; nothing ran." >&2
  exit 78
fi
sim_mounted() { mount | grep -qF " on $SIM_DEVICES_DIR/$1 ("; }  # <udid>
sim_attach() {  # <udid>: mount its image at its device folder (no-op if mounted)
  sim_mounted "$1" && return 0
  mkdir -p "$SIM_DEVICES_DIR/$1"
  hdiutil attach -quiet -nobrowse -owners on -mountpoint "$SIM_DEVICES_DIR/$1" "$LA_CARTE_SIM_DEVICES/$1.sparsebundle"
}
if [ -n "${LA_CARTE_SIM_DEVICES:-}" ]; then
  MOUNTS="$(mount)"
  for img in "$LA_CARTE_SIM_DEVICES"/*.sparsebundle; do
    [ -d "$img" ] || continue
    u="$(basename "$img" .sparsebundle)"
    case "$MOUNTS" in *" on $SIM_DEVICES_DIR/$u ("*) ;; *) sim_attach "$u" || echo "⚠️  could not mount $img" >&2 ;; esac
  done
  unset MOUNTS img u
  # After a reboot CoreSimulatorService may have started before the images were mounted and list none of them:
  # restart it once if nothing uses it (scripts/_sim-service.sh).
  LA_CARTE_SIM_DEVICES="$LA_CARTE_SIM_DEVICES" SIM_DEVICES_DIR="$SIM_DEVICES_DIR" "$ROOT/scripts/_sim-service.sh" || true
fi
# Move a device (local folder, or an older symlink to LA_CARTE_SIM_DEVICES/<UDID>) into a new image mounted at its
# device folder, then erase it: its databases (LaunchServices, containers) hold absolute paths to the old folder, and
# would keep writing app data there. Only device.plist is kept. Call it while holding the device's lock.
sim_to_image() {  # <udid>
  local dev="$SIM_DEVICES_DIR/$1" img="$LA_CARTE_SIM_DEVICES/$1.sparsebundle" src
  sim_mounted "$1" && return 0
  xcrun simctl shutdown "$1" >/dev/null 2>&1 || true
  if [ -L "$dev" ]; then src="$(readlink "$dev")"; else src="$SIM_DEVICES_DIR/../$1.moving"; mv "$dev" "$src"; fi
  case "$src" in "$LA_CARTE_SIM_DEVICES/$1"|"$SIM_DEVICES_DIR/../$1.moving") ;; *) echo "⚠️  $dev -> $src: not ours, left alone" >&2; return 1 ;; esac
  hdiutil create -quiet -type SPARSEBUNDLE -fs APFS -size 100g -volname "sim-$1" "$img" || return 1
  rm -f "$dev"; mkdir "$dev"
  sim_attach "$1" && cp "$src/device.plist" "$dev/" && xcrun simctl erase "$1" && rm -rf "$src"
}
sim_named() {  # <runtime id> <name>: UDIDs of the available devices with that name, sorted (one per line)
  xcrun simctl list devices -j | python3 -I -c '
import json, sys
devices = json.load(sys.stdin)["devices"].get(sys.argv[1], [])
print("\n".join(sorted(d["udid"] for d in devices if d["name"] == sys.argv[2] and d["isAvailable"])))' "$1" "$2"
}
# Create a simulator (prints its UDID), move it into its image on LA_CARTE_SIM_DEVICES (if set) and boot it once, so
# its first-boot work happens now and not in a test run. Call it while holding the device's lock.
sim_create() {  # <name> <device type> <runtime id>
  local udid
  # The service doesn't list some mounted images yet (it started before they were mounted): the device may exist
  # already, and creating it now makes a duplicate whose name stays ambiguous once they are listed (2026-11-28).
  if [ -n "${LA_CARTE_SIM_DEVICES:-}" ] && [ -n "$(LA_CARTE_SIM_DEVICES="$LA_CARTE_SIM_DEVICES" \
      SIM_DEVICES_DIR="$SIM_DEVICES_DIR" "$ROOT/scripts/_sim-service.sh" --missing)" ]; then
    echo "❌ not creating $1: CoreSimulatorService doesn't list some mounted simulator images yet (it started before they were mounted), so $1 may exist already. See the warning above; docs/dev-velocity.md" >&2
    return 1
  fi
  udid="$(xcrun simctl create "$1" "$2" "$3")" || return 1
  if [ -n "${LA_CARTE_SIM_DEVICES:-}" ]; then sim_to_image "$udid" >&2 || return 1; fi
  sim_prewarm "$udid"
  echo "$udid"
}
sim_prewarm() {  # <udid>: boot once, write the appearance preference (sim_appearance_ready), shut down
  xcrun simctl bootstatus "$1" -b >/dev/null 2>&1 || true
  xcrun simctl spawn "$1" defaults write com.apple.uikitservices.userInterfaceStyleMode UserInterfaceStyleMode -int 1 \
    >/dev/null 2>&1 || true
  xcrun simctl shutdown "$1" >/dev/null 2>&1 || true
}
# SpringBoard follows XCUIDevice.appearance only if the appearance preference file existed when it started: on a
# new or erased device it doesn't, and every "dark" screenshot of the first boot renders light (docs/dev-velocity.md).
# Before a run: if the file is missing, write it with one boot and shut down, so the run's boot starts with it.
sim_appearance_ready() {  # <udid>
  [ -f "$SIM_DEVICES_DIR/$1/data/Library/Preferences/com.apple.uikitservices.userInterfaceStyleMode.plist" ] && return 0
  echo "🌗 $1: writing the appearance preference first (one boot, ~30 s)" >&2
  sim_prewarm "$1"
}
# A device whose audio route can never be prepared (docs/dev-velocity.md, "Stuck simulator audio"): the host's one
# SimAudioProcessorService has a read of this device's audio plist that never returns. Every launch on it then fails
# with "SimAudioProcessorServices failed to create an audio route descriptor" (and leaks one more stuck thread);
# only a reboot clears it. A normal read takes microseconds, so an open handle seen by lsof is a stuck one.
sim_audio_stuck() {  # <udid>
  local pid
  for pid in $({ bounded 5 pgrep -U "$(id -u)" -f 'SimAudioProcessorService.xpc/Contents/MacOS/SimAudioProcessorService' || true; }); do
    { bounded 10 lsof -p "$pid" -Fn || true; } | grep -F "/$1/data/var/run/com.apple.coresimulator.audio.plist" >/dev/null \
      && return 0
  done
  return 1
}
