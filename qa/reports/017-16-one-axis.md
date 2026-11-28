# QA: 017 #16 One axis per card + weight transfer

Verdict: PASS
Date: 2026-11-28 · Simulator: iPhone 17 Pro / iOS 27 (local pool, split)
Build: branch `ios-engineer/017-16-one-axis` at e51053c, tests on `qa/017-16-one-axis`
Runs: `qa/screenshots/017-16-mock/` (all affected classes, `--record`), `qa/screenshots/017-16-mock2/`
(`StudyAnswerAlignUITests` again after two test-side fixes, `--record`)
Commands:
- `scripts/ios-ui-test.sh --split --record 017-16-mock` with StudyAnswerAlignUITests, StudyLengthsUITests,
  StudyRevealLiftUITests and `NotesUITests/testNotesStudy_personTextLayout`: 12 passed, 2 failed. Both failures were
  in my new test, not the app: a float `==` on frame sizes (110.33333333333331 vs …343), and an off-main screenshot
  stall (326 → 938 ms) that left no frame mid-crossfade. Fixed in the test.
- `scripts/ios-ui-test.sh --split --record 017-16-mock2 -only-testing:LaCarteUITests/StudyAnswerAlignUITests`: ✅ 3/3.
- `scripts/ios-test.sh` StudyTextLayoutTests + StudyCardTextTests + CardTextTests (unit, criterion (i)): ✅ 22/22.
- No e2e: #16 is layout and colour only, and no API contract changed. Full suite: left to CI (local QA runs only the affected classes).

Manager amendment (not yet in the spec): the short-answer size bump (`.cardFaceSmall`) applies only under a
leading (3+-line) question. A long but 2-line, centred question keeps `.cardAnswer`. Checked: see (d).

Spec wording: (a) says `study.front` starts at "`study.card` minX + 16 pt", but `study.card` is already the
column (frame `16, 122, 370, 642`), so its minX is the 16 pt edge. The deck button's minX is also 16. The tests
assert `study.front.minX == study.card.minX`, which is screen x = 16. That matches the design note's intent. The
architect could reword it to "at `study.card` minX (screen x = 16)".

## Acceptance criteria (#16)
| # | Result | Evidence |
|---|---|---|
| a | PASS, light and dark. Westphalia: `study.front` is at (16.0, 366.7, 370 × 110.3) with 4 lines. Each line's ink starts at x = 16.3–16.7. "The Peace of Westphalia" is at minX 16.0, and its ink starts at 16.67, the same as the question's. Git: front minX 16.0 (3 lines), and "git log main..HEAD" is at 16.0. The answer's line height is 26.3 pt. The question's line pitch is 27.6 pt, so the answer is `.title2` medium (`.cardFaceSmall`), not `.body` (~21 pt). Measured colours: question before reveal #1C1C1C / #F2F2F0 (`ink`), after reveal #6F6F6D / #8A8A88 (`recededInk`); answer #1C1C1C / #F2F2F0 (`ink`). | `017-16-mock2/study-axis-a-westphalia-{front,back}-{light,dark}.png`, `study-axis-a-git-back-{light,dark}.png` |
| b | PASS. The idiom question is 3 lines at minX 16. The answer "To feel down, …" has 2 lines, both inked from x = 16.67, at 21 pt each (`.body`). It's in `ink`, and the question is `recededInk` after reveal. | `017-16-mock2/study-axis-b-2lines-back-{light,dark}.png` |
| c | PASS. Westphalia with a 3-line answer (and the 7-line one): the answer is at minX 16, 361–370 pt wide, wider than the question's ink and within the column (maxX ≤ 386). The answer is `ink` and the question is `recededInk`. | `study-axis-c-3lines-back-*.png`, `study-axis-c-5lines-lift-back-*.png` |
| d | PASS. "la mer" / "the sea": both centred (midX = card midX). The question stays `ink` after reveal, and the answer is `secondaryInk` #9D9D9B / #8A8A88. "mitochondria": the question is centred and `ink`, and the 3-line answer is leading at x = 16 in `secondaryInk`. "Who composed The Magic Flute?" (2 lines) / "Wolfgang Amadeus Mozart": answer centred in `secondaryInk`, question `ink`. **Amendment:** "Which river flows through Paris to the sea at Le Havre, France?" (63 characters, 2 centred lines): "The Seine" is centred in `secondaryInk`, in the regular weight (`.cardAnswer`), and the question stays `ink`. | `study-axis-d-short-back-*.png`, `study-axis-d-shortq-longa-back-*.png`, `study-axis-d-2line-short-back-*.png`, `study-axis-d-long2line-back-light.png` |
| e | PASS. **Timing**, from the recording (`image-ops.py track`, question region, dark Westphalia reveal): the change runs 16.278 → 16.478 s (200 ms, 13 frames), with 10–90 % in 132 ms (±17). An ease-in-out over 0.25 s gives about 145 ms for 10–90 %. Light: 10–90 % in 100 ms (±17), event 133 ms. **Mid-frames** (off-main screenshots, about 105 ms apart): dark …530 ms #F2F2F0 → 633 ms (214) → 741 ms (151) → 848 ms #8A8A88. Light (run 2): 426 ms #1C1C1C → 532 ms (66) → 638 ms #6F6F6D. **Reduce Motion** (Settings toggle, light): the crossfade stays, 420 ms #1C1C1C → 526 ms (49) → 632 ms (106) → 739 ms #6F6F6D. There's no lift: `study.front` minY is 303.67 before and after, even with a 7-line answer. With Reduce Motion off, the same card lifts 84 pt. **New card in ink:** after rating Git, the idiom question fades in from the background to ink (40.218 s blank, 40.247 faint, then darker through 40.463 s). It never starts at the grey. | `017-16-mock/strip-e-next-card-fadein-dark.png`; frame sequences `017-16-mock2/study-axis-e-a-westphalia-{light,dark}-NN-*.png`, `study-axis-e-e-reduce-motion-light-NN-*.png`; `study-axis-e-reduce-motion-{front,back}-reduce-motion-light.png`; recordings `017-16-mock2/recordings/testStudyAnswerAlign_{light,dark,reduceMotion}.mp4` |
| f | PASS. `study.front`'s frame is identical before and after reveal on every leading card that doesn't lift. The ink lines (bands) are identical in y and x (in-test, 1/3 pt grid). `screen-sample.py compare` on the Westphalia front and back screenshots, region 16,366,386,477, gives `bbox dx +0 dy +0 dw +0 dh +0`, 4 bands each with `dy +0`, and `max offset 0 pt (limit 0.34: pass)`, light and dark. On cards whose answer lifts (#14), the bands move by exactly the lift and keep their shape. | `study-axis-a-westphalia-front-*.png` vs `…-back-*.png` |
| g | PASS. Double-tap on the revealed Westphalia question: `study.frontField` is at (16.0, 219.7, 370 × 110.3), at the 16 pt edge and spanning the 370 pt column. Its text is #6F6F6D / #8A8A88 (`recededInk`). `StudyLengthsUITests.testStudyLengths_inlineEditLongFront` also asserts the field's edge and width. | `017-16-mock2/study-axis-g-editing-front-{light,dark}.png` |
| h | PASS. Person cards are unchanged. `NotesUITests.testNotesStudy_personTextLayout` is green. Name and description stay centred under the photo, and the description is in `secondaryInk`. | `017-16-mock/study-person-long-description-prompt-revealed-light.png`, `study-person-*-revealed-*.png` |
| i | PASS (unit, engineer's suite). `CardTextTests.aShortAnswerUnderALeadingQuestionTakesItsTier`, `answerFontStaysBelowTheQuestion` and `StudyTextLayoutTests` pass in a local run. | `scripts/ios-test.sh` output |
| contrast | PASS. `screen-sample.py contrast` on the revealed Westphalia question: light `#6F6F6D on #F9FAF5: 4.8:1 AA pass`; dark `#8A8A88 on #1A1A1A: 5.03:1 AA pass`. The answer: 16.25:1 and 15.53:1. Forest wasn't run on a device (the spec gives it by token values only). | `study-axis-a-westphalia-back-{light,dark}.png` |

Regression baselines updated to #16 (old #6/#15 placement): `StudyLengthsUITests`. The Westphalia question and
the very long, overflow and wrapped-wide (layout D) questions are now asserted at the column edge. The 1-line
answer under Westphalia is on the question's edge, and the long-front edit field spans the column. All 8
StudyLengths tests and both StudyRevealLift tests are green. `StudyAnswerAlignUITests` now holds #16 (light, dark,
Reduce Motion) and replaces its #15 checks. `setReduceMotion` moved from NotesUITests to Support.swift so both
classes can use it.

## Visual review (docs/design-system.md checklist)
- [x] Background runs edge to edge, light and dark.
- [x] Nothing competes with the text, and there's no default blue tint. The keyboard's system return key is iOS's, as before.
- [x] Circle buttons are aligned. The leading question's edge (x = 16) lines up with the deck button's outer edge (16).
- [x] Long text wraps with no truncation. The 7-line answer and the 4-line question fit, ragged right.
- [x] One axis per card: leading cards read as one left-aligned block. The revealed answer is the darkest text on screen, and the receded question is still clearly readable.
- [ ] Dynamic Type XL: deferred (no accessibility checks for now).

## Bugs
None.

## Tooling request
Off-main XCUITest screenshots sometimes stall for about 0.6 s, so an in-test frame sequence can miss a 0.25 s
fade (run 1, light). The recording plus `image-ops.py track` covered it. Finding the event in a 60 s recording
took several manual `track`/`strip` passes, though. A helper that writes a timestamp marker into the recording,
or an activity → video-time map, would let `track --from/--to` target a named step.
