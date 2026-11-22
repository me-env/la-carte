# Logo: decision brief (after rounds 12–15)

The idea: grain streams in, settles on a lattice and closes into a flashcard. The design-critic scores each
candidate against Vyst and Apple icons on harmony · legibility at 58/29 px · how much it reads as a flashcard
(each /10). The images are local and gitignored: regenerate them with each round's `render.py` (see its README).
Paths below are relative to `docs/design/brand/explorations/`.

| # | Candidate | Icon (local) | Critic | Trade-off |
|---|---|---|---|---|
| 1 | Round 15 `b`: two cards, a halftone back card on true arcs | `round15/b/app-icon-1024.png` | 7 · 6/4 · 7 (iteration 1; iteration 2 fixed the corner and the band ends, not re-scored) | The most "deck of cards", with the cleanest back card yet. At 29 px the back card turns into a grey halo. |
| 2 | Round 14 `b`: two cards, a lattice back card, 1-pitch gap | `round14/b/app-icon-1024.png` | 7 · 7/6 · 7 | Better at small sizes than round 15 `b`, but its back corner is a lattice staircase. |
| 3 | Round 14 `b-single`: one card, dots closing into solid ink | `round14/b-single/app-icon-1024.png` | 8 · 7/7 · 6 | The calmest and most legible, and it passes every check. It reads partly as a fade bar. |
| 4 | Round 15 `b-single`: a solid 3:2 card plus a detached dot trail | `round15/b-single/app-icon-1024.png` | 4 · 8/6 · 9 | Reads most clearly as a flashcard, but the trail looks like a leftover. The likely fix is to drop the trail, which leaves a plain card. |

Every candidate animates the same way: grain slides in, settles and closes. With Reduce Motion, the final frame fades
in.

## Open choices

1. **Pure dots or a solid settled card.** Round 12 `a` (`round12/a/card-light-1024.png`, never scored by the critic)
   keeps the whole card as dots. It is truest to the "data points" idea, but it has the weakest silhouette and turns
   grey at 29 px. A solid card (all of the above) gives a crisp shape and contrast; the dots then live only in the
   motion and the trail.
2. **One card or two.** Two cards say "deck" and score higher as a flashcard (7 against 6). They cost legibility at
   29 px (a halo), and the back card fails the overhang check, which the critic accepts as an artefact. One card is
   calmer and closer to Vyst's single-mark simplicity.

Recommendation: #1 if "deck" matters most; #3 if calm and small-size legibility matter most. Either one needs at
most one more round (#1: a 2-row back card for small sizes; #3: more card proportion, less bar).
