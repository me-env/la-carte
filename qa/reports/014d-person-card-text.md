# QA: 014d person card text (centred caption, name first) + text prompt moves on reveal

Verdict: FAIL
Date: 2026-11-22 · Simulator: iPhone 17 Pro / iOS 27 · Branch `worktree-agent-aae3fa935b171477d` (941d334, 27a2863)
Spec: `docs/specs/014d-notes-study.md` → "Person card text…" and "Text prompt: the question moves on reveal"
Runs (gitignored, local):
- `qa/screenshots/014d-person-regress/`: NotesUITests + StudyUITests + StudyLengthsUITests, `--split 4`. 19 passed, 4 skipped,
  1 failed (`testNotesStudy_photoAnswerAndEmptyFieldSkipped`: a test race, fixed and re-run green in `014d-person-fix/`)
- `qa/screenshots/014d-person/`: `--record` motion run (`recordings/*.mp4`, frame strips in `strips/`)
- `qa/screenshots/014d-person-layout/`: first layout run (same screenshots)
Not run: `scripts/e2e.sh` (no live-API change in this design), full suite (CI; brief scoped to these classes).

New tests (`ios/LaCarteUITests/NotesUITests.swift`, stub server, made-up people, one note per direction):
- `testNotesStudy_personTextLayout`: 6 cards (photo, name and description prompts, short and 3+-line descriptions),
  light + dark, frames read after the reveal settles.
- `testNotesStudy_personRevealMotion` / `…Reduced`: name and long-description reveals for `--record`; the Reduced
  variant switches Settings › Accessibility › Motion › Reduce Motion on, then off again at the end.
- `testNotesStudy_photoAnswerAndEmptyFieldSkipped` updated: the description prompt now ends below the photo, and the
  frames are read after the 0.35 s reveal.

## Acceptance criteria (spec "Acceptance (QA)")
| # | Criterion | Result | Evidence |
|---|---|---|---|
| 1 | Hint midX = `study.card` midX ± 1 before reveal, every direction, short + long | PASS | layout test; hint (122…280) on card (16…386), midX 201 |
| 2 | After reveal (short description), `study.back` midX = `study.photo` midX = card midX ± 1 | PASS | layout test, all 3 short cases |
| 3 | Photo prompt: `study.photo` frame identical before/after reveal | PASS | layout test (80,253.7,242,302 both); `study-person-photo(-revealed)-*.png` |
| 4 | Photo prompt: `study.back` top = hint's former top ± 1 | PASS | 570.67 = 570.67 |
| 5 | Text prompt: prompt group (`study.front` + hint) vertically centred in card ± 1 before reveal | PASS | layout test, 4 text-prompt cases; `study-person-name-*.png`, `study-person-long-description-prompt-*.png` |
| 6 | Text prompt: revealed group (photo top → back/front bottom) vertically centred ± 1 | PASS | layout test; `study-person-name-revealed-*.png` |
| 7 | Order photo, name, description, every direction | PASS | layout test; all `*-revealed-*.png` |
| 8 | `study.front` kept on the prompt field after reveal | PASS | name prompt: front = name row; description prompt: front = description row |
| 9 | Hint gone after reveal | PASS | layout test (not hittable / absent) |
| 10 | 3+-line description: lines start at one x, block centred on photo, width ≤ photo + 48 | PASS | `screen-sample bbox` per line on `014d-person-regress/study-person-long-description-prompt-revealed-light.png`: lines start at x 57.3/57.3/58.3/57.7, block 57…345 (288 pt) midX 201 = photo ink midX 201 (photo 81…321, 240×300) |
| 11 | Name `.cardFaceSmall` ink, description `.body` secondaryInk, name prominent | PASS (by eye) | `*-revealed-light/dark.png`: dark name, grey caption |
| 12 | The reveal is animated, prompt moves into the composition (0.35 s) as one view | **FAIL** | bugs 1–3; `strips/name-reveal.png`, `strips/long-description-reveal.png` |
| 13 | Reduce Motion: cross-fade in final place, no move | **FAIL** | bug 4; `strips/reduce-motion-name-and-long.png` |
| 14 | Basic cards: question never moves on reveal | PASS | StudyUITests + StudyLengthsUITests green |
| 15 | `study-person-*` set light + dark + long-description card | PASS | `014d-person-regress/study-person-*.png` (24 new + existing set) |
| — | Dynamic Type / VoiceOver order | deferred | docs/testing.md |

## Visual review (docs/design-system.md checklist), still states
- [x] background edge to edge, light + dark
- [x] nothing competes with the centred text, no default blue tint
- [x] long text wraps, no truncation (4-line caption, 4-line prompt)
- [x] photo, name, hint centred on the column; caption reads as one block under the photo
- [ ] Dynamic Type XL: deferred
- Note (no bug): the photo prompt's revealed composition sits 23 pt lower than the text prompts' (photo top 177 vs 154 in
  the grid) because the photo prompt keeps its reserved slot (spec: photo prompt unchanged). Visible when cards of
  different directions follow each other.

## Motion (recordings, `scripts/image-ops.py strip`)
design-critic (independent sub-agent, from the strips): **NOT YET**. It confirms bugs 1–4 below independently, and adds
that the long reveal is still settling ≈0.4 s after the tap (spec total ≈0.35 s) and that "no Apple app shows doubled
text or text sliding over a photo; it reads as glitchy". Static end states are good.

## Bugs
1. **Name prompt: the fading hint jumps above the name.** Study a person card `name → photo + description`
   ("Theo Lane"), tap Show answer. Expected: the hint fades out where it was (under the name, 0.15 s). Actual: from
   the first frame after the tap (≈14.39 s) until ≈14.46 s, "Photo and description?" is drawn ~90 pt higher, above the
   moving name (where the photo will be), fading there. `strips/name-reveal.png` frames 14.393–14.460.
2. **Name prompt: the fading-in photo overlaps the moving name.** Same card. Expected: inserted rows fade in as room
   opens, nothing overlaps the moving text. Actual: 14.48–14.56 s the photo's bottom edge sits on/under "Theo Lane"
   while both still move (photo top also slides from ~105 to ~68 in the strip). `strips/name-reveal.png`.
3. **Description prompt is replaced by a copy, and the old copy flies over the photo.** Study `description → photo +
   name` with a 4-line description, tap Show answer. Expected: the description moves down as one view into its caption
   row, its style cross-fading (`.contentTransition(.opacity)`); it never leaves the screen and is not replaced by a copy.
   Actual: the prompt-style text slides **up** (from y≈357 to the top of the card) and fades out over the photo, while
   a second caption-style copy fades in at the bottom and slides up into place; two copies of the text are on screen
   for ≈0.25 s, the outgoing one drawn across the photo (19.27–19.51 s). `strips/long-description-reveal.png`.
4. **Reduce Motion still moves.** Reduce Motion on (Settings, confirmed in the clip), same two cards. Expected: no move, no
   morph; the question group fades out and the composition fades in, in its final place. Actual: both the outgoing
   question and the incoming composition slide up ~40–60 pt while cross-fading (name: "Theo Lane" 127 → 84 in the
   strip between 23.17 and 23.32 s; long description: the text and the photo slide up between 28.39 and 28.63 s).
   `strips/reduce-motion-name-and-long.png`.
5. **Long reveal longer than spec (minor, re-check after 3):** still settling ≈0.4 s after the tap (19.21 → 19.61 s)
   against ≈0.35 s total. Likely a consequence of the double-copy fade in bug 3.

## Notes
- XCUITest reports a 3+-line `Text`'s frame as its widest line (57…337), not the 288 pt block, so the block is checked as
  "text starts at photo.midX − 144 and ends inside photo.midX + 144".
- The photo is a grey placeholder for ~0.1 s after reveal before the image fades in (no prefetch: spec out of scope).
