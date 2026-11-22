# UI test helpers shared by ios-ui-test.sh and ios-ui-test-split.sh (sourced, after _ios-env.sh):
# - ui_test_with_retry: the test-without-building step, run once more when the simulator refused the runner
# - ui_keep_recordings / ui_recordings_summary: --record (UI_RECORD=1), Xcode's screen recordings of passing tests too
# - ui_export_logs / ui_logs_summary: the test runner's output (tests' print(), XCTest steps) as plain text in logs/

# Seconds to wait before the infra retry: a just-booted CI simulator needs longer to settle.
if [ -n "${GITHUB_ACTIONS:-}" ]; then UI_INFRA_RETRY_WAIT="${UI_INFRA_RETRY_WAIT:-30}"; else UI_INFRA_RETRY_WAIT="${UI_INFRA_RETRY_WAIT:-10}"; fi
[ "${UI_RECORD:-0}" != 0 ] || UI_RECORD=""

ui_infra_refused() {  # <log> <result.xcresult>: true if the simulator refused the runner and no test ran at all
  grep -qE "preflight checks|reason: Busy" "$1" || return 1
  ! grep -qE "Test [Cc]ase .*(started|passed|failed|skipped)" "$1" || return 1
  [ ! -d "$2" ] || [ "$(xcrun xcresulttool get test-results summary --path "$2" 2>/dev/null \
    | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["totalTestCount"])' 2>/dev/null || echo 0)" = 0 ]
}

# ui_test_with_retry <label> <result.xcresult> <command...>
# Runs the command (a `_sim-pool.sh … xcodebuild test-without-building … -resultBundlePath <result>`), output on stdout.
# If it failed with "preflight checks|reason: Busy" before any test ran (no "Test Case" line, 0 tests in the bundle),
# waits UI_INFRA_RETRY_WAIT s, drops the bundle and runs it once more, on whichever pool slot is free then (no rebuild).
# Writes <result>.infra = "retried" (the retry got the runner going) or "refused" (refused again); returns the exit code.
ui_test_with_retry() {
  local label="$1" result="$2" log="$2.log" s
  shift 2
  rm -f "$result.infra"
  "$@" 2>&1 | tee "$log"; s=${PIPESTATUS[0]}
  if [ "$s" -ne 0 ] && ui_infra_refused "$log" "$result"; then
    echo "⚠️ INFRA: simulator refused the test runner, retrying once ($label)" >&2
    [ -z "${GITHUB_ACTIONS:-}" ] || echo "::warning title=CI infra ($label)::Simulator refused the test runner (preflight checks / Busy) before any test ran; retried once after ${UI_INFRA_RETRY_WAIT}s" >&2
    rm -rf "$result"; sleep "$UI_INFRA_RETRY_WAIT"
    "$@" 2>&1 | tee "$log"; s=${PIPESTATUS[0]}
    if [ "$s" -ne 0 ] && ui_infra_refused "$log" "$result"; then echo refused; else echo retried; fi >"$result.infra"
  fi
  rm -f "$log"
  return "$s"
}

# ui_keep_recordings <products.xctestproducts>: set System/UserAttachmentLifetime = keepAlways on every test target of
# every .xctestrun in these products, so passing tests keep their screen recordings too. Edits only this copy (Xcode
# has no per-run flag for it; the scheme stays deleteOnSuccess). Fails, with a message, if the keys aren't there.
ui_keep_recordings() {
  python3 -I - "$1" <<'PY'
import os, plistlib, sys
products = sys.argv[1]
info = os.path.join(products, "Info.plist")  # {"Tests": [{"xctestrun": "Tests/0/LaCarte.xctestrun", …}]}
runs = [os.path.join(products, t["xctestrun"]) for t in plistlib.load(open(info, "rb")).get("Tests", [])] if os.path.exists(info) else []
if not runs: sys.exit(f"ERROR: --record: no .xctestrun listed in {info}")
for path in runs:
    plist = plistlib.load(open(path, "rb"))
    # format 2: TestConfigurations[].TestTargets[]; format 1: one dict per test target at the top level
    targets = [t for c in plist.get("TestConfigurations", []) for t in c.get("TestTargets", [])] \
        or [v for k, v in plist.items() if isinstance(v, dict) and not k.startswith("__")]
    if not targets or any("SystemAttachmentLifetime" not in t for t in targets):
        sys.exit(f"ERROR: --record: a test target has no SystemAttachmentLifetime in {path}: nothing would be kept")
    for t in targets:
        t["SystemAttachmentLifetime"] = t["UserAttachmentLifetime"] = "keepAlways"
    plistlib.dump(plist, open(path, "wb"))
    print(f"🎬 --record: keeping all attachments of {len(targets)} test target(s) ({os.path.basename(path)})", file=sys.stderr)
PY
}

ui_recordings_summary() {  # <out dir>: count and size of <out>/recordings (disk is user-managed)
  if [ -d "$1/recordings" ]; then
    echo "🎬 recordings: $(find "$1/recordings" -type f | wc -l | tr -d ' ') files, $(du -sh "$1/recordings" | cut -f1) in $1/recordings"
  elif [ -n "$UI_RECORD" ]; then
    echo "⚠️  --record: no screen recording was exported" >&2
  fi
}

# ui_export_logs <result.xcresult> <logs dir> <name>: the runner's output (tests' print(), NSLog, XCTest's "t = …" steps)
# as plain text, read from the bundle's action log (`xcresulttool get log --type action`; its `--type console` log is
# empty for test-without-building runs). Writes <logs>/<name>.txt (each runner process, whole) and appends one
# <logs>/<Class>_<test>.txt per test (sections with testDetails.testName; a retried test gets a second block).
# --split calls it on each shard's bundle (one <k>-console.txt each). Only warns on failure.
ui_export_logs() {
  mkdir -p "$2"
  xcrun xcresulttool get log --type action --compact --path "$1" 2>/dev/null | python3 -I -c '
import datetime, json, os, re, sys
logs, name, bundle = sys.argv[1], sys.argv[2], os.path.basename(sys.argv[3])
def header(s, what):
    t = s.get("startTime")
    when = datetime.datetime.fromtimestamp(t).strftime("%Y-%m-%d %H:%M:%S") if t else "?"
    return f"==== {what} | started {when} | {bundle}\n"
def walk(s, outer):
    d = s.get("testDetails") or {}
    out = d.get("emittedOutput", "")
    if out and outer:  # outermost section with output: one runner process, its whole output
        with open(os.path.join(logs, name + ".txt"), "a") as f: f.write(header(s, s.get("title", "")) + out + "\n")
    if out and d.get("testName"):
        cls, test = re.sub(r"\W", "", d.get("suiteName", "")), re.sub(r"\W", "", d["testName"])
        with open(os.path.join(logs, f"{cls}_{test}.txt"), "a") as f: f.write(header(s, f"{cls}/{test}") + out + "\n")
    for c in s.get("subsections", []): walk(c, outer and not out)
log = sys.stdin.read()
if not log.strip(): sys.exit("no action log in the bundle")
walk(json.loads(log), True)
if not os.path.exists(os.path.join(logs, name + ".txt")): sys.exit("no runner output in the action log")
' "$2" "$3" "$1" || echo "⚠️  log export ($3) failed (exit code unchanged)" >&2
}

ui_logs_summary() {  # <out dir>: where the logs are
  if [ -d "$1/logs" ]; then
    echo "📝 logs: $1/logs  ($(find "$1/logs" -type f | wc -l | tr -d ' ') files, $(du -sh "$1/logs" | cut -f1); <Class>_<test>.txt per test)"
  fi
}
