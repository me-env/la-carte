# QA: 014d Person card, caption alignment and spacing (design 2026-11-25)

Verdict: PASS
Date: 2026-11-25 · Simulator: iPhone 17 Pro / iOS 27 · Commit under test: 598d6ff (branch `worktree-agent-a2e1113bec84f7bbf`)
Runs: `qa/screenshots/014d-caption-mock/` (after, the fix), `qa/screenshots/014d-caption-before/` (the same tests on
the parent's `StudyView.swift`, 5b34fb2, for before/after comparison; checked out temporarily, then restored)
Commands: `LACARTE_AGENT=qa-014d-caption scripts/ios-ui-test.sh --split 3 014d-caption-mock
-only-testing:LaCarteUITests/NotesUITests/{testNotesStudy_personCaption,testNotesStudy_personTextLayout,testNotesStudy_photoAnswerAndEmptyFieldSkipped}`
(✅ 3/3, light + dark). Same on the old code: ❌ 2/3 (the new checks catch the old layout: name to description
gap 4.0 ≠ 8, long caption block centred at x 197.2 instead of 201). No e2e: layout only, no API change. Full suite: left to CI (scope rule).

Scope: only the "Caption alignment and spacing" note (spec `docs/specs/014d-notes-study.md`), acceptance #6 as updated,
and the long-name check. The note's other acceptance items (#1-#5, #7) are re-asserted by `testNotesStudy_personTextLayout` and still pass.

## Tests added or changed (`ios/LaCarteUITests/NotesUITests.swift`)
- New `testNotesStudy_personCaption`, light + dark, 6 made-up people: photo + 1-line, photo + 4-line, no photo + 1-line,
  no photo + 4-line, long name (2 lines) + photo + 4-line, long name + no photo + 1-line, across the photo, name and
  description prompts. It asserts name and description midX on the axis (photo midX, else `study.card` midX, ± 1 pt),
  both ≤ 288 pt wide, name to description = 8 ± 1 pt, photo to name = 16 ± 1 pt, the long name wraps.
  Screenshots `study-caption-<case>-revealed-{light,dark}.png`.
- `checkPersonCard` (long description): replaced the old "lines start at the block's left edge" check with "block
  centred on the photo (± 1 pt), width ≤ photo + 48 pt".

## Measurements (ink on the screenshots, `screen-sample.py bands` + `bbox` per line, 3 px/pt, axis x = 201)
Every line's ink centre, light and dark identical:

| Screen (after) | Name lines | Description lines | Max off-axis |
|---|---|---|---|
| `study-caption-photo-short-revealed` | 201.67 | 201.67 | 0.67 |
| `study-caption-photo-long-revealed` | 201.33 | 200.83, 200.66, 201.16, 201.00 | 0.34 |
| `study-caption-nophoto-short-revealed` | 201.00 | 200.83 | 0.17 |
| `study-caption-nophoto-long-revealed` | 202.00 | 200.83, 200.66, 201.16, 201.00 | 1.00 |
| `study-caption-longname-photo-revealed` | 201.84, 201.34 | 200.83, 200.66, 201.16, 201.00 | 0.84 |
| `study-caption-longname-nophoto-revealed` | 201.84, 201.34 | 201.34 | 0.84 |
| `study-person-{photo-long,name-long,long-description-prompt}-revealed` | 201.17-202.00 | as above | 1.00 |

(The ≤ 1 pt offsets are glyph side bearings: the same name measures the same before and after, e.g. long name 201.84 in both.)
Before the fix the same description lines centred at 186.2, 177.7, … (left edge x 57.7, ragged right).

Widest ink: name 222.7 pt, description 274 pt (x 64.3-338.0), inside the 288 pt block (x 57-345). Accessibility
frames: description 280.3 pt wide centred on 201.0, name ≤ 223.7 pt centred on 201.0.

Gaps (layout frames from the test log / ink on the screenshots):

| Gap | Before | After |
|---|---|---|
| Name → description (frames) | 4.0 | 8.0 (`Theme.Spacing.s`) every case |
| Name → description (ink) | 12.67 | 16.67 (line-to-line ink gaps inside the description: 6-9) |
| Photo → name (ink) | 21.0 / 20.67 | 21.0 / 20.67 (unchanged) |
| Photo → name (frames) | 15 | 15 (within 16 ± 1) |

## Acceptance criteria
| # | Result | Evidence |
|---|---|---|
| Every line centred on one axis (photo; card without a photo) | PASS | table above; `014d-caption-mock/study-caption-*-revealed-{light,dark}.png` |
| Name and description capped at the same width (288 pt) | PASS | long name wraps at 222.7 pt ink, description ≤ 274 pt; `study-caption-longname-photo-revealed-dark.png` |
| Name → description gap larger (`s`, 8) | PASS | frames 8.0 every case (was 4.0); ink 16.67 > line gaps 6-9 |
| Photo → name gap unchanged (`m`) | PASS | ink 21.0 before and after; `study-caption-photo-long-revealed-light.png` |
| #6 (updated): 3+-line answer description centred on `study.photo` (± 1 pt), width ≤ photo + 48 | PASS | `study-person-photo-long-revealed-*.png`, `study-person-name-long-revealed-*.png`, `study-person-long-description-prompt-revealed-*.png`; no photo: `study-caption-nophoto-long-revealed-*.png` on `study.card` midX |
| Long name: wraps to two lines, centred within 288 pt, keeps the `s` gap (± 1 pt) | PASS | `study-caption-longname-photo-revealed-dark.png`, `study-caption-longname-nophoto-revealed-light.png`: name frame 223.7 × 54.3 centred on 201.0, gap 8.0 |
| Nothing else in the study screen moved | PASS | `screen-sample.py compare` before vs after: top bar (0,0,402,121) and rating row (0,766,402,874) 0 pt offset on every screen; text-prompt screens before reveal (`study-person-name`, `study-person-long-description-prompt`) 0 pt over the card |

Note on "nothing moved": on revealed cards and on the unrevealed photo prompt (`study-person-photo-light.png`), the
photo/name group sits 2 pt higher than before (`compare` over 60,140,342,540: 2 pt). It is the card re-centring a
group that is 4 pt taller (`xs` → `s`; the photo prompt reserves the answer slot by spec). Relative positions are
unchanged (photo → name 21.0 ink both) and acceptance #2/#4 (vertical centring, photo identical across reveal) still pass.
This is expected from the change, not a defect.

## Visual review (docs/design-system.md checklist), full screens
- [x] background edge to edge, light + dark (`study-caption-photo-long-revealed-light.png`, `study-caption-nophoto-long-revealed-dark.png`)
- [x] nothing competes with the centred caption, no default blue tint
- [x] circle buttons aligned (top bar unchanged, 0 pt)
- [x] long text wraps, no truncation (4-line description, 2-line name)
- [ ] Dynamic Type XL: deferred (no text-size tests until release; the 208 pt AX caption width is not exercised)

The caption now reads as one centred block under the photo: the name stands apart from the paragraph, and the
paragraph no longer leans left of the photo.

## Bugs
None.
