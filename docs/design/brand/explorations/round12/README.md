# Logo round 12: lost data points settle into a card, with a silhouette

Brief: same as round 11 (noise becomes structure and shows time, Vyst's calm, one light card, grain streaming in
along one curve and settling, discrete dots during the transition, pink tiny or absent). The fix for round 11 c
(critic 5·3·4: a mid-grey halftone with nothing to anchor the eye, read as a comet or boot): give the settled card
a clear silhouette. The user picks between dots only (a) and solid ink (b).

| Variant | Settled card | Seed |
|---|---|---|
| `a` | Pure dots. The ramp ends at the card's left edge, so the whole card is full-size dots (P/2.6). Its outline rows (left and right lattice columns, top and bottom rows) sit exactly on the inset rounded rectangle: W and H snap to the lattice | 23 |
| `b` | Solid ink. Past the settled lattice the marks grow into rounded hexagons and close into the lattice's own cells (`brandkit.mark_shape` / `raster`), solid from 35% of the card's width; the card edge is a crisp rounded rectangle | 23 |

No pink in either. The stream enters the straight part of the card's left edge (no flare), so the card keeps all
four corners. Construction: `render.py`'s docstring.

Regenerate the PNGs, `frames/` and `strip.png` (all gitignored) with `VAR=<a|b> uv run --script render.py`.
Check with `uv run scripts/design-review.py <v>/card-light-1024.png --home --frames <v>/frames`.
`contact-sheet-<v>.png` (local only: it embeds the Vyst icon) shows light, dark, forest, the animation strip,
180/58/29 px and Vyst.

Design review: `a` passes the still and every frame. `b` passes the still; on 2 of 6 frames the column where the
web stage starts fails `touching: min gap` (0.112): brandkit's closing starts its web at coverage 0.625, while the
tool allows marks 1.1 px apart only from 0.65. Holding full walls longer or jumping the coverage there moved the
failure but did not remove it.

Decisions:
- Minimum spacing: every frame, pairs of moving dots closer than the gap rule (+10%, +0.5 px for the tiny ones)
  are pushed apart. That fixes round 11's two touching dots, which came from settling paths crossing.
- `a`: a free perimeter ring of dots (evenly spaced on the outline) was tried first: the gap between ring and
  lattice made a coverage drawdown and an order dip at the left edge. Snapping the card to the lattice gives the
  same outline with no gap.
- `a`: P/2.5 dots measure under the gap rule once anti-aliased; P/2.6 is the densest that passes.
- Start jitter J = 0.65 P (was 0.9) and settling to T2 = 0.72: with the card settled at its left edge the ramp is
  shorter, and the order rose too fast on the animation frames.
- `b`: marks below the solid stay whole: those the card edge would cut are dropped, and the mask gives the
  zig-zag edge row half a pitch of room until coverage 0.9 (else the edge cells close up as isolated blobs).
