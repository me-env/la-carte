# Testing

| Layer | Where | Tool | Owner | Run |
|---|---|---|---|---|
| API unit/integration | `api/tests/` | pytest (in-memory SQLite, `TestClient`, MCP in-process `Client`) | api-engineer | `scripts/api-test.sh` |
| Feature logic | `ios/LaCarteKit/Tests/` | Swift Testing + TCA `TestStore` | ios-engineer | `scripts/ios-test.sh` |
| API contract (iOS side) | `Tests/APIClientTests/DecodingTests.swift` | real JSON payloads from the API | ios-engineer + api-engineer | `scripts/ios-test.sh` |
| UI end-to-end (mock) | `ios/LaCarteUITests/` | XCUITest, `LA_CARTE_API=mock` | **qa-validator** | `scripts/ios-ui-test.sh <run>` |
| Full-stack E2E | same, `*_liveAPI` tests | XCUITest against a fresh seeded API | **qa-validator** | `scripts/e2e.sh <run>` |

## UI tests

- Test names: `test<Screen>_<scenario>` (e.g. `testStudy_revealAndRateGood`). Live-API variants end in `_liveAPI`
  and `XCTSkip` when `LA_CARTE_API_URL` is unset.
- Find elements **only** by accessibility identifier (`<feature>.<element>`), never by visible text or index.
- Mock tests run in **light and dark** (`XCUIDevice.shared.appearance`).
- Call `snapshot("<screen>-<state>", appearance:)` at every state worth reviewing. Names are stable:
  QA compares runs by filename.
- Mock data comes from `[Card].fixtures` (`APIClient/InMemoryAPIClient.swift`). Changing fixtures changes
  screenshots — coordinate with qa-validator.

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
