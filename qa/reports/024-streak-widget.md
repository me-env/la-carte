# QA: 024 Widget: the streak as a history grid (with freezes)

Verdict: PASS (AC 20 left for the user: device check)
Date: 2026-11-23 · Simulator: iPhone 17 Pro / iOS 27 · Branch `worktree-agent-abe83da76a6e6b457` (engineer commit 577b86f,
merged with origin/main incl. ae45807, the dark-mode simulator fix)
Runs: `qa/screenshots/024-mock/` (final), `qa/screenshots/024-mock-forced/` (forced-theme dark tiles),
`qa/screenshots/024-e2e/`, `qa/screenshots/024-renders/` (engineer's `WidgetRenders` PNGs + `widget-sheet.png`)
Commands:
- `scripts/ios-ui-test.sh --split 024-mock -only-testing:` WidgetUITests, MarketingUITests, StudyUITests, SettingsUITests:
  ✅ 17 passed, 0 failed, 3 skipped (the `_liveAPI` variants, which skip on mock)
- `scripts/e2e.sh 024-e2e`: ✅ 9/9. The real `/stats` with the 024 fields decodes in the app.
- `scripts/ios-test.sh`: ✅ 307 passed, 0 failed (after the final merge)
- `scripts/api-test.sh`: ✅ 230 passed (after the merge with API spec 021 v3)
- Full UI suite: not run. Per the manager's brief, only the affected classes run; the full suite is CI's job.

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1–7 (API) | PASS | pytest (`scripts/api-test.sh` green, 230 tests, after merging 021 v3's `/stats` changes). Live: `024-e2e` decodes the real payload (Study counter, Settings test connection) |
| 8 | PASS | `DecodingTests` decodes the full payload, incl. `history`/`history_start`/`streak_start`/`due_new`; `StreakGridTests.unknownLettersReadAsMissed` |
| 9 | PASS | `DecodingTests.toReviewCountsNewCardsUpToTheEndOfTodaysBatch` (64/45/19/15 → 30; due_new 0 → due) |
| 10 | PASS | `StreakGridTests.scenario(_:)`: all 10 expected D/W/Mo/Y + grid strings equal the spec table character for character (checked by QA); `scenarioPeriods` |
| 11 | PASS | `levelThresholds` (28, 29, 154/155, months→years edge), `monthsCountBackAcrossMonthEnds`, `daysAndWeeksAcrossTheDSTChange` |
| 12 | PASS | `invariantsOverRandomHistories` |
| 13 | PASS | `todayIsTheHistorysLastDay` |
| 14 | PASS | Small: status / grid / label (`024-mock/widget-small-*-{light,dark,forest}.png`). Medium: left hero or status block, right grid + label (`widget-medium-*`). Geometry measured on `024-renders/widget-small-freezes-light.png`: 4 bands of 9 pt at 19 pt pitch (y 56.3 / 75.3 / 94.3 / 113.3), ink width 123 pt = 6 × 19 + 9, 28 marks (`dots`: 26 filled + 2 ring = the two freezes), grid starts at x 21 (16 pt margin, leading). Families and description: code review of `DeckWidget.swift` only, not on screen |
| 15 | PASS | Pink-pixel scan (hue 320–5°, s > .35) of every tile PNG (UI light/dark/forest/forced-dark + all 66 renders): **exactly one pink component per tile, always at the today slot** (small 135–143.7 × 116.3–125 pt; medium x 334–342.7). Pending scenarios (zero, nine, twoHundred, eightHundred): ring, 392–416 px. Studied: filled, 569–593 px. `unavailable` and `.accented`: 0 pink. So labels and numbers are never pink. Gallery screens: one pink mark per visible tile (`widget-gallery-dark.png`: 8 tiles → 8 components) |
| 16 | PASS | `024-renders/`: 10 scenarios × small/medium × light/dark/forest + unavailable + `nine` accented per family = 66 PNGs at 170 × 170 / 364 × 170 pt @3x. Reviewed `widget-sheet.png` against `docs/design/renders/024/streak-widget-v3.png`: same layout, same marks, same states |
| 17 | PASS | `WidgetUITests.testWidget_galleryAllStates` (light + dark device) and `testWidget_galleryForestAndForcedThemes` (forest, forced light/dark): every `widgetGallery.tile.small.<id>` / `.medium.<id>` / `.unavailable` exists at 170 × 170 / 364 × 170. Tile = `background`, wallpaper = `surface` (asserted). Tile background pixel: `#F9FAF5` light, `#1A1A1A` dark, `#0E1913` forest (`screen-sample.py at`). Screens: `widget-gallery-{light,dark}.png`, `widget-gallery-forest-{light,dark}.png`, `widget-gallery-forced-*.png`, `widget-gallery-stored-forest-light.png`; per tile `widget-{small,medium}-<id>-{light,dark,forest}.png`, `widget-unavailable-*.png`; `024-mock-forced/widget-*-forced-dark.png` |
| 18 | PASS (unit) | `DeckWidgetEntryTests.accessibilityText` (zero, nine, three, eightHundred). VoiceOver on screen: deferred (docs/testing.md) |
| 19 | PASS | `InMemoryAPIClientTests.historyIsTodayPendingUntilACardIsReviewed`. Existing suites green: Study, Settings and Marketing (mock and stub-backed) |
| 20 | LEFT FOR THE USER | Device check: small and medium widgets on the iPhone show the live grid; today's ring fills after a study session once the app goes to the background |

## Visual review (docs/design-system.md checklist)
- [x] Background edge to edge, light + dark + forest: tile = `Theme.background`, radius 22 (sampled above)
- [x] Nothing competes: one quiet grid, one pink mark, no default blue tint, no borders or icons
- [x] Marks: `run` ink, `older` lighter grey, `missed` faint, frozen = hollow ink ring, distinct from today's pink ring
  over a fill (`sixtyFrozen`, `freezes`). Week squares, month pentagons and year stars share the dots' footprint
  (`widget-small-twoHundred-light.png`, `widget-medium-eightHundred-forest.png`)
- [x] Long text: "Ask your agent to add some", "Can't reach your deck" and "800-day streak" fit without truncation
- [ ] Dynamic Type XL: deferred (no text-size checks for now)

Feel vs the reference mockup and 02-editor / 05-theme-forest: matches v3. The only difference is locale formatting:
"Next at 6:40 PM" / "Next on Nov 24" (simulator en_US) instead of the mockup's 24 h "18:40" / "24 Nov". That's the
system date formatter, as in 007.

## Notes (non-blocking)
1. **Docs not updated yet.** The spec asks design-lead to update `docs/design-system.md` with step 2, but it still
   describes the 007 widget: Widget section "systemSmall only", "streak number in Theme.accent", and accent rule 3
   "The widget's streak number when the streak is ≥ 1". Both should switch to the spec 024 wording ("Docs to update").
   The product follows the spec; the doc is stale.
2. **Environment issues found during this validation, both outside 024:**
   - Device dark mode didn't apply on the SSD simulators until ae45807; validated again after merging it.
   - A fresh simulator shows iOS's one-time "slide to type" keyboard tip, which covered the Done key in
     `MarketingUITests.testMarketing_1_videoSession`. Fixed in tests: `dismissKeyboardTip(_:)` in `Support.swift`.

## Test changes (qa-validator)
- `StubAPIServer.swift`: `StubJSON.stats` sends `new_today`, `milestone`, `due_new`, `history` "p", `history_start` =
  today (device zone), `streak_start` null.
- `WidgetUITests.swift`: tiles = 10 scenarios × small/medium + unavailable, with per-family width. Each tile is
  scrolled fully into view before the colour checks and the crop. The tiles are also shot under forced dark.
- `MarketingUITests.swift`: `widgetGallery.tile.small.nine` replaces `.due`; dismisses the keyboard tip.

Tooling request: `screen-sample.py` has no "find colour" mode. QA wrote a throwaway pink-component counter (hue
window + connected components) to prove "pink only on today's mark". A `screen-sample.py hue <png> rect --hue
330..5` that prints component count, bboxes and pixel areas would make this a one-liner.
