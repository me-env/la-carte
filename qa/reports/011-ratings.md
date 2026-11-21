# QA: 011 Ratings (two buttons + confidence dots)

Verdict: FAIL
Date: 2026-11-21 · Simulator: iPhone 17 Pro / iOS 27 · Branch `worktree-agent-a49c6e2d8c3e3ec0b` @ 23b9b2a
Runs: `qa/screenshots/011-mock/` (Ratings + Study + Refresh), `qa/screenshots/011-mock-ratings/` (Ratings,
final tests), `qa/screenshots/011-mock-rerun/`, `qa/screenshots/011-e2e/`
Commands: `scripts/ios-ui-test.sh 011-mock -only-testing:…/RatingsUITests …/StudyUITests …/RefreshUITests` (❌ 2
Ratings tests; Study 15/15 + Refresh 8/8 green), `scripts/ios-ui-test.sh 011-mock-ratings -only-testing:…/RatingsUITests`
(❌ 1: bug 1; `testRatings_longCardScrollAndPull` green in `011-mock-rerun` after a test fix), `scripts/e2e.sh 011-e2e` (✅ 6/6), full suite: not run (manager rule: feature classes only; the full
regression runs after merge).

Tests: new `ios/LaCarteUITests/RatingsUITests.swift` (10 tests); `StudyUITests` / `RefreshUITests` switched to
the two buttons (hard/easy asserted absent); `testStudy_revealRateToCaughtUp_liveAPI` rates its first card with a
drag (f = +0.13).

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1 | PASS | `testRatings_twoButtons`; `011-mock-ratings/study-revealed-{light,dark,forest-dark}.png`: "Forgot" left, "Got it" right, hard/easy absent, none before reveal |
| 2 | PASS | `testRatings_buttonsAndDragsSendGrade` (Forgot → `again`, Got it → `good`, stub bodies); `testStudy_ratingsDisabledWhileReviewInFlight` (both disabled in flight), `011-mock/study-reviewing-light.png` |
| 3 | PASS (unit) | `StudyFeatureTests` 59/59 green in `scripts/ios-test.sh` |
| 4 | PASS (unit) | `StudyFeatureTests` 59/59 green in `scripts/ios-test.sh` |
| 5 | **FAIL** | Ring present, label "Rating", values Forgot / Hard / None / Got it / Easy correct at the five f, buttons stay, no text; regular ring centered on the card center. But the element's identifier is `study.card`, not `study.swipeRing` (bug 1). `011-mock-ratings/study-swipe-*-{light,dark,forest-dark}.png` |
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
| 17 | review only | XCUITest can't list custom actions. Code: `study.front`/`study.back` get Forgot/Hard/Got it/Easy when `canRate`, next to Edit. VoiceOver device check left for the user |
| 18 | PASS (pending design-critic) | ink-only dots, no pink, readable on all three backgrounds (`011-mock-ratings/study-swipe-*`). See visual note 1 |
| 19 | PASS | `testRatings_accessibilityXL`: both ≥ 44 pt, in the window, under the card, no overlap (`study-revealed-xl-light.png`) |
| 20 | PASS | `011-e2e`: `testStudy_revealRateToCaughtUp_liveAPI` (drag then Got it → "All caught up", API stats 2 reviewed) |

## Visual review (docs/design-system.md checklist)
- [x] background edge to edge, light + dark + forest
- [x] nothing competes with the centered text at rest; no blue tint (the keyboard's blue return key is the system's, 010)
- [x] circle buttons aligned, 44 pt
- [x] long text wraps, no truncation; the long card scrolls
- [x] Dynamic Type XL OK

Notes for design-critic (not blocking on their own):
1. In grayscale, again (-0.22) and hard (-0.13) look nearly the same (both scattered, same dot positions with a bit
   less jitter); good (+0.13) and easy (+0.22) are also close. The design notes ask for the five to read as
   distinct "at a glance".
2. Dots are drawn over the card text (a dot sits on the "y" of "serendipity" and on "without" in the back).
   Allowed by the spec ("above the text"), but worth a look.

## Bugs
1. **`study.swipeRing` identifier missing (#5, untestable by spec id).** Launch with `LA_CARTE_API=mock`
   `-studySwipePreview " 0.13"`, tap `study.reveal`. Expected: an element `study.swipeRing` (label "Rating", value
   "Got it"). Actual: the element exists with label "Rating" and value "Got it", but its identifier is `study.card`
   (the card's `.accessibilityIdentifier("study.card")` overrides the ring's own, since the ring sits inside the
   card's modifier chain). Side effect: `study.card` then matches two elements, and the first match is the ring.
   Evidence: `011-mock/App UI hierarchy for fr.lacarte.txt` line 11; `011-mock-ratings/Complete Issue Description.txt`.
   The tests currently find the ring by label "Rating" as a fallback so the absence checks aren't vacuous; once
   fixed, `testRatings_swipeHeldPreview` goes green with no test change.

2. **`scripts/ios-test.sh` red: 6 `AppFeatureTests` hit their 60 s time limit** (`addingFromStudyShowsTheNewCardWhenCaughtUp`,
   `closingSettingsReloadsStudy`, `openSettingsFromStudyPresentsSettingsOverStudy`, `deckButtonPresentsTheDeck`,
   `deletingFromTheDeckRefreshesStudy`, `aSuccessfulConnectionTestReloadsStudyWithTheSheetOpen`). The machine was
   heavily loaded (about ten agents testing), so this may be load, but six TestStore tests each exceeding 60 s looks like
   a hang. ios-engineer: rerun on a quiet machine and compare with main before merging.

## Unit tests
`scripts/ios-test.sh` (run once): StudyFeatureTests 59/59 green, including the known-flaky
`ratingCancelsALoadInFlightSoTheRatedCardCantComeBack` (did not recur). AppFeatureTests: bug 2.

Tooling request: XCUITest can't drive a multi-segment drag (out and back, #7) or read custom accessibility actions
(#17); both stay unit/review-only. A DEBUG hook that replays a list of drag points would close #7 on screen.
