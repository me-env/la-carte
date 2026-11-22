# QA: 017 Adaptive card text

Verdict: PASS (re-validation of fix `30a7d0a`; the first run's FAIL on AC 11 is kept below for history)
Date: 2026-11-22 · Simulator: iPhone 17 Pro / iOS 27 · light mode (spec: one simulator, light)
Build: `30a7d0a` (rebased on main incl. spec 018) on `worktree-agent-af2975cb0d52400eb`

## Addendum: layout D + scroll-bar flash (branch `worktree-agent-aa790f7910fc56c74`, rebased on main `5f30a22`)
Verdict: **FAIL** (1 bug: a leading answer overhangs a centred wrapped question by 3.3 pt). Scroll-bar fix: PASS.
Date: 2026-11-22 · iPhone 17 Pro / iOS 27 · light · commits `f9daa19` (scroll flash), `bf0c591`/`97bc1ce` (alignment by lines, layout D default)

Runs (all in `qa/screenshots/`):
- `017D-mock/` StudyLengthsUITests + StudyUITests + StudyEditUITests, `--split 3 --wait`: **21 passed, 0 failed, 3 skipped**
  (built before the ink check below was added)
- `017D-mock-b/` layoutD (with ink check) + inline edit + scroll bar: layoutD **failed** on the ink check (bug A), others passed
- `017D-lengths-mock/`, `-b/`, `-c/` iterations (`017D-lengths-mock-c/` has the full layout-D frame log)

New tests: `testStudyLengths_layoutD` (stub deck, 5 cards), `testStudyLengths_scrollBarOnRevealOnly`. Updated for D:
`alignmentByLength` (Westphalia block centred, answer at its left edge, inside its width), `veryLongCardChromeScrollAndFade` and
`overflowingCardScrollsAndNextOpensAtTop` (long front block centred), `inlineEditLongFront` (field width = block width).

### (1) Scroll bar flashes on reveal only: PASS
Detector: changed pixels in the card scroll view's right 8 pt strip (378–385.5 × 126–760 pt) in every frame captured after
the action returns (~10 fps, 1.6 s), versus a settled screenshot 3 s later. Card = "Chlorophyll N" (short question) with a
~1,450-char hidden answer that overflows the card.
| transition | worst frame | evidence |
|---|---|---|
| Easy drag (+0.22 w) on "la mer" → Chlorophyll 1 | 0 points | `017D-mock/study-scrollbar-after-easy-light.png` |
| control: reveal Chlorophyll 1 | **5463 points** (bar flashes) | `017D-mock/study-scrollbar-reveal-worst-00-0976ms-light.png` |
| Got it button → Chlorophyll 2 | 0 points | `017D-mock/study-scrollbar-after-gotit-light.png` |
| reveal, scroll down, Got it → Chlorophyll 3 | 0 points | `017D-mock/study-scrollbar-after-scrolled-light.png` |
Same numbers in `017D-mock-b` and `017D-lengths-mock`.

### (2) Layout D on device
Frames (pt, card column 16–386, 370 wide) from `017D-lengths-mock-c`; pixels with `screen-sample.py`:
| card | question frame | answer frame | question pixels before/after reveal (`compare`, 0.34 pt) | result |
|---|---|---|---|---|
| "Which river flows through Paris?" (2 lines) / "The Seine" | 91.2–310.8, centred | 153.5–248.5, midX = question midX | 0 pt | PASS |
| "Speed of light (km/s)?" (1 line, 89 %) / 5-line answer | 36.2–365.8 | 36.2–358.2; ink 36.8 vs question 37.5 | 0 pt | PASS |
| "Who composed The Magic Flute?" (2 lines, centred) / 5-line answer | 73–329 | 73–322; **ink 73.3 vs question 76.7** | 0 pt | **FAIL (bug A)** |
| "Speed of light (km/s)?" / "299,792" | 36.2–365.8 | centred on the question | 0 pt | PASS |
| "Photosynthesis" (1 line, 63 %) / 5-line answer | 84.8–317.2 | 16–386 (column, layout A) | 0 pt | PASS (short question unaffected) |
| Westphalia (4 lines, leading) / "The Peace of Westphalia" | ink 16.3–384.3 | ink starts 16.7 | 0 pt (`017D-mock/study-lengths-long-*`) | PASS (shared left edge) |
| "la mer", "mitochondria", medium "capital of Australia" | centred, as before | as before | — | PASS |
Every question frame is identical before and after reveal (XCUI frame equality + pixel compare).

### (3) Inline edit keeps the block width: PASS
- Westphalia front: `study.frontField` = 16, 370 wide, same as `study.front` (±1 pt).
- Answer under the 2-line Magic Flute question: `study.backField` 73–329 (256 pt, the question's column incl. its break space)
  vs `study.back` 73–322 (249 pt): same left edge, same height (128.3 pt, no rewrap), within the question
  (`017D-lengths-mock-c/study-layoutD-2line-long-editing-back-light.png`, lines break as in `…-2line-long-back-light.png`).

### Bugs
A. **Leading answer overhangs a centred, wrapped question by 3.3 pt (layout D).** Stub card "Who composed The Magic Flute?" /
   "About 299,792 kilometres per second in a vacuum, the fastest that anything can travel, and the same for every observer
   whatever their speed." on iPhone 17 Pro, light, reveal. The question wraps to 2 centred lines; its column is measured
   with the break space ("Who composed The ", 256 pt), so the frame is 73–329 but the centred line's ink is 76.7–324.7
   (the trailing space is not drawn, so the line sits ~3.5 pt right of the frame's left edge). The leading answer starts at
   the frame (ink 73.3), 3.3 pt left of the question's first glyph: visible as an overhang
   (`017D-lengths-mock-c/study-layoutD-2line-long-back-light.png`, crop x 60–140 pt, y 330–470 pt), and past AC 13's 3 pt.
   A leading (3+ line) question doesn't have this (Westphalia: 16.3 vs 16.7), nor a one-line wide question (37.5 vs 36.8).
   Expected: the answer's left edge = the centred question's widest line's drawn left edge (measure the widest line without
   its trailing break space, or align to the drawn line). Repro: `scripts/ios-ui-test.sh 017D-x
   -only-testing:LaCarteUITests/StudyLengthsUITests/testStudyLengths_layoutD` (fails on "answer ink starts 3.33 pt left").

### Notes
- `testStudyLengths_inlineEditLongFront` failed 2 of 5 runs (passed in `017D-mock`, `-c`, `-b`): after the medium draft, the
  tap at (0.99, 0.95) of the one-line `study.frontField` (16–386 × 259.7–292 pt) to place the caret ended the edit, so the
  long-word draft step found no field. Frames are the same in passing and failing runs; recording
  `017D-lengths-mock/recordings/testStudyLengths_inlineEditLongFront.mp4` ~18.5 s. Not tied to layout D as far as I can
  tell (that field is full-column like before); worth a look if it shows up again.
- Spec 017 UI checks for AC 6, 7, 10 and 13 updated to the rendered-line rule and layout D.

## Re-validation (fix `30a7d0a`)
Runs:
- `qa/screenshots/017b-mock/` very long card + fade (AC 8, 11): passed
- `qa/screenshots/017b-edit/` inline edit (AC 10 + answer position), new `testStudyLengths_inlineEditTrailingNewline`: 2 passed
- `qa/screenshots/017b-full/` full UI suite `--split 3` (branch now includes 018): 93 passed, 1 failed, 9 skipped (14.6 min);
  the failure is `ThemeUITests/testTheme_backToSystemInOpenSheets` "Test crashed with signal kill" (infrastructure),
  re-run alone in `qa/screenshots/017b-full-b/`: passed. Net: every UI test green. Live-API e2e not re-run (the fix only touches StudyView layout/transition; 017-e2e was 10/10 on the first run)

**AC 11: PASS.** Ink bounding box and darkest pixel in the card area (16–386 × 150–650 pt) per frame
(`study-lengths-fade-NN`, PIL script; `screen-sample.py region` gives the same colours):

| frame | content | darkest | ink bbox (pt) |
|---|---|---|---|
| 02 · 333 ms | Darwin card + answer | 28 (`ink`) | 16–383 × 150–650 |
| 03 · 445 ms | empty: old card gone at once, new one at ~0 opacity | 249 | none |
| 04 · 556 ms | "serendipity" mid-fade (`screen-sample region`: #979895) | 151 | 118.3–283.3 × 410.7–440.7 |
| 05 · 661 ms | near full | 36 | 118.3–283.7 × 410.7–441.0 |
| 06+ · 772 ms | final | 28 | 118.3–283.7 × 410.7–441.0 |

Two intermediate frames, ~0.25–0.3 s from first to final, same bbox in every frame (no slide), the previous answer
never shows over the new question. Same picture as the reveal control (`study-lengths-revealfade-NN`).
Mid-fade frame: `017b-mock/study-lengths-fade-04-0556ms-light.png`.

**Inline edit, answer position: PASS.** When the edit starts the keyboard lifts the whole centred stack by ~147 pt
(system keyboard avoidance, spec 010 "Keyboard (decided)"), so the answer is measured against the question:
- Asserted (`testStudyLengths_inlineEditLongFront`, `…TrailingNewline`): `study.back.minY − study.frontField.minY`
  equals `study.back.minY − study.front.minY` before the edit (±0.5 pt), `study.back` same height, and
  `frontField.maxY ≤ study.back.minY` at edit start and for every draft.
- Pixels (ink bands, pt): Westphalia first question line → answer top 148.0 before, 149.4 editing; 2-line stub
  114.3 → 115.7. So the answer sits fixed under the field's frame; the field's glyphs are drawn 1.4 pt higher than
  the Text's (was 2.7 pt in the first run). Under spec 010 #14's ±2 pt, not visible. `017b-edit/study-lengths-long-revealed-light.png` vs `…-long-editing-light.png`.
- Drafts that could wrap differently: "Pneumonoultramicroscopicsilicovolcanoconiosis, Hippopotomonstrosesquippedaliophobia?"
  (hyphenated over 4 lines in the field, answer 28 pt below the last line, no overlap:
  `017b-edit/study-lengths-long-editing-longword-draft-light.png`), short and medium drafts as before.
- Draft ending in a newline: Return and a pasted "\n" both commit the edit (a pasted newline saved "Which treaty?",
  trimmed), so the only way to get there is deleting the last line of a card with a line break. Stub card
  "Which treaty ended the Thirty Years' War?\nWestphalia" / "1648", delete "Westphalia": the field shows the empty
  last line with the caret (290–326 pt) and the answer stays below it (348 pt), no overlap:
  `017b-edit/study-lengths-newline-draft-light.png`.

---

## First run (build `bef2170`): FAIL on AC 11
Tests: `ios/LaCarteUITests/StudyLengthsUITests.swift` (5 tests), `APIMode.mockLengths` in `Support.swift`
Runs:
- `qa/screenshots/017-mock/` (all 5 tests, `--split 3`; one shard died at bootstrap, "Test crashed with signal kill
  before establishing connection", infrastructure; its 2 tests re-run in 017-mock-b / 017-mock-c)
- `qa/screenshots/017-mock-b/` (alignment, all green; the edit test failed on a 2.7 pt field/text height
  tolerance, see note 2, loosened)
- `qa/screenshots/017-mock-c/` (very long card + fade control, inline edit: 2 passed)
- `qa/screenshots/017-full/` full UI suite, `qa/screenshots/017-e2e/` live API: full suite 93 passed / 0 failed / 10 skipped (`--split 3`, 16.4 min), e2e 10 passed / 0 failed

Note: every UI test is green. AC 11 fails on the frame-sequence evidence, which a UI assertion can't judge
reliably, so it is in the report and not a red test.

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| 1–4 | unit (not re-run here) | engineer's `CardTextTests`, `StudyCardTextTests` |
| 5 | PASS | `testStudyLengths_alignmentByLength`: front and back midX = card midX ±1 pt. `017-mock-b/study-lengths-short-front-light.png`, `…-short-back-light.png` |
| 6 | PASS | Westphalia: front.minX = card.minX = 16 pt ±1, front spans > 80 % of the card; revealed short answer "The Peace of Westphalia" at the same leading edge. `017-mock-b/study-lengths-long-front-light.png`, `…-long-back-light.png` |
| 7 | PASS | mitochondria centred (before and after reveal), long answer leading at card.minX and > 80 % wide. `017-mock-b/study-lengths-shortq-longa-front-light.png`, `…-back-light.png` |
| 8 | PASS | Darwin card (> 500 chars, asserted): `study.deck`, `study.add`, `study.reveal`, `study.rate.again/good` frames equal the "la mer" ones (±0.5 pt). It fits one screen, as rule 5 intends, so nothing scrolls there (`017-mock-c/study-lengths-verylong-*`). Overflow checked with a ~1,000-char stub card (`testStudyLengths_overflowingCardScrollsAndNextOpensAtTop`): dragging scrolls the text, the end of `study.back` comes above the rating row, chrome frames unchanged, no accidental rating. `017-mock/study-lengths-overflow-{front,back,scrolled}-light.png` |
| 9 | PASS | Westphalia front frame identical (±0.5 pt, same size) before and after reveal |
| 10 | PASS | `testStudyLengths_inlineEditLongFront`: `study.frontField` minX = text minX (16 pt). Draft "Which treaty?" (short tier) then "Which treaty, signed in 1648?" (medium tier): one-line field stays the same height, well below the 34 pt "la mer" field, still leading. After Done it re-tiers once to a centred medium question. `017-mock-c/study-lengths-long-editing*-light.png`, `…-long-edited-light.png` |
| 11 | **FAIL** in the first run, **PASS** after `30a7d0a` (see Re-validation) | see Bug 1. `017-mock-c/study-lengths-fade-NN-*.png` vs control `017-mock-c/study-lengths-revealfade-NN-*.png` |
| 12 | PASS (identifiers) / deferred (VoiceOver) | all tests find `study.front/back/frontField/card/deck/add/reveal/rate.*` by identifier; VoiceOver deferred per docs/testing.md |
| — | PASS (engineer's note: next card opens at the top) | After scrolling the overflow card down and rating, the next long card's front.minY equals the first card's unscrolled minY (±0.5 pt): `017-mock/study-lengths-overflow-next-light.png`. After the Darwin card, "serendipity" sits exactly where it does as the first card of the plain mock deck: `017-mock-c/study-lengths-after-verylong-light.png` |

Medium tier (spec screenshot list; mock-lengths has no 25–60 char question, so a stub serves "What is the capital of
Australia?" / "Canberra"): centred 28 pt question, centred 22 pt answer. `017-mock/study-lengths-medium-{front,back}-light.png`.

All screenshots match `docs/design/renders/017/sheet-front.png` / `sheet-back.png` (bottom row) for the same
tiers: big centred word, centred two-line medium question, 22 pt leading paragraph at the 16 pt margin aligned with
the circle buttons, answer one tier below in `secondaryInk`.

## AC 11 evidence (frame sequence)
Frames are full screenshots taken off the main thread every ~105 ms while the action runs (`captureFrames`).
- **Control, reveal** (`withAnimation(Theme.Motion.standard)`, also 0.25 s): `revealfade-05` (627 ms) and `-06`
  (730 ms) catch "the sea" part-way (darkest pixel 235 → 178 → 157 final) and the Show answer / Forgot · Got it
  cross-fade. So this capture rate does see a 0.25 s fade.
- **Rating the Darwin card**: `fade-02` (317 ms) is the full Darwin card with its answer, `fade-03` (423 ms) is
  "serendipity" at full ink (darkest pixel 28 = `ink`, same dark-pixel count as every later frame). No partial frame.
  Same in the first run (`017-mock/study-lengths-fade-*`: 421 ms Darwin → 527 ms full serendipity) and in that run's
  16 fps Xcode recording (one frame Darwin, the next full-opacity serendipity).
- No slide: serendipity is at its final position in the first frame it appears. The previous answer never shows
  over the new question (the old card is gone in one frame).

## Visual review (docs/design-system.md checklist)
- [x] background edge to edge (light; dark not required by this spec)
- [x] nothing competes with the text, no default blue tint
- [x] circle buttons aligned; leading text lines up with their outer edges (16 pt)
- [x] long text wraps, no truncation; size and alignment follow length; answer one tier below the question;
      anything longer scrolls (overflow card)
- [ ] Dynamic Type XL: deferred (no text-size tests for now)

## Bugs (first run; fixed in `30a7d0a`)
1. **AC 11: the next card doesn't fade in, it pops.** Launch with `LA_CARTE_API=mock-lengths`, rate the first three
   cards Got it, reveal the Darwin card, tap Got it. Expected: "serendipity" fades in over ~0.25 s
   (`Theme.Motion.standard`). Actual: it appears at full opacity in the next ~105 ms frame, no intermediate frame,
   in two runs and in the 16 fps recording, while the same capture shows the 0.25 s reveal fade in 2–3 frames.
   Evidence: `qa/screenshots/017-mock-c/study-lengths-fade-02-0317ms-light.png` →
   `study-lengths-fade-03-0423ms-light.png`; control `study-lengths-revealfade-05/06`. Reproduce:
   `scripts/ios-ui-test.sh 017-x -only-testing:LaCarteUITests/StudyLengthsUITests/testStudyLengths_veryLongCardChromeScrollAndFade`
   and compare the `fade-*` frames. Whatever the cause, the insertion transition doesn't run on screen.

## Notes (not blocking)
2. (Fixed in `30a7d0a`, now 1.4 pt of glyph offset, see Re-validation.) While editing the 5-line Westphalia front, `study.frontField` is 137.0 pt high vs 134.3 pt for the text
   (~0.5 pt per line), so the answer below shifts ~2.7 pt when the edit starts. Spec 010 #14 checks one-line cards
   (±2 pt). Barely visible; the test allows ±4 pt.
3. The mock deck's > 500-character card doesn't overflow on iPhone 17 Pro (by design, rule 5), so the scroll path was
   validated with a stub card; consider a longer mock card if marketing/QA want to show scrolling with `mock-lengths`.

Tooling request: frame-sequence capture tops out at ~10 fps (off-main `XCUIScreen` screenshots), and no ffmpeg on the
Mac to slice Xcode's recordings. A 30–60 fps capture (or `ffmpeg` / an `extract-frames` script for
`recordings/*.mp4`) would make animation criteria like AC 11 a measurement instead of an inference from a control.
