# QA: 019 Rating dial cues + wider middle grades (amended 2026-11-22)

Verdict: FAIL (one spec/behaviour mismatch that needs a decision; everything else passes)
Date: 2026-11-22 · Simulator: iPhone 17 Pro / iOS 27 · Branch `worktree-agent-a2d52c4d75fe2db65` (base 83bce37)
Runs: `qa/screenshots/qa-dial2-ratings/` (all 13 RatingsUITests), `qa/screenshots/qa-dial2-ratings-2/`
(new middle-band-edge test + MarketingUITests dragRing + StudyLengths scroll bar). Screenshots are gitignored, so they are local only.
Commands: `scripts/ios-ui-test.sh --split 2 --wait qa-dial2-ratings -only-testing:LaCarteUITests/RatingsUITests` (13/13 passed),
`… qa-dial2-ratings-2 -only-testing:…` (3/3 passed). No e2e run: the change is app-side only, and the live-API flows did not change.
Full suite: not run locally; CI runs it.
Code review: CHANGES REQUESTED. Its two must-fix items (stale 0.22 fractions in spec ACs 2, 5, 6, 7 and in the UI tests) are fixed on this branch.
Its other items are listed below.

## Test changes
- Extreme drags moved from ±0.22 to ±0.3 card widths (Easy/Forgot now start at 0.235 w): held preview, buttonsAndDragsSendGrade,
  realDragsAnyDirection, releaseTiming, releaseRewardNextCardImmediate, MarketingUITests `dragRing`, and StudyLengths `scrollBarOnRevealOnly`.
  The header comment now states the bands.
- New middle-band checks: ±0.2 w releases send `good` / `hard` (buttonsAndDragsSendGrade, realDragsAnyDirection);
  new `testRatings_swipeHeldMiddleBandEdge` holds ±0.2 w (light + dark) and checks that the ring and row still read Got it / Hard.
- The ±0.22 drags left in place are on unrevealed and editing cards, where any drag must send nothing.

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 2 / 7 | PASS | Real drags: up or right 0.3 → easy, down or left 0.3 → again, ±0.13 and ±0.2 → good / hard, up-left → nothing (stub bodies) |
| 5 / 6 | PASS | `study-drag-{again,hard,neutral,good,easy,easy-up}-{light,dark,forest-dark}.png`; ring value and row labels asserted |
| 8 | PASS | `testRatings_longCardAngleSweep`, `testRatings_longCardScroll` (unchanged vectors still give the same grades) |
| 9 | PASS | Dead zone, unrevealed, editing, double-tap, and review failure then retry all pass |
| §6 / 11 | PASS | `release-timing.txt`: next card shown +0.02 s after release for good, easy and again (mean 0.02 / 0.02 / 0.02 s), same as the main baseline `qa-longcard-fix-27` |
| §3 cues: Forgot pink, Easy chains | PASS | `held-grades-sheet.png`: Forgot −0.30 shows pink dots, light + dark; Easy +0.30 shows three closed chains; Hard −0.13, dead zone and Got it +0.13 show no cue |
| §3 "Hard, Got it and the dead zone carry none" | **FAIL** | `study-drag-good-far-light.png`, `zoom-good-far-light-links.png`, `study-drag-hard-far-*.png` |

## Visual review
- [x] Background edge to edge, light + dark. The pink stays readable on dark.
- [x] Nothing competes with the centred text. No default blue tint. Row echo is semibold on the target grade.
- [x] The dial is centred on the card. Dots don't touch.
- Dynamic Type and VoiceOver: deferred (user rule).

## Bugs
1. **Grade cues show while the release is still Got it or Hard.** Steps: launch with `-studySwipePreview " 0.2"` (light), reveal, and hold.
   The ring value and row both read "Got it", and a release sends `good`. Even so, every ring shows partial link stubs, as `zoom-good-far-light-links.png` shows.
   The same happens on the other side: `-studySwipePreview " -0.2"` reads "Hard" and shows about 5 pink dots.
   - Cause: links start at 60 % of the Got it→Easy span (m ≈ 0.68, ease ≈ 0.84), but Got it lasts until ease 0.97, so the top ~40 % of Got it shows lines. Pink starts at 70 % of the Hard stretch.
   - Expected: spec 019 §3 says "Hard, Got it and the dead zone carry none" and "Got it and anything short of clearly heading to Easy show no line". The user said: "when you're on Got it, you know for sure you've not picked Easy by error, because there are no lines".
   - Actual: a user can see lines (or pink), release, and get Got it (or Hard).
   - Decision for the manager/user, one of:
     - (a) Start links at Easy's bin edge and pink at Forgot's. Then a cue means "this release is Easy/Forgot".
     - (b) Keep the current behaviour (the user validated the look) and reword §3, `RatingDial.swift:8-9` and the design-system Study row to "lines/pink appear only as the drag nears Easy/Forgot".

## Review items not fixed here (engineer/architect)
- `RatingDial.swift:3-19`: `RatingBands` sits between `RatingDial`'s doc comment and the struct, so the dial's doc now documents `RatingBands`.
- 019 AC table: no numbered criterion covers the grade cues (`RatingDialCueTests`, `dial-held-*` strip).
- `011-ratings.md:41`: the old bin table (0.125 / 0.875) under the amendment note is not marked as superseded.
- Nits: `RatingDial.swift:123-127` checks the same thing twice. The `0.31` in `onlyForgotIsPink` is a magic number. `StudyDragTests.swift:39` uses 0.24 (ease 0.98, only 0.01 above the edge); 0.25 would leave more margin.
