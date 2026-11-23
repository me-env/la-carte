# QA: 021 Milestone ladder (new cards per day, iOS UI ACs 20–24)

Verdict: **PASS** (re-validated after the report fix, 62a08aa merged with origin/main aaaf8fd)
Date: 2026-11-23 · Simulator: iPhone 17 Pro / iOS 27 · Branch `worktree-agent-adce3acd44906595c` (merged local main 3061a3e)
Runs: `qa/screenshots/021-recheck/` + `021-recheck-report/` (re-validation), `qa/screenshots/021-mock/` (new class), `qa/screenshots/021-regress/` + `021-regress2/` (affected classes),
`qa/screenshots/021-e2e/`
Commands:
- `scripts/ios-ui-test.sh 021-mock -only-testing:LaCarteUITests/StudyMilestonesUITests`: ✅ 3 passed, 1 skipped (live)
- `scripts/ios-ui-test.sh --split 021-regress` over the 15 classes that touch Study's counter: 101 passed, 10 failed.
  8 were stale test expectations, now fixed; `021-regress2` reran the 10: ❌ 8 passed, 2 failed (bug 1 + a
  pre-existing failure, see below)
- `scripts/e2e.sh 021-e2e`: ✅ 10 passed (includes the new `testStudyMilestones_ladderFromStats_liveAPI`)

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 20 | PASS | `testStudyMilestones_atRiskLadder`, light/dark/forest. Counter "1 at risk", popover only `study.milestone.atRisk` "At risk, 0 of 1" (`study-counter-atrisk-*`, `study-milestones-atrisk-*`). Rate: notice "At risk done" (`study-milestone-notice-*`), then "1 to review", popover At risk ✓ + Reviews 1/2 (`study-milestones-reviews-*`). Rate: "Reviews done" (`study-milestone-notice-reviews-*`), then "1 new", popover At risk ✓, Reviews ✓, 1 new 0/1 (`study-milestones-new-*`). Rate: "1 new done" over "All caught up" (`study-milestone-notice-caughtup-*`) |
| 21 | PASS | `testStudyMilestones_normalDay`: "1 to review", one row `study.milestone.reviews` "Reviews, 0 of 1", no at-risk or new row (`study-milestones-normal-*`) |
| 22 | PASS | `testStudyMilestones_manyNew`: "2 new"; `newDone` "4 new" ✓ above `new` "6 new, 4 of 6", with a bar at 4/6 (`study-milestones-many-*`) |
| 23 | PASS | `study.remaining` elementType `.button`, label "Milestones", value = counter text (all tests read the counter from its value now). Popover: 0 buttons, no static text outside the row frames, rows in ladder order, below the counter; a tap outside dismisses it without revealing the card |
| 24 | PASS | Measured on all 27 mock shots (pixels with R−G > 70 and R−B > 25): pink only in the counter's digit, about 4×8 pt at (169–189, 80–88) pt. None in the unit, popover, bar, checkmarks or notices (the 6 notice shots have no pink at all). The caught-up shots' pink is the logo (rule 1) |
| e2e | PASS | `testStudyMilestones_ladderFromStats_liveAPI`: the real `/stats` has `at_risk_total/done`, `reviews_total/done`, `new_today`, `milestone` 15, `due_new` 2; app shows "2 new", popover "15 new 0/15" (`021-e2e/study-milestones-live-light.png`) |

Dark mode is real: the background samples as #1A1A1A in dark shots and #0E1913 in forest ones.

## Visual review (docs/design-system.md checklist)
- [x] Background edge to edge, light / dark / forest.
- [x] The counter is a glass capsule: same rim and shadow as the two `CircleIconButton`s, on their line, 44 pt tall.
- [x] The popover is system glass with its arrow pointing at the counter, about 220 pt wide (measured 271–933 px @3x),
  rows only. Done rows are secondary ink with a checkmark; the current row is ink with secondary "done/total" and an
  ink bar on a light track. This matches `docs/design/renders/021/milestone-ladder.png`.
- [x] Notices are centred, in secondary ink like "Reported", and replace the counter.
- [x] No default blue tint. Text-size checks are deferred (docs/testing.md).

## Re-validation (2026-11-23, after the fix)
- `scripts/ios-ui-test.sh --split 021-recheck` over ReportUITests, StudyMilestonesUITests, DeckUITests,
  RatingsUITests, StudyUITests (every class that failed in `021-regress`): ✅ 49 passed, 0 failed, 5 skipped (live).
- `testReport_heldAfterRefresh` now also asserts that `study.milestoneNotice` never appears in the 4 s after the
  report, then shoots the result. `021-recheck-report`: ✅ 2 passed (with `testReport_brokenPhotos`).
  `study-report-counter-updated-light.png`: "la carte" unrevealed, the counter reads **"2 new"**, no step notice.
- `scripts/e2e.sh 021-recheck-e2e` on the merged head: ✅ 10 passed.
- `scripts/ios-test.sh` on the merged head: ✅ 332 passed, 0 failed, 11 skipped.

## Bugs
None open.

### Fixed
1. ~~**A report leaves the counter stale (the counter overstates what's left).** Repro: `LA_CARTE_API=mock` (3 new
   cards). Reveal "serendipity", open the report menu, choose "I don't want this card". The front becomes "la carte"
   but the counter stays **"3 new"** with 2 cards left; expected "2 new" (before 021 it read "2 to review"). Test:
   `ReportUITests/testReport_heldAfterRefresh` (line 258, 4 s wait), reproduced twice. Likely cause: the counter for
   a new step is `min(T − newToday, W)` with W from the last `/stats`. Only a rating refreshes the ladder (decision
   7), so a report, which removes the card from the batch and holds it on the server, never updates W. Fix
   (ios-engineer, or architect if decision 7 needs a word): after a successful report, refetch the ladder like after
   a rating, without a step notice. Alternatively, cap the counter by the batch size.~~ Fixed in 62a08aa:
   after a report the counter reads "2 new" and no notice shows (`021-recheck-report/study-report-counter-updated-light.png`).

## Not 021 (pre-existing)
- `ReportUITests/testReport_brokenPhotos` failed on main 3061a3e. aaaf8fd (now merged) fixed it, and it passes in
  `021-recheck` and `021-recheck-report`.

## Test changes in this round (qa-owned)
- New `StudyMilestonesUITests` (3 mock flows × light/dark/forest, plus 1 live test added to `scripts/e2e.sh`).
- `Support.launch(environment:)` and `waitForCounter` (reads `study.remaining`'s value). Every class now uses it.
- The mock deck's cards are new, so mock counters read "N new". The live seeded deck reads "2 new" / "1 new". Stub
  decks keep "N to review" (ladder counts 0).
- `StubJSON.stats` carries the four ladder counts next to 024's fields. Two stubs that served only `/cards/due` now
  serve `/stats`, because a queue load needs both (AC 17).
