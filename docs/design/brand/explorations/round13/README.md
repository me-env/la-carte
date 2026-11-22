# Logo round 13: round 12 b refined (dots converge into a solid card)

Brief: refine round 12 b (critic 7 · 6/5 · 6, ITERATE): no neck at the junction, card at 55–60% of the tile,
shorter tail, closing in the last ~20% of the animation. No pink. Seed 23. Construction: `render.py`'s docstring.

| Candidate | What | Critic (harmony · 58/29 px · flashcard) |
|---|---|---|
| iteration 1 | Flared stream (no neck), card 57%, TAIL 220, DROP 110, closing in the last 20% | 7 · 6/5 · 5, ITERATE (lip at the junction, ragged lower flare, off-centre, grey haze tail) |
| `b` | Iteration 2: straight symmetric stream (DROP 0), nothing overhangs the card, TAIL 190, tail grain R1 = R0, plus a second card behind (44 px up-right, flat 35% tint, 12 px gap) | 7 · 7 · 6, ITERATE |
| `b-single` | `b` without the back card (`STACK=0 CX=566 CY=510`) | 7 · 7 · 5, ITERATE |

Regenerate the PNGs, `frames/` and `strip.png` (all gitignored) with `uv run --script render.py` (and
`STACK=0 CX=566 CY=510 OUT=b-single uv run --script render.py`). Check with
`uv run scripts/design-review.py b/card-light-1024.png --home --frames b/frames`. `contact-sheet-<v>.png` (local
only: it embeds the Vyst icon) shows light, dark, forest, the strip (t = 0.3 … 1), 180/58/29 px and Vyst.
`<v>/app-icon-{1024,58,29}.png`: the static app-icon candidate (the settled frame).

Design review: both candidates pass the still and all 8 frames. Near the limits: hole size CV 0.199 (0.2),
|psi6| band step 0.244 (0.25, frame 0.65), hole size rise 0.095 (0.1), hairline walls 0.448 (0.5, frame 0.95).

Critic's next round (ranked):
1. Back card in the brand's halftone (same lattice, fixed coverage 0.25–0.3), not a flat grey; keep offset and gap.
2. `TAPER` 1 (the tail keeps the card's height, only density fades), or round the taper with the card's radius.
3. Closing zone ~150 px (5 pitches, now ~91 px) to remove the seam at 180/58 px; no empty patches in the tail.

Decisions:
- A shorter ramp makes the order rise too steep (|psi6| band step up to 0.32): settling starts earlier (`OT0`
  0.05, was 0.12) with a softer ease-out (`POW` 1.6, was 3), and the tip has more grain (`H0` 0.06, was 0.03).
- Overhang: clamping dot positions onto the card's edge merged them (touching); dropping the few loose dots that
  would cross the edge passes.
- Centring: design-review's optical centre mixes centroid and bbox, so with a solid card on the right the bbox
  can't be centred (centre ~470, offset 0.017–0.020 of 0.03).
- The closing is a coverage scale above the settling stage (`squash()`), so every frame keeps the still's ramp shape.
