# QA: 018 Auto-refresh (no pull-to-refresh)

Verdict: PASS
Date: 2026-11-22 · Simulator: iPhone 17 Pro / iOS 27 (aiAppPicker fix also on iOS 26.5)
Build: branch `worktree-agent-ae451f3e6cdf01e60`, implementation commit 3ed9337
Runs: `qa/screenshots/018-mock/` (full suite), `qa/screenshots/018-mock-missing/` (#1–#3 + long-card scroll, final code),
`qa/screenshots/018-e2e/`
Commands:
- `scripts/ios-ui-test.sh --split 3 018-mock` (full suite): 81 passed, 3 failed, 9 skipped. The 3 failures
  (`DeckUITests/testEditor_discardProtection` and `MarketingUITests/testMarketing_4_readme`, both "crashed with signal
  kill", plus `MarketingUITests/testMarketing_1_videoSession`, "scroll to visible" AX error) are unrelated to 018 and
  all three passed on rerun (`018-rerun`, 3/3). The two crashes stopped their shard, so 4 new/renamed tests didn't run
  there; they ran on their own in `018-mock-missing`: 4/4 ✅.
- `scripts/e2e.sh 018-e2e`: 9/9 ✅ (`testStudy_pullToRefresh_liveAPI` removed from the list).
- `SettingsUITests/testSettings_aiAppPicker` (manager request, CI failure on Xcode 26.6): ✅ iOS 27 and ✅ iOS 26.5.

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1 | PASS | `testStudy_noPullOnCard`, `testStudy_noPullOnMessages`: drag down on `study.card` (studying) and `study.message` (caught up, no cards yet, offline 503): no new `GET /cards/due` or `/stats` in 3 s, no activity indicator, a card added on the stub doesn't appear. `018-mock-missing/study-no-pull-light.png`, `study-caught-up-no-pull-light.png`, `study-empty-no-pull-light.png`, `study-offline-no-pull-light.png` |
| 2 | PASS | Mid-drag screenshot (finger held 3 s after a 250 pt drag) vs before: no pixel moved around `study.front` / `study.message`; frame unchanged within 1 pt after. `018-mock-missing/study-no-pull-mid-drag-light.png`, `study-caught-up-no-pull-mid-drag-light.png`. Long card still scrolls: `testRatings_longCardScroll`, `study-long-scrolled-light.png` |
| 3 | PASS | `testDeck_noPull`: no `GET /notes`, no activity indicator, new stub row not shown, sheet still open, row frame unchanged. Mid-drag: the sheet follows the finger (native interactive dismiss) but the row keeps its place relative to the sheet's toolbar (no rubber-band). `018-mock-missing/deck-no-pull-mid-drag-light.png`, `deck-no-pull-light.png` |
| 4–11 | unit | Logic criteria, covered by the engineer's `StudyFeatureTests` (not re-checked here by UI) |
| 12 | PASS | `testStudy_autoRefreshAtNextDue` (light + dark): stub card due launch + 8 s → "All caught up / Next card in 4 seconds" → `canine` shows unrevealed with "1 to review" between 7.5 s and 15 s after launch, no interaction. `018-mock/study-auto-due-before-{light,dark}.png`, `study-auto-due-{light,dark}.png` |
| 006 #3, #5 | PASS | `testStudy_foregroundReload` kept: `018-mock/study-foreground-*.png` |
| 015b #10 | PASS | `testReport_heldAfterRefresh` now reloads via background → foreground |

Not UI-tested per spec: 30 s agent-add check (#5) and offline recovery (#7).

## Visual review (docs/design-system.md checklist)
- [x] background edge to edge, light + dark (`study-auto-due-dark/light`)
- [x] nothing competes with the centered text, no default blue tint, no refresh spinner anywhere
- [x] circle buttons aligned, 44pt (unchanged)
- [x] long text wraps, no truncation (`study-long-scrolled-light`)
- [ ] Dynamic Type XL: deferred (no text-size checks for now)

## Test changes (qa-validator)
- `RefreshUITests`: deleted the five pull tests; added `testStudy_noPullOnCard`, `testStudy_noPullOnMessages`,
  `testDeck_noPull`, `testStudy_autoRefreshAtNextDue`.
- `Support.swift`: `pullToRefresh` → `dragDown`; `pullToRefreshCapturing` → `dragDownHoldingCapture` (mid-drag
  screenshot while the finger is held) + `changedPoints`.
- `RatingsUITests.testRatings_longCardScrollAndPull` → `testRatings_longCardScroll` (pull half dropped).
- `ReportUITests.testReport_heldAfterRefresh`: background → foreground instead of the pull.
- `SettingsUITests.testSettings_aiAppPicker`: menu options matched by label or identifier, waited for.
- `scripts/e2e.sh`: live pull test and its comment removed; `scripts/ios-ui-test.sh` smoke list uses
  `testStudy_foregroundReload`.

## Bugs
None in the feature.

## Notes for other owners
1. `.github/workflows/ci.yml:107` (cicd-lead) smoke step still lists
   `RefreshUITests/testStudy_pullToRefreshWhenCaughtUp`, which doesn't exist (already stale before 018). Replace with
   `RefreshUITests/testStudy_foregroundReload` or `testStudy_autoRefreshAtNextDue`.
2. Tooling request (ios-ui-test-split.sh): when a test crashes ("signal kill") the rest of its shard isn't run, and the
   `TESTS:` summary doesn't list the tests that never ran (4 here, found only by diffing `func test` names against the
   log). It should report "N not run" and fail, or retry the remainder of the shard.
