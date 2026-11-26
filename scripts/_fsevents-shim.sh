# Sourced by _ios-env.sh. Local only: when fseventsd is hung, run xcodebuild through a shim that skips FSEvents.
# "Hung builds" in docs/dev-velocity.md.
#
# Why: once fseventsd is stuck in state U (only a reboot fixes it), every FSEventStreamStart blocks forever in
# f2d_register_rpc. xcodebuild starts one per local Swift package while it opens the project (IDESwiftPackage
# file watcher: LaCarteKit), so it hangs at 0% CPU before printing anything. Package flags don't avoid it.
# Shim: a copy of xcodebuild, ad-hoc signed (Apple's has library validation, which ignores DYLD_INSERT_LIBRARIES),
# with a tiny dylib whose FSEventStreamStart/Stop do nothing. xcodebuild only loses its file watchers, which a
# one-shot command-line build never needs. The dylib drops DYLD_INSERT_LIBRARIES once loaded, so no child inherits it.
# Limit: the shim can't run tests. Simulators only talk to an xcodebuild holding Apple's private entitlements
# (DTServiceHub "failed to bless service hub"; an ad-hoc copy with them is killed at launch). So the wrapper hands
# test-without-building (and -exportArchive), which open no project, to Apple's xcodebuild, and refuses plain `test`:
# ios-test.sh then runs build-for-testing + test-without-building, as ios-ui-test.sh always does.
# Built once per Xcode into /tmp (~100 KB). Off with LA_CARTE_FSEVENTS_SHIM=0; forced on with =1.

fseventsd_hung() { ps -axo stat=,comm= | awk '$2 ~ /\/fseventsd$/ && $1 ~ /^U/ { f = 1 } END { exit !f }'; }

fsevents_shim_build() {  # prints the shim dir (contains an `xcodebuild` wrapper)
  local dev real key dir tmp
  dev="${DEVELOPER_DIR:-$(xcode-select -p)}"; real="$dev/usr/bin/xcodebuild"
  key="$(cksum <"$real" | cut -d' ' -f1)"
  dir="/tmp/la-carte-fsevents-shim/v2-$key"  # bump v<n> when this function changes
  if [ ! -x "$dir/xcodebuild" ]; then
    tmp="$(mktemp -d /tmp/la-carte-fsevents-shim.XXXXXX)"
    cat >"$tmp/nofse.c" <<'C'
#include <CoreServices/CoreServices.h>
#include <stdlib.h>
#define INTERPOSE(r, e) __attribute__((used)) static struct { const void *r_; const void *e_; } i_##e \
  __attribute__((section("__DATA,__interpose"))) = { (const void *)&r, (const void *)&e };
static Boolean start(FSEventStreamRef s) { (void)s; return true; }
static void stop(FSEventStreamRef s) { (void)s; }
INTERPOSE(start, FSEventStreamStart)
INTERPOSE(stop, FSEventStreamStop)
__attribute__((constructor)) static void init(void) { unsetenv("DYLD_INSERT_LIBRARIES"); }
C
    cp "$real" "$tmp/xcodebuild.bin"
    # Its rpaths are relative to its own location (@executable_path/../../..): point them at the real Xcode.
    local r
    for r in "" /Frameworks /SharedFrameworks; do
      install_name_tool -rpath "@executable_path/../../..$r" "${dev%/Developer}$r" "$tmp/xcodebuild.bin" 2>/dev/null
    done
    /usr/bin/clang -dynamiclib -framework CoreServices -o "$tmp/nofse.dylib" "$tmp/nofse.c" \
      && codesign -s - -f "$tmp/xcodebuild.bin" 2>/dev/null && codesign -s - -f "$tmp/nofse.dylib" 2>/dev/null \
      || { rm -rf "$tmp"; return 1; }
    cat >"$tmp/xcodebuild" <<SH
#!/bin/sh
# fseventsd shim (scripts/_fsevents-shim.sh). Running tests needs Apple's own xcodebuild (see there).
for a in "\$@"; do
  case "\$a" in
    test-without-building|-exportArchive) exec "$real" "\$@" ;;
    test) echo "❌ fseventsd is hung: 'xcodebuild test' can't run (shim can't reach the simulator, Apple's xcodebuild hangs). Use build-for-testing, then test-without-building ('Hung builds' in docs/dev-velocity.md)" >&2; exit 69 ;;
  esac
done
DEVELOPER_DIR="$dev" DYLD_INSERT_LIBRARIES="$dir/nofse.dylib" exec "$dir/xcodebuild.bin" "\$@"
SH
    chmod +x "$tmp/xcodebuild"
    mkdir -p "$(dirname "$dir")"
    if [ -e "$dir" ]; then rm -rf "$tmp"; else mv "$tmp" "$dir"; fi  # another script won the race: use theirs
  fi
  echo "$dir"
}

if [ -z "${CI:-}" ] && { [ "${LA_CARTE_FSEVENTS_SHIM:-}" = 1 ] || { [ "${LA_CARTE_FSEVENTS_SHIM:-}" != 0 ] && fseventsd_hung; }; }; then
  if FSEVENTS_SHIM_DIR="$(fsevents_shim_build)"; then
    case ":$PATH:" in *":$FSEVENTS_SHIM_DIR:"*) ;; *) PATH="$FSEVENTS_SHIM_DIR:$PATH"; export PATH ;; esac
    export FSEVENTS_SHIM_DIR
  else
    echo "⚠️  fseventsd is hung and the xcodebuild shim failed to build: builds will likely stall ('Hung builds' in docs/dev-velocity.md)" >&2
  fi
fi
