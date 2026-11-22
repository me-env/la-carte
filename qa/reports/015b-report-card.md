# QA: 015b Report a card (iOS, incl. broken_photo auto-report)

Verdict: **PASS** (re-validated at ab5f164, see Recheck)
Date: 2026-11-22 · Simulator: iPhone 17 Pro / iOS 27 · Branch `worktree-agent-acb62b7c558f65dcb` (50ff9a7 + main 82df9d3)
Runs: `qa/screenshots/report/` (requested selection), `qa/screenshots/015b-full/` (full suite), `qa/screenshots/015b-e2e/`
Commands:
- `UI_WORKERS=1 scripts/ios-ui-test.sh --split 3 report -only-testing:…/StudyUITests …/StudyEditUITests …/ReportUITests` ❌ 18/20 (bug 1; one flaky pass/fail, see notes)
- `scripts/ios-ui-test.sh --split 3 015b-full` (full suite) ❌ 79 passed, 1 failed (bug 1 only), 10 skipped
- `scripts/ios-test.sh` ✅ 215 passed
- `scripts/e2e.sh 015b-e2e` ❌ 8/10 (bugs 2 and 3)

New tests: `ios/LaCarteUITests/ReportUITests.swift`. Stub: `StubAPIServer.swift` now serves `POST /cards/{id}/report`
(recorded in `StubDeck.reports`, card then held out of `/cards/due`; `writeStatus` makes it fail) and
`/photos/broken-*` (404, an unreachable photo). `NotesUITests.testNotesStudy_unreachablePhoto_liveAPI` updated to the
amended 014d/015b behaviour (photo-prompt card skipped). Live cleanups use `addTeardownBlock` (a failed assertion
skipped `defer`, and the leftover note broke the next tests on the empty API).

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1 | PASS (as amended by 016: no title, Ask first, 5 reasons in order, ids on all 6 buttons, no broken_photo). On iOS 27 the system shows it as a popover anchored to the card, no Cancel row; tapping outside dismisses | `report/study-report-menu-{light,dark}.png`, `testReport_menuOpensAndCancels` |
| 2 | PASS (double tap on `study.back` → `study.backField`, no menu; unrevealed double tap only reveals) | `report/study-report-doubletap-text-light.png` |
| 3 | unit (green) | `StudyReportTests` |
| 4 | PASS (dismiss → card still revealed, ratings enabled, counter unchanged, nothing sent) | `testReport_menuOpensAndCancels` |
| 5 | PASS (wrong/drop/doubt/rephrase each sent, no `comment` key, right card) | `testReport_eachReasonSent` (stub bodies) |
| 6 | PASS with a next card ("Reported" centered in the counter slot, next card unrevealed, count decremented after ~2 s). **FAIL on the last card: see bug 3** | `015b-full/study-reported-light.png` |
| 7 | PASS for behaviour ("What's wrong?" opens right after the menu, Report disabled empty/blank, Cancel sends nothing, " typo in the answer " sent trimmed); **FAIL: `study.report.comment` id missing (bug 1)** | `report/study-report-other-light.png` |
| 8 | PASS ("All caught up") but see bug 4 for the subtitle | `report/study-report-caught-up-light.png` |
| 9 | PASS (stub 500: card stays revealed, ratings enabled, "Couldn't send the report", doesn't expire, cleared by a rating) | `report/study-report-failed-light.png` |
| 10 | PASS (mock: reported card not back after pull-to-refresh) | `testReport_heldAfterRefresh` |
| 11 | unit (green) | `APIClientTests` |
| 12 | PASS for the contract (card reported, not in `GET /cards/due`, "All caught up"); confirmation missing (bug 3) | `015b-e2e/study-report-live-light.png` |
| 13 | PASS on stub (broken prompt never shown, no dialog/notice, `broken_photo` + URL sent once, next card shown, count 2). **FAIL on the real API when the skipped card was the last loaded one: bug 2** | `report/study-broken-photo-skipped-light.png`, e2e `testNotesStudy_unreachablePhoto_liveAPI` |
| 14 | PASS (answer photo placeholder, card shown normally, one `broken_photo` report, rating continues, no notice) | `report/study-broken-photo-answer-light.png` |
| 15 | unit (green); UI also saw exactly one report per card | `testReport_brokenPhotos` |

Haptics and the VoiceOver "Report" action: not checkable / deferred.

## Visual review (docs/design-system.md checklist)
- [x] background edge to edge, light + dark (menu, notices, alert)
- [x] no default blue tint, no pink in the menu/alert/notice; notice is the `.meta` secondary counter text, centered
- [x] circle buttons aligned
- [x] long text wraps (menu titles fit, "I want it phrased differently" uses a smaller size but isn't truncated)
- [ ] Dynamic Type: deferred (docs/testing.md)
- Note for design-lead (not blocking): the iOS 27 popover's arrow sits on the card's centre and covers part of the
  answer line ("finding something go_d …", `report/study-report-menu-light.png`).

## Bugs
1. **Alert text field has no `study.report.comment` id.** Steps: reveal, double-tap the card, "Other…". Expected:
   the field is `study.report.comment` (spec ids). Actual: the alert's text field identifier is `''`
   (`study.report.send` and the menu ids do work). The `.accessibilityIdentifier` on the `TextField` inside `.alert`
   is dropped. Test: `ReportUITests/testReport_eachReasonSent` (fails at the end, after checking the behaviour via
   the alert's only text field).
2. **A skipped broken-prompt card can end the session while its sibling is due (real API).** Steps:
   `scripts/e2e.sh` → `testNotesStudy_unreachablePhoto_liveAPI`: a person note with photo `http://127.0.0.1:9/nobody.png`
   and directions photo→… and description→…; the API serves one direction (sibling burying). Expected: the photo
   card is skipped and reported, then the description card shows. Actual: "All caught up / Your deck is empty"
   while `GET /cards/due` returns the description card. API log order: `GET /cards/due`, `GET /cards/due`,
   `GET /cards/due`, then `POST /cards/{id}/report`: in `photoLoadFailed` the report and `fetchDueCards` run
   concurrently (`.merge`), so the refetch reaches the API before the report holds the card. Send the report
   first, then refetch.
3. **No "Reported" when the last due card is reported.** Steps: one due card, reveal, menu → "I don't want this
   card". Expected (#6): "Reported" in the counter slot for 2 s. Actual: the counter slot only renders while
   `phase == .studying`; the refetch switches to caught-up at once, so the notice never shows (polled every 0.1 s,
   `testReport_dropCard_liveAPI`).
4. **After reporting the last card the subtitle says "Your deck is empty".** Same steps as 3 (real API). The deck
   still has the card (held; decision 7: it still counts in `stats.total` = 1) but `next_due` is null, and
   `StudyView.nextDueText(nil)` returns "Your deck is empty". Screenshot `015b-e2e/study-report-live-light.png`.
   Expected: plain "All caught up" (or what the architect decides) when `total > 0`.

## Notes
- `testReport_doubleTapTextStillEdits` failed once in the first split run ("study.back missing" after a double tap
  on the unrevealed card) and passed in every other run (incl. 4/4 with `-test-iterations 4` and the full suite). Not filed; watch it.

## Recheck (ab5f164): PASS
All 4 bugs fixed. New test `testReport_lastCardShowsReportedThenCaughtUp`: "Reported" shown, then "All caught up"
(subtitle "Next card in 1 day", not "Your deck is empty"). Screenshots: `qa/screenshots/report-recheck/study-report-last-reported-light.png`,
`study-report-last-caught-up-light.png`.
- `UI_WORKERS=1 scripts/ios-ui-test.sh --split 2 report-recheck` (ReportUITests + StudyUITests): 13 passed, 0 failed, 3 skipped
- `scripts/e2e.sh report-recheck-e2e`: 10 passed, 0 failed (`qa/screenshots/report-recheck-e2e/`)
- `scripts/ios-test.sh`: all passed
