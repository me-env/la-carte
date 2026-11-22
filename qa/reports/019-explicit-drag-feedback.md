# QA: 019 Explicit rating drag (dot dial, any direction)

Verdict: **PASS** (final validation 2026-11-22 on 008bff6, see the last section; AC 10 and haptics / Reduce Motion left for design-critic and the device)
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


## Re-validation 2026-11-22 (d683688 dial rings, 516178b AC8 fix, 015b7db release reward) — interim, run paused

Verdict so far: **FAIL** (2 bugs below). Paused by the manager mid-run (Xcode updated to 27.2; toolchain being
restored by dev-velocity). Not yet run: full UI suite (`--split 3`), `scripts/e2e.sh`, `testRatings_releaseTiming`.
Runs: `qa/screenshots/019b-mock/` (Ratings + StudyLengths: 15 passed, 2 failed), `qa/screenshots/019b-mock2/`.

- **AC8 fixed: PASS.** New `testRatings_longCardAngleSweep` (long card at AX-XL, real drags, hold 0.4 s): near-vertical
  up / down (17° from vertical) scroll with no dial and no review; 30°, 40°, 45°, 45° slow (→ good), 50°, 55° up-right
  rate `easy`; 45° down-left rates `again`. `testRatings_longCardScroll` (incl. 45°) green. `study-long-45deg-rated-light.png`.
- **AC5/6 held dial: PASS** (`testRatings_swipeHeldPreview` green after widening my frame bound: the element frame is
  ~274 pt, sized for pulse/release growth; the drawn dial measures ~219 pt = 2 × (R + 16) + dot). `screen-sample.py dots
  --tol 120` (excludes the 30 % text) on `019b-mock/study-drag-*-{light,dark,forest-dark}.png`, rect 80,320,322,565:
  96 dots in every armed state. Easy / Easy-up: d 4.42–4.54 pt (one size), min edge gap 5.26 pt, mirror symmetry max
  0.04 pt, 0 unmatched. Got it: spread 1.12 pt, min gap 2.98 pt (spec 1.5 + 6.5 × 0.2 = 2.8). Hard: spread 2.47, min
  gap 4.47 (spec 4.4). Forgot: sizes 2.58–8.04 pt (spread 5.46 > 3), min gap 8.01 pt (spec ≥ 8). Same in all themes.
  Contrast: armed dots on dark 15.5:1; dead-zone dots 1.7:1 light (#C2C2BF on #F9FAF5), 2.64:1 dark, 2.8:1 forest
  (visible, below 3:1: for design-critic).
- Release reward: Got it reward plays over the next card (recording `019b-mock2/recordings/testRatings_releaseRewardNextCardImmediate.mp4`
  7.717 → 7.782 s: next card under the settling dial). See bug 2 for Easy.

### Bugs (re-validation)
2. **The dial stays in the accessibility tree during the Got it reward** (019 §6 "hidden from accessibility"; also
   breaks 011 regression `testRatings_buttonsAndDragsSendGrade`: "ring on next card 3"). Repro:
   `testRatings_releaseRewardNextCardImmediate`, drag up 0.13 w on a revealed card, query after release:
   `+0.68 s id 'study.swipeRing' label 'Rating' value 'None' frame {{58,290},{286,286}}`, `+0.81 s … {{53,285},{296,296}}`
   (the frame grows: it is the reward's grow-and-fade). Not seen after Easy releases in the same test.
3. **(to confirm, timing run pending) Easy release: the next card appears only after the reward fades.** Recording
   `019b-mock2/recordings/testRatings_releaseRewardNextCardImmediate.mp4`, frames 10.95–11.25 s: at 10.952 s the
   released card (front 1 / back 1, text back to full) is still shown under the dial with the row reading "Easy";
   the dial grows and fades over that old card until 11.083 s; no frame changes until 11.198 s, when "front 2" starts
   fading in. For Got it (7.717 → 7.782 s) the next card is under the dial at once. `testRatings_releaseTiming` (added,
   not yet run) measures next-card delay per grade to confirm.


## Final validation 2026-11-22 (008bff6: `study.swipeRing` exists only while the drag is held) — **PASS**

Runs:
- `qa/screenshots/019c-reward/`: `testRatings_releaseRewardNextCardImmediate` + `testRatings_releaseTiming`,
  `-test-iterations 3`: 6/6 passed.
- `qa/screenshots/019-final/`: affected classes only, `--split 3`: RatingsUITests, StudyUITests, StudyLengthsUITests,
  StudyEditUITests, ReportUITests, RefreshUITests: 43 passed, 2 failed, 4 skipped. The full suite was not run
  locally (manager / user decision: 019 only touches Study; CI runs the full suite after the push). The first
  attempt (`--split 3 --wait 019-final`) never ran: this branch predates main's dcfa766, so `--wait` reached
  xcodebuild as a build action.
- `qa/screenshots/019-final-rerun/`: the 2 failures, `-test-iterations 3`: 6/6 passed.
- `qa/screenshots/019-e2e2/`: `scripts/e2e.sh 019-e2e2`: 9/9 passed.

Results:
- **Bug 2 fixed.** `testRatings_releaseRewardNextCardImmediate`: no `study.swipeRing` in the accessibility tree
  at any 50 ms poll for 1.2 s after Got it, Easy, Forgot and right-drag Easy releases, in all 3 iterations; 011
  regression `testRatings_buttonsAndDragsSendGrade` green.
- **Bug 3 not reproduced (closed).** `testRatings_releaseTiming` (Got it / Easy / Forgot ×3, each iteration): next
  card seen +0.02 s after the drag returns for Got it and Easy and +0.03 s for Forgot (mean good 0.02 · easy 0.02 ·
  again 0.03 s, `019c-reward/release-timing.txt`). Screenshots taken right after the release show the next card's
  front under the reward overlay for both grades (`019c-reward/study-release-{good,easy}-overlay-light.png`). The
  drag after an Easy release rates normally.
- AC 5–9: all 12 RatingsUITests green (held dial, row echo, real drags in every direction, long-card scroll and the
  angle sweep, 011 regressions). Live: `testStudy_revealRateToCaughtUp_liveAPI` green (`019-e2e2/study-live-*.png`).
- Dial measured again on `019-final/study-drag-*` (`screen-sample.py dots --tol 120`, rect 80,320,322,565): 96 dots
  in every state; Easy (forest) d 4.42–4.54 pt, min gap 5.26 pt, mirror symmetry 0.02 pt; Got it spread 1.12, min
  gap 2.98; Hard spread 2.44, min gap 4.47; Forgot spread 5.46, min gap 8.05 pt. Same as the 019b values.
- Not caused by 019 (flaky): `testStudyEdit_editBackDone` and `testStudyLengths_inlineEditLongFront` failed once in
  the split run (inline edit field gone at `hasFocus` / keyboard Done "scroll to visible" AX failure under 3
  parallel simulators); both passed 3/3 when rerun alone. Neither involves the rating drag.
- Left for the device: haptics (`.success`, the heavy impact on Easy), Reduce Motion, and how the reward feels.
  AC 10 is for design-critic. Dead-zone dot contrast (below 3:1, see above) is for design-critic, not a spec failure.

### Bugs
None open (1, 2 fixed; 3 not reproduced).
