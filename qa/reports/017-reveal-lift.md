# QA: 017 Reveal lift (design note + AC 14, amending AC 9 and 13)

Verdict: PASS
Date: 2026-11-26 · Simulator: iPhone 17 Pro / iOS 27 · Build: `worktree-agent-ae7d0f0dd705347fa` @ fed74c2
Runs: `qa/screenshots/017-lift-mock/` (new tests + recordings), `qa/screenshots/017-lift-regress/` (affected classes),
`qa/screenshots/017-lift-regress2/` (rerun of the two failures)
Commands:
- `scripts/ios-ui-test.sh --split --record 017-lift-mock -only-testing:LaCarteUITests/StudyRevealLiftUITests`: 2/2 ✅
- `scripts/ios-ui-test.sh --split 017-lift-regress` with `StudyLengthsUITests`, `StudyUITests`, `NotesUITests`, `StudyEditUITests`:
  31 passed, 2 failed, 5 skipped (live-API tests). Both failures were mine or a flake (see below). Rerun of those two
  (`017-lift-regress2`): 2/2 ✅
- `scripts/ios-test.sh -only-testing:ScreenColorTests -only-testing:StudyFeatureTests/StudyTextLayoutTests`: 19 passed,
  0 failed ✅ (includes `questionStaysPut`, which holds the Reduce Motion render, and the three `revealLift*` tests)
- `scripts/e2e.sh`: not run. This is a pure view change with no API flow.
- Full UI suite: not run. Per the brief and `ui-test-scope`, only the affected study classes ran locally.

New test: `ios/LaCarteUITests/StudyRevealLiftUITests.swift`. It runs light and dark on a stub deck of 5 basic cards.
It asserts frames and ink, with the measurements logged as `QA017L`. Amended test: `StudyLengthsUITests.testStudyLengths_layoutD`.
The "question moved on reveal" check now follows AC 14: if lift ≤ 40 the frame must be identical. If lift > 40 the
question must be centred before reveal, lift by the computed amount, and keep its x and size.

Geometry (pt, from the log): `study.card` = (16, 122, 370 × 642), so its midY is 443.0.

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 14a: lift ≤ 40 → nothing moves | PASS | `q1a2` ("la mer" with a 2-line answer, lift 29.2): the frame is identical before and after reveal, light and dark. `screen-sample.py compare study-lift-q1a2-front-*.png study-lift-q1a2-back-*.png 150,385,252,440` gives max offset 0 pt in light and dark. In layoutD, the 1-line answers (lift 21.2: `2line-short`, `wide1line-short`, `2line-widerAnswer`) have identical frames. |
| 14b: lift > 40 → centred before reveal (±1 pt) | PASS | `q1a4` (lift 51.2), `q1a8` (95.2) and `pairOverflows` (265.8): `study.front` midY = 443.0 for all three, light and dark (`study-lift-q1a4-front-{light,dark}.png`, `study-lift-q1a8-front-*`, `study-lift-pairOverflows-front-*`). Ink check: `bbox study-lift-q1a4-front-light.png` gives ink 431–455.33, midY 443.17. The layoutD 3+-line answers (lift 51.2 ×5) are also centred within 1 pt. |
| 14c: after reveal, the place matches today's | PASS | Each case moved exactly the computed lift (`moved` = `expected`, within 1e-13). A pair that fits is centred: (front.minY + back.maxY) / 2 = 443.0. The ink moved with the frame (`q1a4`: ink top 431 → 379.67, Δ 51.33, frame Δ 51.17). Today's render, pixel for pixel: `ScreenColorTests.questionStaysPut` (revealed vs the Reduce-Motion still, 0 changed pixels) passed. |
| 14d: horizontal place and columns never change | PASS | minX, width and height are identical within 0.5 pt in all 8 layoutD cards and all 5 lift cards. In `q1a4`, the ink x range is 157–246 before and after. |
| 14e: Reduce Motion → no lift | PASS (render) | XCUITest can't turn Reduce Motion on for the app (see the `LogoUITests` note). Render evidence: `questionStaysPut` renders with `\._accessibilityReduceMotion = true`. Unrevealed with Reduce Motion vs revealed gives 0 changed pixels in the question's ink. On device: deferred to the user. |
| Motion: critically damped, ~0.35 s | PASS | Recording `017-lift-mock/recordings/testStudyRevealLift_light.mp4`, about 8.18 s to 8.63 s. Per-frame question ink top: 431 → 429.3 → 424 → 418.3 → 407.3 → 398.3 → 392.7 → 387.7 → 384.7 → 382.7 → 380.7 → 380.3 → 380 → 379.67. That is monotonic with no overshoot. It settles within 0.33 pt in ~0.38 s. The answer fades in while rising. Strip: `study-lift-q1a4-strip-light.png`. |
| Scrolling: pair overflows → starts centred, ends at the top, no scroll | PASS | `pairOverflows` (pair 894.7 > card 642): before reveal midY is 443.0. After reveal, front.minY = 122.0, which equals the content top measured on `qAloneOverflows`. The end of the answer scrolls above the ratings (`study-lift-pairOverflows-{back,scrolled}-{light,dark}.png`). |
| Scrolling: the question alone overflows → lift 0 | PASS | `qAloneOverflows` (question 782 > card 642): the frame is identical before and after reveal and starts at the top (`study-lift-qAloneOverflows-*`). `testStudyLengths_overflowingCardScrollsAndNextOpensAtTop` passed. |
| Person cards unchanged | PASS | All 9 runnable `NotesUITests` passed, including `personRevealMotion`, `personRevealMotionReduced` and `personTextLayout` (`017-lift-regress/study-person-*`). |
| AC 9 / 13 regressions (other study tests) | PASS | `StudyLengthsUITests`, `StudyUITests`, `StudyEditUITests` and `NotesUITests` are green after the rerun. |

## Visual review (docs/design-system.md checklist)
- [x] background edge to edge, light + dark (all `study-lift-*` full screens)
- [x] nothing competes with the centred text, no default blue tint
- [x] circle buttons aligned and unchanged; the chrome doesn't move on reveal
- [x] long text wraps with no truncation, and overflow scrolls (`pairOverflows-back` flashes the scroll bar on reveal, as specified)
- [ ] Dynamic Type XL: deferred (no text-size tests for now)

## Notes (not bugs)
- First regression run, `layoutD`: the failures were in my AC 14 amendment. It compared CGSize with `==` (a 1e-13
  float difference) and reused the pre-reveal frame after a lift. Fixed, and green on rerun.
- First regression run, `StudyEditUITests.testStudyEdit_tapFieldRightAfterOpen` timed out after 10 min: every
  "wait for app to idle" took 60 s. The run took 29 min while other agents' runs held the pool. The card in that test is
  "serendipity" with a 1-line answer, so lift = 0 and the new code path doesn't run. Alone in `017-lift-regress2` it
  passed. Treated as a simulator-contention flake. If it recurs on CI, look at idle time there.

## Bugs
None.

Tooling request: XCUITest can't switch Reduce Motion on for the app, so AC 14's Reduce Motion half is checked only in a
render. A launch hook (e.g. an env var the app maps to `accessibilityReduceMotion`) would make it UI-testable.
