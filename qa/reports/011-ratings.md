# QA: 011 Ratings (two buttons + confidence dots)

## Recheck 2026-11-22 (HEAD 9de7f98+): **PASS**. Gallery dots fit the screen (`qa/screenshots/recheck/design-system-light.png`); design-system tap tests green; full UI suite green (`recheck`).


## Final recheck 2026-11-21 (integrated branch, main merged): **FAIL** (1 regression)
`RatingsUITests` 8/8, `StudyUITests` 5/5 (2 live skipped), drag-rated live flow green in `final-e2e`.
1. **Design-system gallery is shifted left and clipped** since 011 added its "Confidence dots" section
   (`DesignSystemGallery.swift`, five rings in one row): launch with `LA_CARTE_SCREEN=design-system`. Expected: content
   inside the screen. Actual: the whole scroll content is offset left ("Design system" title, "LOGO", "CONFIDENCE DOTS"
   cut at the left edge, `qa/screenshots/final-rerun/design-system-light.png`), and the circle buttons can't be tapped:
   `LaCarteUITests/testDesignSystem_tapEachButton` and `testDesignSystem_tapButtonEdge` fail in both runs
   ("Last tapped: none"). Likely the dots row is wider than the screen; wrap it or let it scroll horizontally.

---


Verdict: **PASS**
Date: 2026-11-21 · Simulator: iPhone 17 Pro / iOS 27 · Branch `worktree-agent-a49c6e2d8c3e3ec0b` @ 1ba2dad (main merged)
Runs: `qa/screenshots/study-final/` (Ratings + Study + Refresh + StudyEdit), `qa/screenshots/study-final-e2e/`;
earlier: `011-mock/`, `011-mock-ratings/`, `011-mock-rerun/`, `011-e2e/`
Commands: `scripts/ios-ui-test.sh --split 4 study-final …` (Ratings 8/8, Study 7/7 + 2 live skipped, Refresh 8/8
green; the 3 failures are in StudyEditUITests, see the 010 report), `scripts/e2e.sh study-final-e2e` (✅ 7/7),
`scripts/ios-test.sh` (✅ 168 passed, 2 skipped).

Tests: `RatingsUITests` (8 tests), `StudyUITests` / `RefreshUITests` on the two buttons. Removed by the user's rule
(text-size tests deferred until before publishing): `testRatings_accessibilityXL`, `testStudy_accessibilityXL`,
`…XLLongText`, `…XLVeryLongTextScrolls`, `…XXXLCapped`.

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1 | PASS | `testRatings_twoButtons`; `011-mock-ratings/study-revealed-{light,dark,forest-dark}.png`: "Forgot" left, "Got it" right, hard/easy absent, none before reveal |
| 2 | PASS | `testRatings_buttonsAndDragsSendGrade` (Forgot → `again`, Got it → `good`, stub bodies); `testStudy_ratingsDisabledWhileReviewInFlight` (both disabled in flight), `011-mock/study-reviewing-light.png` |
| 3 | PASS (unit) | `StudyFeatureTests` 59/59 green in `scripts/ios-test.sh` |
| 4 | PASS (unit) | `StudyFeatureTests` 59/59 green in `scripts/ios-test.sh` |
| 5 | PASS | `testRatings_swipeHeldPreview` (identifier now asserted): `study.swipeRing`, label "Rating", values Forgot / Hard / None / Got it / Easy at the five f, buttons stay, no text. `study-final/study-swipe-*-{light,dark,forest-dark}.png` |
| 6 | PASS | `testRatings_buttonsAndDragsSendGrade`: +0.13 → good, +0.22 → easy, -0.13 → hard, -0.22 → again; body is exactly `{"rating": …}`; next card unrevealed, count decrements, no ring |
| 7 | PASS (partial) | `testRatings_deadZoneAndUnrevealedSendNothing`: f = ±0.04 → no POST, still revealed, both buttons enabled, no ring (`study-swipe-cancelled-*.png`). "Out to +0.22 and back" is not drivable in XCUITest (single-segment drags only): unit only |
| 8 | PASS | same test: ±0.22 on the unrevealed card → no POST, not revealed, no ring (`study-unrevealed-after-drag-*.png`); preview held before reveal shows no ring |
| 9 | PASS (editing) | `testRatings_dragWhileEditingSendsNothing`: ±0.22 while `study.backField` is open → no POST, no ring (`study-editing-after-drag-light.png`). In-flight case: unit |
| 10 | PASS | `testRatings_longCardScrollAndPull` (rerun): vertical drag scrolls the back's end into view, pull refreshes (new GET), card stays revealed, no ring, no POST (`011-mock-rerun/study-long-*.png`) |
| 11 | PASS | `testRatings_tapAndDoubleTapUnchanged`: tap reveals, double-tap opens `study.backField`, no ring (`study-doubletap-edit-*.png`) |
| 12 | PASS | `testRatings_dragReviewFailureThenRetry`: drag +0.13 with POST 500 → "Can't reach your deck"; retry → same card revealed, two buttons, no ring (`study-swipe-review-failed/retried-light.png`) |
| 13 | PASS (unit) | `StudyFeatureTests` 59/59 green in `scripts/ios-test.sh` |
| 14 | left for the user | haptics: device check |
| 15 | PASS (screens) | held shots morph from scatter (again) to a regular ring (easy), same picture across light/dark/forest runs (seeded); card text never moves. Motion/fade: device check |
| 16 | left for the user | Reduce Motion: device check |
| 17 | PASS (listed) / left for the user (activation) | Driving real VoiceOver (StudyEdit #13 test): the revealed back lists Easy, Got it, Hard, Forgot, Edit; none before reveal. XCUITest can't activate a custom action under VoiceOver (even "Forgot" does nothing), so activation is a device check |
| 18 | PASS (pending design-critic) | ink-only dots, no pink, readable on all three backgrounds (`011-mock-ratings/study-swipe-*`). See visual note 1 |
| 19 | deferred | Text-size UI tests deferred by the user |
| 20 | PASS | `011-e2e`: `testStudy_revealRateToCaughtUp_liveAPI` (drag then Got it → "All caught up", API stats 2 reviewed) |

## Visual review (docs/design-system.md checklist)
- [x] background edge to edge, light + dark + forest
- [x] nothing competes with the centered text at rest; no blue tint (the keyboard's blue return key is the system's, 010)
- [x] circle buttons aligned, 44 pt
- [x] long text wraps, no truncation; the long card scrolls
- [ ] Dynamic Type XL: deferred (user rule)

Notes for design-critic (not blocking on their own):
1. In grayscale, again (-0.22) and hard (-0.13) look nearly the same (both scattered, same dot positions with a bit
   less jitter); good (+0.13) and easy (+0.22) are also close. The design notes ask for the five to read as
   distinct "at a glance".
2. Dots are drawn over the card text (a dot sits on the "y" of "serendipity" and on "without" in the back).
   Allowed by the spec ("above the text"), but worth a look.

## Bugs
None. Previous bug 1 (`study.swipeRing` id) is fixed. Previous bug 2 (AppFeatureTests time-outs) did not recur:
`scripts/ios-test.sh` 168/168 green.

Tooling request: XCUITest can't drive a multi-segment drag (#7 out-and-back) or activate custom accessibility actions
(#17); both stay unit/device checks.
