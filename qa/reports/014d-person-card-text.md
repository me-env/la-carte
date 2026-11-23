# QA: 014d person card text + text prompt moves on reveal (re-validation 3)

Verdict: PASS
Date: 2026-11-23 · Simulator: iPhone 17 Pro / iOS 27 (pool simulator on the external SSD)
Branch `worktree-agent-aae3fa935b171477d` at 1b5d500 (spec ACs 1-7 under "Acceptance (QA)" in
`docs/specs/014d-notes-study.md`). Previous verdict FAIL, bugs 1-3 (git history of this file).
Run (gitignored, local): `qa/screenshots/014d-person-r3/`: NotesUITests with `--record`: **7 passed, 0 failed, 2 skipped**
(`_liveAPI`, mock run), 7.6 min. Recordings in `recordings/`, strips in `strips/`.
Not run: `scripts/e2e.sh` (no live-API change in this fix), full suite (CI; brief scoped to NotesUITests).

## Acceptance criteria (spec "Acceptance (QA)")
| # | Criterion | Result | Evidence |
|---|---|---|---|
| 1 | Hint midX = card midX ± 1, every direction, short + long | PASS | `testNotesStudy_personTextLayout`; `study-person-{name,photo,description-prompt,long-description-prompt}-{light,dark}.png` |
| 2 | Text prompt: prompt group centred before reveal, revealed group after (± 1); order photo, name, description | PASS | layout test; `study-person-*-revealed-*.png` |
| 3 | Short description: back midX = photo midX = card midX ± 1 | PASS | layout test |
| 4 | Photo prompt: photo frame identical; back top = hint's former top ± 1 | PASS | layout test; `study-person-photo(-revealed)-*.png` |
| 5 | Hint gone after reveal; Reduce Motion: question layer hidden from the tree after reveal, answer layer before | PASS | `testNotesStudy_personRevealMotion` + `…Reduced` tree checks (hint not hittable, one copy of the prompt, no answer field before reveal under Reduce Motion). Previous bugs 1 and 2 fixed |
| 6 | 3+-line description: lines start at one x, block centred on photo, width ≤ photo + 48 | PASS | layout test; `study-person-long-description-prompt-revealed-*.png` |
| 7 | Motion frame by frame: no overlap, no second copy, no jump; Reduce Motion opacity only; ends by ≈ 0.4 s / ≈ 0.5 s | PASS | below. Previous bug 3 (two copies) fixed |
| — | Dynamic Type / VoiceOver reading order | deferred | docs/testing.md |

### AC7 measurements (`recordings/testNotesStudy_personRevealMotion*.mp4`, 60 fps)
- **Name reveal** (`strips/name-reveal.png`). Tap ≈ 6.565 s. Name ink top 414 → 439.3 → 468.3 → 496.7, then the name
  bottom settles 572 → 581 → 587 → 591 → 594 → 595 → 596 → 596.7 → 597.3 (6.787 s) and holds: monotonic, no shift.
  Hint-to-name gap 27 → 14.3 → 1.7 pt (6.588 s, hint already faint, zoom crop: no touch), hint gone at 6.605 s. Photo and
  description fade in from ≈ 6.758 s with the name in place; photo luma settles at 6.937 s: **≈ 0.37 s** (≤ 0.4).
- **Long-description reveal** (`strips/long-description-reveal.png`). Tap ≈ 10.34 s. Text block top 376 → 398 → 418 →
  439 → 459 → … → 504 → 517 → 530 → 538 → 545 → … → 570 (10.620), bottom → 658.7: monotonic, steps shrinking, no shift.
  **Second copy:** on every frame only one style has ink, even at tolerance 6: prompt style (x 22.7–373) up to 10.405 s,
  nothing at 10.420 s, caption style (x 57.3–331.7) from 10.437 s. Name and photo fade in from 10.645 s with the caption
  at its end (570 of 573), no overlap. Settled by ≈ 10.80 s: **≈ 0.46 s** (≤ 0.5).
  - **Hand-over dip** (engineer's note): text is below 24/255 contrast for 4 frames (10.405–10.453, ≈ 65 ms) and fully
    blank for 1 (10.420). It reads as a fast fade-through while the block slides down, not as a flicker: the dark
    prompt dims, then the grey caption comes up, with no frame of two copies and no position jump. Not a glitch in my
    judgement, but it is the one thing to show design-critic in the clip (spec: the #7 clips go to design-critic).
- **Reduce Motion** (`strips/reduce-motion.png`). Name: question rows stay at 414/465.3, answer rows at 580.7–597 and
  609.7–625.3, photo box (81, 259.7, 321.3, 560) on every frame 18.750–18.968 s; only opacity changes, ≈ 0.2 s. Long:
  question rows 375.7–514.3 in place while fading, answer rows 547.3/576.7/598.7/620.7/642.7 fixed 23.017–23.218 s;
  ≈ 0.2 s. Before the tap the photo area is background (18.708 s, 22.990 s).

## Visual review (docs/design-system.md checklist)
Stills: `strips/person-stills-light.png`, `strips/person-stills-dark.png` (name, name revealed, long prompt, long
revealed, photo, photo revealed, description revealed, photo-long revealed).
- [x] background edge to edge, light and dark (dark renders #1A1A1A in this run, the SSD-simulator dark bug did not reproduce)
- [x] nothing competes with the centred text, no default blue tint
- [x] long text wraps, no truncation (4-line prompt and caption)
- [x] photo, name, hint centred; the caption reads as one block under the photo
- [ ] Dynamic Type XL: deferred

## Bugs
None.

## Notes
- For design-critic: the description hand-over dip above (≈ 65 ms faint, one blank frame).
- The recordings also leave "Synthesized Event …" and "UI Snapshot …" files next to the screenshots (export noise).
