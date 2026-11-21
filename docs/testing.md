# Testing

| Layer | Where | Tool | Owner | Run |
|---|---|---|---|---|
| API unit/integration | `api/tests/` | pytest (in-memory SQLite, `TestClient`, MCP in-process `Client`) | api-engineer | `scripts/api-test.sh` |
| Feature logic | `ios/LaCarteKit/Tests/` | Swift Testing + TCA `TestStore` | ios-engineer | `scripts/ios-test.sh` |
| API contract (iOS side) | `Tests/APIClientTests/DecodingTests.swift` | real JSON payloads from the API | ios-engineer + api-engineer | `scripts/ios-test.sh` |
| UI end-to-end (mock) | `ios/LaCarteUITests/` | XCUITest, `LA_CARTE_API=mock` | **qa-validator** | `scripts/ios-ui-test.sh <run>` |
| Full-stack E2E | same, `*_liveAPI` tests | XCUITest against a fresh seeded API | **qa-validator** | `scripts/e2e.sh <run>` |

**Logo renders.** `scripts/ios-test.sh --render -only-testing:DesignSystemTests/RenderTests` (about 15 s) writes
`logo-<light|dark|forest>-p<000|025|050|075|100>.png` (1024 × 1024 px, `ImageRenderer`, on the theme
background) to `$LA_CARTE_SCRATCH/renders` or `build/renders`, or to `LA_CARTE_RENDER_DIR` if you set it. The
suite is skipped in normal runs and on CI. It doesn't render the gallery, because `ImageRenderer` draws a
ScrollView as empty. Use the UI-test screenshots for the gallery.

## UI tests

- Test names: `test<Screen>_<scenario>` (e.g. `testStudy_revealAndRateGood`). Live-API variants end in `_liveAPI`
  and `XCTSkip` when `LA_CARTE_API_URL` is unset.
- Find elements **only** by accessibility identifier (`<feature>.<element>`), never by visible text or index.
- Mock tests run in **light and dark** (`XCUIDevice.shared.appearance`).
- Call `snapshot("<screen>-<state>", appearance:)` at every state worth reviewing. Names are stable:
  QA compares runs by filename.
- Mock data comes from `[Card].fixtures` (`APIClient/InMemoryAPIClient.swift`). Changing fixtures changes
  screenshots — coordinate with qa-validator.

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
qa/screenshots/<run>/recordings/<test>.mp4   # when Xcode records the run
```
`qa/screenshots/` is gitignored; the QA report references the run, and the manager shows the user the key images.
Ad-hoc capture of a running simulator, only when the user is at the Mac (macOS privacy prompt):
`xcrun simctl io booted screenshot qa/screenshots/adhoc.png`.

## Simulator

Defaults to `iPhone 17 Pro` (same as the user's phone) on the latest installed iOS (27). Xcode 27 doesn't
create that simulator by default; create it once with:
`xcrun simctl create "iPhone 17 Pro" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-0`.
Override with `SIMULATOR=… OS=…` (CI uses `iPhone 17`).
