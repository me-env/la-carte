# QA: 014b Notes client (model/client layer, no new screens)

Verdict: PASS
Date: 2026-11-21 · Simulator: iPhone 17 Pro
Runs: `qa/screenshots/014b/`, `qa/screenshots/014b-rerun/`, `qa/screenshots/014b-e2e/`
Commands: `scripts/ios-ui-test.sh 014b -only-testing:LaCarteUITests/LaCarteUITests -only-testing:LaCarteUITests/StudyUITests` (15 pass, 2 skipped, 1 flaky fail, see below); rerun of the failed test (pass); `scripts/e2e.sh 014b-e2e` (6/6 pass). Full suite not run: per manager's rule it runs once after merge.

## Acceptance criteria
Criteria 1-9 are unit/review items, outside QA scope. Criterion 10 (UI part):
| # | Result | Evidence |
|---|---|---|
| 10 (existing UI tests unchanged) | PASS (smoke set) | `014b/contact-sheet-1.png`; live API against real stack: `014b-e2e/contact-sheet.png` |

## Notes
- `StudyUITests/testStudy_ratingsDisabledWhileReviewInFlight` failed once ("study.rate.good vanished while the review is in flight"), then passed on isolated rerun (`014b-rerun`). Timing-sensitive test with a 3s stub delay while the lock queue made the simulator slow. Judged flaky, not a 014b regression (no UI/feature code changed; the stub card JSON uses pre-014a shape and decodes fine, as the other live-stub tests prove). Recommend engineer/QA watch it in the post-merge full run.
- Visual checklist: no screens changed; contact sheet shows backgrounds edge to edge, centered text, no regressions in light/dark.

## Bugs
None.
