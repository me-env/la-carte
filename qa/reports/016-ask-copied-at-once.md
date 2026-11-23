# QA: 016 AC 4 (Ask: "Copied" at once, "isn't installed" later with a fresh 2 s expiry)

Verdict: PASS
Date: 2026-11-23 · Simulator: iPhone 17 Pro / iOS 27 · Branch `ios-small-fixes` (validated at 4604d4d)
Runs: `qa/screenshots/016-mock/` (all of ReportUITests), `qa/screenshots/016-ask/` (Ask test, with recording)
Commands: `scripts/ios-ui-test.sh 016-mock -only-testing:LaCarteUITests/ReportUITests` (Ask tests ✅; `testReport_brokenPhotos` ❌, also fails on origin/main, see Notes),
`scripts/ios-ui-test.sh --record 016-ask` (testAsk_copiesCardText ✅). `e2e.sh` and full suite not run (not requested; full suite is CI's job).

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 4 | PASS | Recording `016-ask/recordings/testAsk_copiesCardText.mp4`, frames cropped to the counter slot in `016-ask/study-ask-copied-then-not-installed-frames-light.png`: menu closes at 12.20 s, "Copied" fades in at 12.27 s, then "Copied · Vibe isn't installed" cross-fades in from about 12.36 s, when the open call returns. "Copied" never waits for open. End state `016-ask/study-ask-not-installed-{light,dark}.png`. |
| 4 (stalled open, fresh expiry) | PASS (unit) | `StudyReportTests.copiedShowsAtOnceAndASlowOpenAddsNotInstalledWhenItReturns` (open stalls 60 s: "Copied" at once, expires at 2 s, "isn't installed" at 60 s, expires 2 s later) and `askCopiesThenOpens…NotInstalled`. The simulator can't stall the universal-link lookup on demand, so ordering under a stall is a unit-level check. |
| 5, 6 (regression) | PASS | `testAsk_copyOnlyShowsCopied`; `testAsk_copiesCardText` still checks the final "Copied · Vibe isn't installed", no request sent, and the exact pasteboard text. |

Test change: `testAsk_copiesCardText` now asserts that a notice starting with "Copied" exists within 2 s of the Ask tap, before it waits up to 90 s for the "isn't installed" text. It does not require the first label XCUITest sees to be exactly "Copied". The tap only returns once the app is idle, and on the simulator the "not installed" answer arrives about 90 ms after "Copied", so a strict check failed on the first run even though the screen was correct. The test saves `study-ask-copied` only when it catches the plain notice. The recording is the proof of order.

## Visual review (docs/design-system.md checklist)
- [x] background edge to edge, light + dark (`study-ask-not-installed-{light,dark}.png`)
- [x] notice sits centered in the counter slot, secondary grey, nothing competes with the card text
- [x] circle buttons aligned
- [x] long notice ("Copied · Vibe isn't installed") fits on one line, no truncation
- [ ] Dynamic Type XL: deferred (no AX checks for now)

Observation, not a bug: on the simulator the two notices cross-fade within about 150 ms, so "Copied" flashes briefly before the longer text. That matches the spec ("replaces the notice").

## Bugs
None for AC 4.

## Notes
- `testReport_brokenPhotos` fails on this branch and the same way on origin/main (3061a3e, run `016-main-broken`): "the card after the broken prompt photo never showed". The recording `016-ask/recordings/testReport_brokenPhotos.mp4` shows "Lee Park" (the next card) arriving at about 15 s, which is the poll timeout. Skipping a card whose prompt photo fails takes about 12 to 15 s. This branch only touches the Ask reducer, so the failure isn't caused by it. It needs its own ticket: either the broken-photo skip got slower on main (spec 015b #13) or the test's 15 s poll is too short.
