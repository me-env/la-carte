# Testing

| Layer | Where | Tool | Owner | Run |
|---|---|---|---|---|
| API unit/integration | `api/tests/` | pytest (in-memory SQLite, `TestClient`, MCP in-process `Client`) | api-engineer | `scripts/api-test.sh` |
| Feature logic | `ios/LaCarteKit/Tests/` | Swift Testing + TCA `TestStore` | ios-engineer | `scripts/ios-test.sh` |
| API contract (iOS side) | `Tests/APIClientTests/DecodingTests.swift` | real JSON payloads from the API | ios-engineer + api-engineer | `scripts/ios-test.sh` |
| UI end-to-end (mock) | `ios/LaCarteUITests/` | XCUITest, `LA_CARTE_API=mock` (3 basic cards) or `mock-notes` (notes with several directions + a person, spec 014b) | **qa-validator** | `scripts/ios-ui-test.sh <run>` |
| Full-stack E2E | same, `*_liveAPI` tests | XCUITest against a fresh seeded API | **qa-validator** | `scripts/e2e.sh <run>` |

**Logo renders.** `scripts/ios-test.sh --render -only-testing:DesignSystemTests/RenderTests` (about 15 s) writes
`logo-<light|dark|forest>-p<000|025|050|075|100>.png` (1024 × 1024 px, `ImageRenderer`, on the theme
background) to `$LA_CARTE_SCRATCH/renders` or `build/renders`, or to `LA_CARTE_RENDER_DIR` if you set it. The
suite is skipped in normal runs and on CI. It also writes `gallery-<light|dark|forest>.png` (390 pt wide at 3×):
the gallery's content without its ScrollView (`DesignSystemGalleryContent`), since `ImageRenderer` draws a
ScrollView as empty.

**Study renders.** `scripts/ios-test.sh --render -only-testing:ScreenColorTests/StudyRenders` (about 30 s) draws
the real `StudyView` in a window (`Screen`, 402 × 874 pt at 3×) and writes 44 PNGs to the same folder,
`screen-study-<state>-<theme>-<scheme>.png`: front short / medium / long / overflowing, revealed short and long
answer, rating drag held at ease 0, 0.25, 0.5, 0.76 and 1, editing the back, in light, dark and forest; empty and
done also in system. Liquid Glass is hidden (`layer.render` blanks on it; `drawHierarchy` draws nothing in the test
process), so judge glass on UI-test screenshots. Add a state as one line in `catalogue` in
`ios/LaCarteKit/Tests/ScreenColorTests/StudyRenders.swift`, using only store state.

## Script output and exit codes

- **Live:** `ios-test.sh`, `ios-ui-test.sh` and `e2e.sh` print each test as it finishes, even redirected to a
  file or agent log (`NSUnbufferedIO=YES` + `grep --line-buffered`), plus 🔒 lock lines and `error:` lines.
  `tail -f` the file to follow a long run.
- **Summary:** the last line is `TESTS: 69 passed, 0 failed, 6 skipped (49.3 min)` (from the xcresult), followed by
  one `✘ Class/test(): message` line per failed test. `TESTS: none run (exit N…)` means the build failed or a lock timed out.
- **Infra retry:** if the simulator refuses the test runner before any test ran (`preflight checks` / `reason: Busy`,
  no test result), the test step runs once more without rebuilding, after `UI_INFRA_RETRY_WAIT` s (10; 30 on GitHub
  Actions, plus a `::warning`), on a freshly taken pool slot (it may be the same simulator; `scripts/_ui-retry.sh`, also per `--split` shard and in
  `e2e.sh`). It prints `⚠️ INFRA: …` and adds `infra-retry: yes` to the TESTS line; refused again, the line is
  `TESTS: infra failure (simulator refused the runner)` (exit code still non-zero). A run where any test ran is never retried.
- **Exit code** = xcodebuild's: 0 green, 65 build or test failure, 75 lock timeout. Screenshot export, renaming,
  the summary and the contact sheet only print a ⚠️ warning when they fail. `e2e.sh` exits with `ios-ui-test.sh`'s code.
- **Contact sheet:** when `uv` is on PATH, `ios-ui-test.sh` runs `scripts/contact-sheet.py` on the run's
  screenshots after the export (writes `contact-sheet*.png` into `qa/screenshots/<run>/`).

## UI tests

**UI tests test UI, not logic.** A UI test exists only for what a TestStore/unit test can't see: the screen
renders right (layout, colours, light/dark, accessibility sizes), navigation and gestures work on real UIKit,
and the app wires to the API end to end (a few `_liveAPI` tests). Reducer logic (state changes, API calls made,
errors, debounce, in-flight guards, persistence) is a unit test. Before adding a UI test, ask "could a TestStore
test catch this?" — if yes, write that instead. One UI test per flow, one appearance pass unless the look differs.
**No accessibility tests for now** (user, 2026-11-21): no Dynamic Type / text-size (XL, XXXL, AX5) and no
VoiceOver tests (labels read aloud, custom actions, rotor). Revisit before release. Don't add them, don't block a
verdict on them. Accessibility identifiers stay: they are how UI tests find elements.

- Test names: `test<Screen>_<scenario>` (e.g. `testStudy_revealAndRateGood`). Live-API variants end in `_liveAPI`
  and `XCTSkip` when `LA_CARTE_API_URL` is unset.
- Find elements **only** by accessibility identifier (`<feature>.<element>`), never by visible text or index.
- Mock tests run in **light and dark** (`XCUIDevice.shared.appearance`).
- Call `snapshot("<screen>-<state>", appearance:)` at every state worth reviewing. Names are stable:
  QA compares runs by filename.
- Debug galleries (debug builds only, no network): `LA_CARTE_SCREEN=design-system` (tokens and components),
  `LA_CARTE_SCREEN=widget` (spec 007: every Home Screen widget state in 170 pt tiles, `widgetGallery.title`,
  `widgetGallery.tile.<due|caughtUp|caughtUpLater|empty|unavailable|long>`). Widgets themselves aren't reachable
  from XCUITest. Both follow `-theme forest`.
- Mock data comes from `[Card].fixtures` (`APIClient/InMemoryAPIClient.swift`). Changing fixtures changes
  screenshots — coordinate with qa-validator.

## Splitting a run

`scripts/ios-ui-test.sh --split [N] [--wait] [--record] <run> [-only-testing:LaCarteUITests/<Class>[/<test>] …]` builds once, lists
the tests from the built bundle on a pool simulator (no filter or `-only-testing:LaCarteUITests` = all), deals
the selected test methods into N shards (balanced by the last measured durations in
`<results dir>/ui-test-durations.tsv`, else by count) and runs them at once, one UI pool simulator each. Output is
the same as a plain run: screenshots in `qa/screenshots/<run>/`, one merged `<run>.xcresult`, one `TESTS: …` line
(wall time), exit code non-zero if any shard fails. Shard lines are prefixed `[k]`.
- **Logs:** each shard's (and the retry's) runner output is exported from its own bundle, before the merge:
  `logs/<k>-console.txt`, `logs/retry-console.txt`, plus `logs/<Class>_<test>.txt` per test (see Screenshots).
- **Not run:** a crash can end a shard early. Selected tests with no result in any shard are retried once in one
  extra run (lines `[retry]`); any still missing are counted as `N not run` and listed `⊘ <test>: not run`, and the
  exit code is non-zero (65 if nothing else failed).
- **When:** 8+ tests or about 4 min of runtime; below that run plainly (each shard costs ~1 min of fixed overhead).
- **N** defaults to, and is capped by, the free UI simulators; with one free (busy pool) it is a plain run.
- **`--wait`:** N defaults to `UI_POOL_SIZE` and is capped only by it and the test count; the `🔀 N shards, W waiting`
  line says how many start without a simulator. Those wait for a slot (up to `LOCK_TIMEOUT`, one `[k] 🔒` line each).
  A shard that gets none counts as `N not run (no simulator within <s>s)`, is not retried, and the exit code is 75.
  `--split 1 --wait`, or a caller already holding a simulator, is a plain run.

Full parallel runs use `--split` (`UI_WORKERS=N` is shorthand for `--split N`). Xcode's parallel-testing clones are
not used: they boot cold each run and trigger PosterBoard crash pop-ups.

## Running the app against a local API

The app has no built-in server (spec 008). To run it from Xcode on the simulator against `scripts/api-dev.sh`,
set `LA_CARTE_API_URL=http://127.0.0.1:8000` and any `LA_CARTE_API_TOKEN` in the scheme, or type both once in
Settings. A server started without `LA_CARTE_API_TOKEN` ignores the header. UI tests' `APIMode.live` always
sends a token for the same reason.

## Screenshots

`scripts/ios-ui-test.sh <run>` exports to `qa/screenshots/<run>/`:
```
qa/screenshots/<run>/home-light.png
qa/screenshots/<run>/home-dark.png
qa/screenshots/<run>/recordings/<test>.mp4   # Xcode's screen recording: failed tests only, every test with --record
qa/screenshots/<run>/logs/console.txt        # the test runner's output: tests' print(), XCTest's "t = …" steps
qa/screenshots/<run>/logs/<Class>_<test>.txt # the same, one test (a retried test has one block per attempt)
```
The run prints `📝 logs: …` under the `📸 screenshots:` line. Logs come from the bundle's action log
(`xcresulttool get log --type action`, per-test sections; its `--type console` log is empty for these runs); an export
failure only warns. `print` is for debugging: anything a test asserts on or a QA report cites also goes in an
`XCTContext.runActivity` note or an attachment, which stay in the `.xcresult` and in Xcode's report.
`scripts/ios-ui-test.sh --record <run> …` (or `UI_RECORD=1`; with `--split` too) keeps the recordings of passing
tests as well, for that run only: it sets the attachment lifetime to `keepAlways` in the run's own copy of the test
products, never in the scheme. The run ends with `🎬 recordings: N files, SIZE`; about 1–10 MB per test, so record
only the tests you need. A test name found in two classes becomes `<Class>-<test>.mp4`.
`qa/screenshots/` is gitignored; the QA report references the run, and the manager shows the user the key images.
Colour, contrast and spacing criteria are measured, not eyeballed: QA cites `uv run scripts/screen-sample.py`
output (`at`, `region`, `diff`, `contrast`, `gap`; coordinates in points) per criterion in `qa/reports/`.
Layout (ink = max per-channel |Δ| from the region's commonest colour > `--tol 24`):
```bash
uv run scripts/screen-sample.py bbox  <png> x0,y0,x1,y1                     # ink bounding box + size (pt)
uv run scripts/screen-sample.py bands <png> x0,y0,x1,y1 [--min-gap 4]       # text lines: start/end/gap (--axis x: columns)
uv run scripts/screen-sample.py compare <A> <B> x0,y0,x1,y1 --max-offset 0.34   # B - A offsets; exit 1 if something moved
uv run scripts/screen-sample.py dots <png> x0,y0,x1,y1 [--ring] [--sym x|y|both] [--dots-list]
#   dots (ink components): count, diameters, filled/ring, merged, ink/track Δ, min/max edge gap, mirror symmetry
uv run scripts/screen-sample.py dots f0.png f1.png … x0,y0,x1,y1 --ring   # frame sequence: per frame + worst frame
```
Image and video ops (`uv run scripts/image-ops.py --selftest`; same point/scale rules, outputs in `$TMPDIR/image-ops/`):
```bash
uv run scripts/image-ops.py crop <png|svg> x0,y0,x1,y1 --zoom 8             # pixel-level inspection (--zoom 2.5: LANCZOS;
                                                                             # an SVG is rasterised at 1024, --svg-size N)
uv run scripts/image-ops.py montage a.svg b.png --apple --mask [--sizes 1024,58,29] [--cols N]   # icon contact sheet:
                                                                             # one row per candidate (1024 shown at 256,
                                                                             # 58/29 + 4x zoom, Apple icons at 58/29 beside);
                                                                             # without --apple a grid <= ~1.5x as tall as wide
uv run scripts/image-ops.py frames <mp4> --from 2 --to 4 [--every 0.1]       # PNGs named by real timestamp
uv run scripts/image-ops.py track <mp4> x0,y0,x1,y1 [--from S --to S] [--json]  # luma per frame + 10-90 % transition times
#   track … --match HEX[:TOL] (repeatable)   # + per frame the region's share of pixels near that colour
#   track … --scroll-indicator              # + per frame whether an iOS scroll indicator shows at the right edge
uv run scripts/image-ops.py grid 'dir/{col}-{row}.png' --cols a,b,c --rows x,y [--col-label a=TEXT]  # variants (cols)
                                                                             # x cases (rows) sheet with headers
uv run scripts/image-ops.py strip <mp4> [x0,y0,x1,y1] (--every S | --at t1,t2,…) [--height PX]   # frames side by
                                                                             # side, each labelled with its timestamp
```
Ad-hoc capture of a running simulator, only when the user is at the Mac (macOS privacy prompt):
`xcrun simctl io booted screenshot qa/screenshots/adhoc.png`.

## Simulator

Defaults to `iPhone 17 Pro` (same as the user's phone) on the latest installed iOS (27). Xcode 27 doesn't
create that simulator by default; create it once with:
`xcrun simctl create "iPhone 17 Pro" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-0`.
Override with `SIMULATOR=… OS=…` (CI uses `iPhone 17`).

**Dark on a local iOS 26.5 simulator** (docs/tooling.md P9): the device appearance can't be switched unattended
(`simctl ui` triggers a macOS privacy prompt). Check dark rendering there with the forced Dark / Forest theme
(`-theme dark`). "System theme follows device dark" on iOS 26 is checked on CI shards only
(`ci/boot-simulator.sh`), or locally only with the user at the Mac.
