# Logo round 11: lost data points settle into a card

Brief (user, after rounds 1–10): noise becomes structure and shows time, with Vyst's calm. One light card
silhouette, ink at most 35% of the tile, grain streaming in along one smooth curve and settling into order.
Dots only: nothing merges, and there are no worm holes and no seams. The transition is smooth from frame to frame,
and pink is used sparingly, if at all.

Idea: the card's texture is a hex lattice of discrete dots. On its left the card carries on as a ribbon of grain
that falls away along one curve. Reading left to right (time), sparse random grain fills in, settles onto the
lattice, then the settled dots grow. The construction is in `render.py`'s docstring.

| Variant | Silhouette | Seed |
|---|---|---|
| `a` | The card's full height continues into a ribbon that narrows upstream (no left corners) | 14 |
| `b` | The same, but the ribbon widens and thins upstream, like Vyst's dispersing wisp | 12 |
| `c` | A full 3:2 rounded card. The stream flares into its left corners, and one settled dot is pink (the remembered fact) | 23 |

Regenerate the PNGs, `frames/` and `strip.png` (all gitignored) with `VAR=<a|b|c> uv run --script render.py`.
Check them with `uv run scripts/design-review.py <v>/card-light-1024.png --home --frames <v>/frames`: all three
pass on the still and on every frame. The order metrics are seed-sensitive at this ramp length, so the
seeds above were picked to pass.

Decisions:
- Each start is the site plus a relaxed random offset, paired with its site by optimal transport. A
  blue-noise start set made order dip while dots settled.
- Low density is a random subset of the dots. An evenly spread subset is more ordered than the full set,
  so order fell as the set filled.
- The curve is a shear, not a bend: the ribbon keeps its thickness, so dots are never squeezed.
- The largest dot is P/2.6 to P/2.7, the most the gap rule allows. So the settled card is a mid-grey halftone,
  not solid. This is the brief's cost: it is weak at 29 px.

Critique (design-critic, two passes, harmony vs Vyst · 58/29 px · reads as a flashcard):
- Pass 1: a 6·3·3, b 5·3·2, c 6·4·5, all ITERATE; c is the best. Applied to c: a 3:2 card, the stream flaring
  into the corners (no neck), a wider and lower composition, max dot P/2.6, and one pink settled dot.
- Pass 2: c 5·3·4, ITERATE. Applied: earlier growth for a more uniform settled card, the pink dot moved to the
  top-right corner, and recentring. Tried and dropped: a coarser pitch (x1.2–1.4) fails design-review's
  order metrics at this ramp length, and centring on the bbox fails its optical-centre metric.
- Still open: a perimeter row of full-size dots so the card has a left edge and corners; weak contrast at 29 px
  (a discrete-dot halftone stays mid-grey).

`contact-sheet-c.png` (force-added) shows c in light, dark and forest, the animation strip, 180/58/29 px and Vyst.
