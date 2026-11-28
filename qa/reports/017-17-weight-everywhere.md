# QA: 017 #17 Weight transfer on every card

Verdict: PASS
Date: 2026-11-28 · Simulator: iPhone 17 Pro / iOS 27 (local pool, split)
Build: branch `ios-017-17-weight-everywhere` at 4f4113a; tests on `qa-017-17`
Runs: `qa/screenshots/017-17-mock/` (`--record`: logs in `logs/`, recordings in `recordings/`)
Commands:
- `scripts/ios-ui-test.sh --split --record 017-17-mock` with StudyAnswerAlignUITests (light, dark, forest, Reduce
  Motion), StudyLengthsUITests, StudyRevealLiftUITests and NotesUITests `testNotesStudy_personTextLayout`,
  `_personRevealMotion` and `_personRevealMotionReduced`: ✅ 17/17 passed, first run (7.3 min wall, 5 shards).
- `scripts/ios-test.sh` (unit, criterion (h)): ✅ 380 passed, 0 failed, 12 skipped.
- No e2e: #17 changes colour only, and no API contract changed. Full suite: left to CI (local QA runs only the
  affected classes).

## Test changes
- `StudyAnswerAlignUITests`: now asserts the #17 colours on every card. Before reveal the question is `ink`. After
  reveal the question is `recededInk` and the answer is `ink`, on centred cards as well as leading ones. The colour
  tolerance is ± 3 per channel (it was 6). A forest run was added (`testStudyAnswerAlign_forest`). The la mer
  (centred) reveal is now captured as a frame sequence too. The ink-mask position check (f) now runs on every card,
  not only leading ones. (g) also checks `study.backField`. The Reduce Motion test now covers a centred card
  (la mer) as well as Westphalia.
- `NotesUITests.testNotesStudy_personTextLayout`: runs in light, dark and forest. It measures the colour of the
  prompt before reveal, and of the name and description rows after reveal. It also compares the photo's mean colour
  before and after reveal, and across every card. `recordPersonReveals` (normal and Reduce Motion) checks the
  revealed colours.

## Acceptance criteria (#17)
Every colour below was measured on device as the most common glyph-core pixel colour. Tokens: `ink` is #1C1C1C
(light), #F2F2F0 (dark) and #EEF2EC (forest). `recededInk` is #6F6F6D (light), #8A8A88 (dark) and #83938A (forest).

| # | Result | Evidence |
|---|---|---|
| a | PASS in light, dark and forest. Measured colours (question before → after; answer): la mer / the sea (centred, `.cardAnswer`): light (28,28,28) → (111,111,109) = #6F6F6D, answer (28,28,28). Dark (242,242,240) → (138,138,136), answer (242,242,240). Forest (238,242,236) → (131,147,138), answer (238,242,236). mitochondria + 3-line answer (question centred, answer leading at x = 16), Westphalia, Git (leading, `.cardFaceSmall`), the idiom with a 2-line answer, Westphalia with 3- and 5-line answers, the 63-character 2-line centred question / "The Seine", and Magic Flute / Mozart all give the same values in each look, within ± 3. Contrast (`screen-sample.py contrast`, la mer revealed): question 4.8:1 (light), 5.03:1 (dark) and 5.57:1 (forest); answer 16.25:1, 15.53:1 and 15.89:1. All pass AA. Alignment and sizes are unchanged from #16: every frame matches the #16 report (for example Git's answer is 26.3 pt high, the `.cardFaceSmall` line, and The Seine is centred in the regular weight). Notes cards' extra prompt fields: not exercised (no notes-card fixture with extra prompt fields in these classes). | `017-17-mock/study-axis-d-short-back-{light,dark,forest-light}.png`, `study-axis-d-shortq-longa-back-*.png`, `study-axis-a-{westphalia,git}-back-*.png`, `study-axis-b-2lines-back-*.png`, `study-axis-c-3lines-back-*.png`, `study-axis-d-long2line-back-*.png`, `study-axis-d-2line-short-back-*.png`; values in `logs/StudyAnswerAlignUITests_*.txt` (lines `QA017-16 <look> <case>: … colours`) |
| b | PASS in light, dark and forest. **Name prompt** (Theo Lane, Lena Brook): before reveal the name is `ink`. After reveal it is (111,111,109) / (138,138,136) / (131,147,138), which is `recededInk`, and the description is `ink`. **Description prompt** (Nora Vale, Iris Moreau with a long description): the description is `ink` before reveal and `recededInk` after; the name is `ink`. Sizes and layout are unchanged (all 014d frame assertions pass). | `study-person-name-revealed-{light,dark}.png`, `study-person-name-forest-revealed-light.png`, `study-person-description-prompt-revealed-*.png`, `study-person-long-description-prompt-*revealed*.png`; `logs/NotesUITests_testNotesStudy_personTextLayout.txt` (`QA017-17 …`) |
| c | PASS. **Photo prompt** (Mia Stone, Owen Hart): after reveal, name and description are both `ink` in all three looks. The photo is untouched. Its mean colour is (197,194,203) before reveal, after reveal, and on every text-prompt card, in light, dark and forest (no tint, no opacity change). | `study-person-photo-revealed-dark.png`, `study-person-photo-forest-revealed-light.png`, `study-person-photo-long-revealed-light.png` |
| d | PASS. **Mid-fade frames** (off-main screenshots about 110 ms apart) fall between `ink` and `recededInk` on centred and leading cards. Light la mer: 440 ms (28) → 545 ms (51) → 657 ms (107) → 768 ms (111). Dark la mer: 561 ms (242) → 667 ms (202) → 776 ms (144) → 887 ms (138). Forest la mer: 648 ms (238) → 763 ms (217) → 871 ms (142) → 973 ms (131). Westphalia (light, dark and forest) gives similar results. **Timing**, from the recording (`image-ops.py track`, la mer region, dark): `#F2F2F0` disappears at 9.413 s and `#8A8A88` is reached at 9.630 s, which is about 217 ms of visible change. That fits a 0.25 s ease-in-out (the eased tails are below the frame resolution). At about 125 ms (9.538 s) the luma is 53.6, halfway between 64.4 and 45.4. Westphalia (dark): 13.998 → 14.197 s. **Answer**: it fades in from the background straight to `ink`, never from grey. In dark it goes 26 → 122 → 240 → 242; a fade from grey would start near 138. **New card**: the next question goes background → ink (dark 26 → 98 → 224 → 242), never starting at the receded grey. **Person name prompt** (recording, light): the name crossfades #1A1A1A → #6C6C69 during its morph, 7.49–7.82 s, with #545454 at about 125 ms. | frame sequences `study-axis-e-d-short-{light,dark,forest}-NN-*.png`, `study-axis-e-a-westphalia-*-NN-*.png`, `study-axis-e-next-*`; `recordings/testStudyAnswerAlign_dark.mp4`, `recordings/testNotesStudy_personRevealMotion.mp4` |
| e | PASS. With **Reduce Motion** on, the crossfade still runs. Centred la mer: 439 ms (28) → 550 ms (69) → 655 ms (110) → 766 ms (111). Leading Westphalia: 440 ms (32) → 551 ms (77) → 663 ms (111). Neither question moves: la mer stays at minY 401.33, and Westphalia (5-line answer) stays at 303.67, against an 84 pt lift with motion on. Person cards under Reduce Motion end with the prompt (111,111,109) and the other row (28,28,28), for both the name and the long-description prompt. | `study-axis-e-reduce-motion-centred-{front,back}-reduce-motion-light.png`, `study-axis-e-reduce-motion-{front,back}-reduce-motion-light.png`, `study-axis-e-e-reduce-motion*-NN-*.png`, `study-person-motion-*-reduce-motion-light.png` |
| f | PASS. `study.front`'s frame is identical before and after reveal on every card (in-test check, ± 0.5 pt). The ink lines are identical (± 1/3 pt) on every card that doesn't lift, centred ones included. `screen-sample.py compare`, la mer, light/dark/forest: `max offset 0 / 0.33 / 0.33 pt (pass)`. Measurement note: at the default `--tol 24`, the dimmer receded ink drops its faintest anti-aliased pixel row, so dark Magic Flute and dark Git show a 1 px shrink on both sides (0.66 pt). That is the threshold, not movement. At an equal-coverage threshold (`bbox --tol 108` for the ink frame against `--tol 56` for the receded frame, both 50 % coverage), dark Git gives the identical box `17, 385.67, 359, 461.67` with the same 37,726 ink pixels and identical bands. Magic Flute in dark and forest at `--tol 50`: `max offset 0 pt`. | `study-axis-d-short-{front,back}-*.png`, `study-axis-d-2line-short-*`, `study-axis-a-git-*` |
| g | PASS in light, dark and forest. Westphalia's `study.frontField` is at (16, 219.7, 370 × 110.3), with text (111,111,109) / (138,138,136) / (131,147,138), which is `recededInk`. mitochondria's `study.backField` text is (28,28,28) / (242,242,240) / (238,242,236), which is `ink`. | `study-axis-g-editing-front-*.png`, `study-axis-g-editing-back-{light,dark,forest-light}.png` |
| h | PASS. `StudyView.answerColor` is gone (no match in `ios/LaCarteKit`). The `CardText.answerFont` tests are unchanged. Unit suite green (380 passed). | `scripts/ios-test.sh` |
| unchanged | PASS. Alignment, sizes and the short-answer bump are as in #16: all assertions from (a) to (d), StudyLengths (8 tests) and StudyRevealLift (2 tests) pass. | as above |

## Visual review (docs/design-system.md checklist)
- [x] Background runs edge to edge in light, dark and forest.
- [x] Nothing competes with the text. On every card the revealed answer is the darkest or brightest text, and the receded question is still easy to read (≥ 4.8:1). There's no default blue tint; the keyboard's blue confirm key is the system's.
- [x] Circle buttons are aligned, and the leading edge is at x = 16.
- [x] Long text wraps with no truncation (mitochondria and the long descriptions).
- [x] The photo is never dimmed (its mean colour is constant).
- [ ] Dynamic Type XL: deferred (no accessibility checks for now).

## Bugs
None.

## Tooling request
`screen-sample.py compare` uses one absolute ink threshold (`--tol`) for both images. When only the text colour
changes (ink → recededInk), the dimmer image loses its faintest anti-aliased row, which shows up as a false 0.66 pt
"move". I had to re-run `bbox`/`bands` by hand at matched-coverage thresholds. A `compare --coverage 0.5` option
(each image's threshold set to half its own text-to-background contrast) would make "position unchanged, colour
changed" a single command.
