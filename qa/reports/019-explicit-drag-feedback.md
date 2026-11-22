# QA: 019 Explicit rating drag (dot dial, any direction)

Verdict: FAIL (1 gesture bug; final dial screenshots pending design-lead's next RatingDial commit)
Date: 2026-11-22 · Simulator: iPhone 17 Pro / iOS 27
Build: branch `worktree-agent-af2df849bd472bf2d`, implementation 64091f2 (was a0bd570 before the rebase) + dial
rework a9cce82
Runs: `qa/screenshots/019-mock/` (Ratings + StudyLengths + theme rerun on a9cce82), `qa/screenshots/019-e2e/`,
`qa/screenshots/019-full/` (full suite, on 64091f2/a9cce82 mid-rebase)
Commands:
- `scripts/ios-ui-test.sh --split 019-mock -only-testing:…/RatingsUITests …/StudyLengthsUITests …/ThemeUITests/testTheme_forestFromPickerForcesDarkScheme`:
  15 passed, 1 failed (`testRatings_longCardScroll`, bug 1).
- `scripts/e2e.sh 019-e2e`: 9/9 ✅ (the live study flow now rates its first card with an **upward** drag).
- Full suite `--split` (all classes): 91 passed, 4 failed, 9 skipped. Failures: `testRatings_longCardScroll` (bug 1);
  `testRatings_swipeHeldPreview` (my size check caught the dial mid-pulse: fixed in the test, passes);
  `testStudyLengths_veryLongCardChromeScrollAndFade` (the test's extra vertical drag on a card that **fits** now rates
  it, which is 019 #2 by design: the test now drags only when the card scrolls; passes); `testTheme_forestFromPickerForcesDarkScheme`
  (signal kill, simulator; passes on rerun).

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1–4 | unit | Logic: engineer's `StudyDragTests` (fraction, grades by direction, `shouldBegin`) and `RatingDialTests`; not re-checked by UI |
| 5 | PASS | `testRatings_swipeHeldPreview` (light, dark, forest): `study.swipeRing` label "Rating", value Got it / Easy / Hard / Forgot / None at +0.13 / +0.22 / −0.13 / −0.22 / +0.04, "Easy" for `-studySwipePreviewUp 0.22`; dial centred on the card centre. `019-mock/study-drag-{again,hard,neutral,good,easy,easy-up}-{light,dark,forest-dark}.png` (a9cce82 dial; final dial screenshots pending) |
| 6 | PASS | Same test: `study.rate.again` "Forgot" (−0.22) / "Hard" (−0.13), `study.rate.good` "Easy" (+0.22, Up 0.22) / "Got it" (+0.13, +0.04), other side unchanged, ids and left/right order unchanged. Weights/colours by eye: armed side semibold ink, other side secondaryInk, +0.04 regular (`study-drag-neutral-light.png`) |
| 7 | PASS | `testRatings_realDragsAnyDirection` (real XCUITest drags, stub records bodies, fitting card): up 0.22 w → `easy`, down 0.22 w → `again`, up-right (0.1, −0.1) → `good`, left 0.22 → `again`, up-left (−0.2, −0.2) → no POST, card stays revealed, dial gone, row at rest (`study-drag-cancelled-upleft-light.png`) |
| 8 | **FAIL** | `testRatings_longCardScroll`: vertical swipe scrolls with no ring ✅; near-vertical drag (dx = 0.3 · dy) scrolls, no ring, no POST ✅; vertical drag at the end of the scroll doesn't rate ✅; **45° up-right drag scrolls ~12 pt and rates nothing** ❌ (bug 1) |
| 9 | PASS | 011 regressions: `testRatings_buttonsAndDragsSendGrade`, `_deadZoneAndUnrevealedSendNothing`, `_dragWhileEditingSendsNothing`, `_tapAndDoubleTapUnchanged`, `_dragReviewFailureThenRetry`, `_twoButtons` all green; live API `testStudy_revealRateToCaughtUp_liveAPI` green. Haptics / VoiceOver actions: unit + deferred |
| 10 | deferred | design-critic + device check (pulse, release scales, Reduce Motion left for the device). Interim notes below |

## Visual review (docs/design-system.md checklist)
- [x] background edge to edge, light + dark + forest (`study-drag-*-{light,dark,forest-dark}.png`)
- [x] no default blue tint; no accent in the dial (pink only on the counter)
- [x] circle buttons aligned; rating row keeps positions while echoing
- [x] card text fades during the drag (by eye on the held screenshots; opacity values are unit-tested), full again after cancel
- [ ] Dynamic Type XL: deferred (user rule)

Measured (`uv run scripts/screen-sample.py contrast`, region 140,300,270,345 pt, a9cce82):
- armed dots on dark (Forgot): #F2F2F0 on #1A1A1A, 15.5:1.
- dead-zone dots (60 % secondaryInk): 2.64:1 on dark (#5D5D5C on #1A1A1A), 2.8:1 on forest. Visible in the screenshots,
  but below the 3:1 non-text guideline: for design-critic to judge, not a spec failure.

On the first dial (64091f2, 24 dots), geometry matched the spec exactly: radius 108.5 ± 0.1 pt (R + 16 = 108),
armed 6 pt, track 4 pt, rings vs discs measurable. That dial has since been replaced (a9cce82), and one more
ordered-layout change is announced, so the final `study-drag-*` screenshots are **pending**.

## Bugs
1. **Long (scrolling) card: a 45° up-right drag scrolls instead of rating** (019 #2, AC 8).
   Repro: `testRatings_longCardScroll` (stub card `long` with a long back, `-UIPreferredContentSizeCategoryName
   UICTContentSizeCategoryAccessibilityXL` so it scrolls), reveal, then press at the card centre and drag
   (+0.2 w, −0.2 w) and hold 0.4 s. Expected: dial appears and release sends `easy` (|dx| = |dy| ≥ 0.58 · |dy|).
   Actual: the back scrolls 12 pt and no review is sent. Angle sweep on the same card (drag vector in card widths):
   (0.3, −0.17) 30° above horizontal → `easy` ✅; (0.25, −0.21) 40° → `easy` ✅; (0.2, −0.2), (0.3, −0.3) and a slow
   (0.12, −0.12) 45° → scroll, nothing ❌; (0.2, −0.24) 50° → scroll ❌; down-left 45° (−0.2, 0.2) → nothing (no
   scroll either) ❌. So the actual cut-off is between 40° and 45° above horizontal, not the spec's 60° (30° from
   vertical). Most likely the scroll view's pan wins before `RatingPan.shouldBegin` gets to decide; worth confirming on
   the device as well.

Tooling request: no `ffmpeg` on the Mac, so the UI-test recordings (`recordings/*.mp4`) can't be turned into frames
to see what a real drag did mid-gesture; I had to add temporary snapshots and rerun. A frame extractor (or ffmpeg)
would save a rerun per investigation. Also `scripts/ios-ui-test.sh --split <run>` with no `-only-testing` fails with
"0 UI tests matched (no filter)", and `-only-testing:LaCarteUITests` matches only the class of that name: a full-suite
split needs every class listed.
