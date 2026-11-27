#!/usr/bin/env bash
# Renames files and folders under <dir> so actions/upload-artifact accepts them: it rejects the whole upload
# when one path contains " : < > | * ? CR or LF (run 45925206158 lost a shard's screenshots and recordings
# to `Debug description for "NotificationShortLookView" BannerNotification.txt`, an XCUITest attachment).
# Each such character becomes "_"; a name that would collide gets "-2", "-3"… before its extension.
# Usage: ci/artifact-safe-names.sh <dir>   (missing dir: nothing to do)
set -euo pipefail
DIR="${1:?usage: $0 <dir>}"
[ -d "$DIR" ] || exit 0
python3 -I - "$DIR" <<'PY'
import os, re, sys
bad = re.compile(r'[":<>|*?\r\n]')
for parent, dirs, files in os.walk(sys.argv[1], topdown=False):  # children first: renaming a folder last keeps paths valid
    for name in files + dirs:
        safe = bad.sub("_", name)
        if safe == name:
            continue
        stem, ext = os.path.splitext(safe)
        dest, n = os.path.join(parent, safe), 1
        while os.path.lexists(dest):
            n += 1
            dest = os.path.join(parent, f"{stem}-{n}{ext}")
        os.rename(os.path.join(parent, name), dest)
        print(f"renamed for upload: {os.path.join(parent, name)!r} -> {dest}")
PY
