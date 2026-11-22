# Logo round 14: round 13 b refined (halftone back card, full-height tail, wider closing)

Brief: apply the critic's round 13 fixes to `b` (7 · 7 · 6, ITERATE): back card in the brand's halftone, tail at the
card's full height, closing zone ~150 px, no ink outside the card (design-review's new overhang check). Kept: no
neck, card 57% of the tile, closing in the last 20% of the animation, no pink, seed 23. Construction: `render.py`'s
docstring.

| Candidate | What | Critic (harmony · 58/29 px · flashcard) |
|---|---|---|
| `b` | Iteration 2: card 584 x 460 (was 388 tall), a second card behind (57 px up and right) in halftone (coverage 0.28, the front card's lattice, one pitch of paper around the front card), fading in after the front card is solid (t 0.96 -> 1), `CX=540 CY=530` | iteration 1 (44 px, 12 px gap, H 388): 7 · 7/6 · 7; iteration 2: 7 · 7/6 · 7, ITERATE (critic's pick) |
| `b-single` | `b` without the back card (`STACK=0 CX=566 CY=512`) | iteration 1: 8 · 7/6 · 5; iteration 2: 8 · 7/7 · 6, ITERATE (reads as a fade bar) |

Regenerate the PNGs, `frames/`, `strip.png` and `contact-sheet-<v>.png` (all gitignored; the sheet embeds the Vyst
icon, local only) with `uv run --script render.py` and
`STACK=0 CX=566 CY=512 OUT=b-single uv run --script render.py`. `<v>/app-icon-{1024,58,29}.png`: the static
app-icon candidate (the settled light frame). Check with
`uv run scripts/design-review.py b/card-light-1024.png --home --frames b/frames`.

Design review:
- `b-single`: PASS, still and all 8 frames. Nothing above 80% of a limit except the minimum dot gap (0.223 vs 0.2,
  the render's built-in 10% margin).
- `b`: the front layer alone (`STACK=0`) passes all 8 frames. The composite fails only overhang (56 px, 4.7%): the
  back card's own dots, which the single-card check counts as ink outside the card (the critic accepts it as an
  artefact). Iteration 1's seam flip (back card visible while the front was still closing) is gone with the late
  fade-in. Near limits: 58 px drawdown 0.039 (frame 0.65, x 274), |psi6| band step 0.229 (frame 0.5).
- Tooling requests: a stack-aware overhang (front layer only, still failing ink past the front card's corner); a
  "paper gap survives at 58/29 px" metric for stacked shapes.

Decisions:
- Pitch 11.4 px (was 10.5): `bk.closing_wall` is min(2.2, 0.194 P), so at 10.5 the closing walls were 2.03 px and
  a ~150 px closing measured 0.6–0.9% hairlines (limit 0.5); at 11.4 they are the full 2.2 px (0.07% still, 0.36%
  worst frame).
- Wider closing: a PCHIP knot (TC, 0.65), TC = 1 - 150 px / ramp; the ramp is longer (FILL 0.48, was 0.36) and the
  settling ends earlier (T2 0.38) so the dot-to-hexagon growth keeps its length (dot size step was 0.26).
- Overhang: right of the card's left edge ink is the card's silhouette only (round 13 gave edge cells half a pitch
  of room: the 7 px FAIL). A separate mark that would cross the top, bottom or right edge is dropped; web-stage
  cells are clipped crisply. The left edge is exempt (the stream enters there): testing it too cut a column of dots
  and made a coverage dip at the junction.
- Clamping loose dots inside the height during the spacing relaxation merged them at the edge (48 blobs): dropped
  ones stay dropped, as in round 13.

Critic's next round (ranked, on `b`):
1. Back card corner: place its dots on curves parallel to the front card's edge (gap 11.4 + k x 9.87 px, k = 0..3,
   11.4 px of arc between dots, alternate rows offset half a pitch), so the outer corner is a true arc (r ~117)
   instead of a lattice staircase.
2. Paper gap 2 pitches (22.8 px, ~1.3 px at 58) with a 4-row band (offset ~68 px), re-centred (imbalance <= 0.08);
   if 29 px still shows a halo, a 29 px variant with a 2-row band at coverage ~0.4.
3. Smooth the coverage ramp at x 260-290 around t 0.65 (58 px drawdown 0.039 of 0.04). `b-single` only if kept:
   solid >= 60% of the card's width.
