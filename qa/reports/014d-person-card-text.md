# QA: 014d person card text + text prompt moves on reveal (re-validation 2)

Verdict: FAIL
Date: 2026-11-23 · Simulator: iPhone 17 Pro / iOS 27 (pool simulator on the external SSD)
Branch `worktree-agent-aae3fa935b171477d` at 602a9ea, merged with main 325fdaf (spec ACs 1-7 under "Acceptance (QA)"
in `docs/specs/014d-notes-study.md`). Previous verdict FAIL, bugs 1-5 (git history of this file).
Runs (gitignored, local, under `qa/screenshots/`):
- `014d-person-r2/`: NotesUITests, `--record`: 6 passed, 1 failed (`testNotesStudy_personRevealMotionReduced`, AC5), 2
  skipped (`_liveAPI`, mock run). Recordings in `recordings/`, strips and crops in `strips/`.
- `014d-person-r2-rm/`: the Reduced test alone, with frames in the failure messages (same failures).
- `014d-person-r2-dark/`: `testNotesStudy_personTextLayout` alone, to check dark mode (see "Environment").
Not run: `scripts/e2e.sh` (no live-API change), full suite (CI; brief scoped to NotesUITests).

Test changes (`ios/LaCarteUITests/NotesUITests.swift`): the motion tests now check AC5 in the accessibility tree:
under Reduce Motion, before reveal, no photo and no other answer field, one copy of the prompt; after reveal (both
modes) the hint not hittable and one copy of the prompt. Failure messages list the duplicates' frames.

## Acceptance criteria (spec "Acceptance (QA)")
| # | Criterion | Result | Evidence |
|---|---|---|---|
| 1 | Hint midX = card midX ± 1, every direction, short + long | PASS | `testNotesStudy_personTextLayout` (6 cards), `study-person-{name,photo,description-prompt,long-description-prompt,...}-light.png` |
| 2 | Text prompt: prompt group centred before reveal, revealed group centred after (± 1); order photo, name, description | PASS | layout test; `study-person-*-revealed-light.png` |
| 3 | Short description: back midX = photo midX = card midX ± 1 | PASS | layout test |
| 4 | Photo prompt: photo frame identical; back top = hint's former top ± 1 | PASS | layout test; `study-person-photo(-revealed)-light.png` |
| 5 | Hint gone after reveal; Reduce Motion: question layer hidden from the tree after reveal, answer layer before | **FAIL** | normal motion: PASS (hint not hittable, one prompt copy). Reduce Motion: bugs 1, 2 |
| 6 | 3+-line description: lines start at one x, block centred on photo, width ≤ photo + 48 | PASS | layout test: caption starts at photo.midX − 144, ends inside +144; `study-person-long-description-prompt-revealed-light.png` |
| 7 | Motion frame by frame: no overlap, no second copy, no jump; Reduce Motion opacity only; ends by ≈ 0.4 s / ≈ 0.5 s | **FAIL** (one item) | no overlap, no jump, timings, Reduce Motion: PASS (below). Second copy: bug 3 |
| — | Dynamic Type / VoiceOver reading order | deferred | docs/testing.md |

### AC7 measurements (`recordings/testNotesStudy_personRevealMotion*.mp4`, 60 fps)
- **Name reveal** (`strips/name-reveal.png`). Tap at ≈ 8.605 s. The name's ink top (`screen-sample bands`, every frame) goes
  414 → 433.7 → 462 → 491 → 516 → 535.7 → 550 → 560.3 → 567.7 → 572.3 → 575.3 → 577.3 → 578.7 → 579.7 → 580 (8.817 s), then
  it holds. The movement is monotonic and has no one-frame shift. The hint moves with the name. The gap from the name to the
  hint goes 27 → 17.3 → 4.7 pt, and the hint is gone at 8.650 s. It never touches the name. The photo first shows at 8.805 s,
  when the name is at 580, and its bottom (559.7) stays above the name. The fade-in is over by 8.983 s: **≈ 0.38 s** ✓ (≤ 0.4).
- **Long-description reveal** (`strips/long-description-reveal.png`). Tap at ≈ 12.40 s. The bottom of the text block goes
  514.3 (before) → 535 → 553.7 → … → 652.3 (12.685) → 658.7, so it moves monotonically. Steps are ≤ 26 pt per frame and get
  smaller (spring), with no shift. The name and photo fade in from 12.707 s, when the caption is within 3 pt of its end
  (570 of 573), so nothing overlaps. The photo fade is over by 12.883 s: **≈ 0.48 s** ✓ (≤ 0.5). The rest is a sub-point
  spring tail (≤ 0.33 pt/frame) to ≈ 12.95 s.
- **Reduce Motion** (`strips/reduce-motion-name-and-long.png`). Name: the composition's rows (name 580.7–597, description
  609.7–625.3) and photo box (81, 259.7, 321, 560) are identical on every frame from 18.100 s, when they first appear, to
  18.302 s. The question fades in place. Long: the caption rows (560/576.7/598.7/620.7/642.7) are fixed from 22.148 s to
  22.352 s, and the question keeps x 22.7–353.7 until it fades. Only opacity changes, in ≈ 0.2 s ✓. Before the tap the
  photo area is pure background (17.947 s and 22.007 s: ΔE 0), so nothing shows through early.

## Visual review (docs/design-system.md checklist)
Stills: `strips/person-stills-light.png` (name, name revealed, long prompt, long revealed, photo, photo revealed,
description revealed, photo-long revealed).
- [x] background edge to edge (light)
- [ ] **dark: not verifiable in this run.** Every `*-dark.png` is light, see "Environment"
- [x] nothing competes with the centred text, no default blue tint
- [x] long text wraps, no truncation (4-line prompt and caption)
- [x] photo, name, hint centred, and the caption reads as one block under the photo
- [ ] Dynamic Type XL: deferred

## Bugs
1. **Reduce Motion: the hint stays in the accessibility tree and stays hittable after reveal.**
   - Steps: Reduce Motion on. Study `name → photo + description` ("Theo Lane"), tap Show answer, wait 1.5 s.
   - Expected (AC5): `study.answerHint` is not hittable, because the question layer is `accessibilityHidden` after reveal.
   - Actual: `study.answerHint` exists and is hittable at (121.8, 618, 158.3 × 18). That is below the revealed description,
     inside the composition layer, not where the visible hint was (≈ 465). The long-description card has the same fault
     at (140.5, 675.3, 121 × 18).
   - The same check passes with Reduce Motion off.
   - Evidence: `014d-person-r2-rm/logs/NotesUITests_testNotesStudy_personRevealMotionReduced.txt`, NotesUITests.swift:444.
2. **Reduce Motion, description prompt: the description is in the accessibility tree twice, before and after reveal.**
   - Steps: Reduce Motion on. Study `description → photo + name` with a 4-line description.
   - Expected (AC5): one copy. The answer layer is hidden before reveal, and the question layer after.
   - Actual, before reveal: two static texts with the description's label, at (22.3, 370.8, 357.3 × 110.3) (prompt style)
     and (57, 382.8, 280.3 × 86.3) (the caption style of the question's CrossFadeStack, opacity 0).
   - Actual, after reveal: two copies, both at (22.3, 561, 357.3 × 110.3).
   - The hidden style of the CrossFadeStack is not `accessibilityHidden`. The name prompt has 1 copy before and after.
   - Evidence: NotesUITests.swift:433 and :446, same log.
3. **Normal motion, description prompt: two copies of the text show together for 4 frames (AC7 "no second copy").**
   - Steps: Study `description → photo + name` with a 4-line description, tap Show answer.
   - Actual: from 12.420 s to 12.483 s (≈ 70 ms), the fading prompt style (x 22.7–373, 4 lines) and the incoming caption
     style (x 57–331, 4 lines) are both clearly visible. They are centred on the same frame but not aligned with each
     other, so the paragraph looks doubled or ghosted. See `strips/long-crop-12.433.png`, `long-crop-12.465.png` and
     `long-description-reveal.png` frames 12.450 and 12.483.
   - The copy no longer flies elsewhere, so the previous bug 3 is fixed. But this overlay is a second copy of the prompt
     text on screen, which AC7 rules out on every frame.
   - It follows from the spec's own CrossFadeStack design (prompt fades out over 0.15 s while the caption fades in over
     0.2 s). The fix is either to sequence the two styles so they don't overlap visibly (caption in only once the prompt
     style is almost gone), or to have the architect and design-critic amend AC7 to allow a short in-frame style
     cross-fade. Not shippable as is: the spec rules it out.

Previous bugs: 1 (hint jumps above the name), 2 (photo overlaps the name), 4 (Reduce Motion moves) and 5 (long reveal too
slow) are fixed. 3 (copy flies over the photo) is fixed, and its remaining in-place overlap is new bug 3.

## Environment (not an app bug)
`XCUIDevice.shared.appearance = .dark` has no effect on the pool simulator since the move to the SSD. Every
`*-dark.png` in `014d-person-r2/` and `014d-person-r2-dark/` is light (#F9FAF5 at 200,700). Another agent's run at
01:50 (`qa/screenshots/qa-red-local/deck-person-added-dark.png` on main) shows the same. Runs on 2026-11-22, before
the move, rendered dark (#1A1A1A). Dark mode for 014d stays unverified until this is fixed. Owner: dev-velocity.

## Notes
- The recordings also leave "Synthesized Event …" and "UI Snapshot …" files next to the screenshots (export noise, harmless).
