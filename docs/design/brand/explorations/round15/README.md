# Logo round 15: round 14 b refined, b-single redrawn as a card

Brief: apply the critic's round 14 steps to `b` (back-card corner as a true arc, a 2-pitch gap, smooth the 58 px
dip). Make `b-single` read as a card, not a fade bar (about 3:2, a visible corner radius, clear separation from the
trail). Kept: pitch 11.4, seed 23, no neck, closing in the last 20% of the animation. Construction: `render.py`'s
docstring.

| Candidate | What | Critic (harmony · 58/29 px · flashcard) |
|---|---|---|
| `b` | Round 14 b. The back card's halftone now sits on 4 rows parallel to the front card's edge, so the outer corner is a true arc (r ≈ 119). Paper gap of 2 pitches, re-centred (`CX 532 CY 531`). Iteration 2: the same dot count per row through the arc (equal angle, odd rows offset half a step) and band ends cut square on one line | iteration 1: 7 · 6/4 · 7, ITERATE (shown to the user); iteration 2: not re-scored |
| `b-single` | `SINGLE=1`: a whole rounded card, 560 x 374 (3:2), RC 80, solid at rest. To its left, a grain-dot trail that stops 2 pitches before the card and never grows past dots | 4 · 8/6 · 9, ITERATE. Reads most as a flashcard, but the trail looks like a leftover block and is a smudge at 58/29 px |

Regenerate everything with `uv run --script render.py` and `SINGLE=1 uv run --script render.py`. That writes
`<v>/card-*.png`, `<v>/app-icon-{1024,58,29}.png` (the settled light frame), `frames/`, `strip.png` and
`contact-sheet-<v>.png`. All of it is gitignored, and the sheet embeds the Vyst icon, so it stays local.

Design review (`--home --frames`):
- `b`: all 7 animation frames before the still PASS. The still fails **only overhang** (60 px, 4.6%). **That failure
  is ignored on purpose**: the check treats the back card's dots as ink outside the front card. The critic will not
  waive a FAIL itself, so it needs a stack-aware check (tooling request below). The 58 px drawdown fell from 0.039
  to 0.020 on the still and to 0.027 at worst across frames (limit 0.04). The fix was re-centring, which moved the
  58 px sampling grid; the ramp itself is unchanged.
- `b-single`: the whole-mark continuity metrics (coverage step and 2nd diff, front swing, empty band) fail by design
  at the 2-pitch gap. Each part checked on its own region:
  - Trail still (`--region 40,410,272,618`): PASS, apart from the optical centre, which is an artefact of the region.
  - Card interior frames (`--region 320,410,830,618`): 6 of 8 PASS. The 2 FAILs are region-boundary artefacts.
  - Whole still: overhang PASS (1 px), centre PASS.
  - The critic does not accept a piecewise review: a solid card with a gap can't meet the continuity rule.

Decisions:
- The back card uses equal angle per row instead of an equal 11.4 px of arc. With equal arc length the inner rows
  bunched and lost their half-pitch offset in the corner.
- The band ends are cut square (x >= XL + STACK, y <= bottom - STACK). With rounded ends the rows were staggered by
  about 40 px.
- `b-single`'s ramp now closes inside the paper gap (UB = XL - 2P), so the card is solid at rest. The trail's order
  is capped (at most 0.75), so its last column doesn't read as a fence.

Critic's open items:
- `b`: the dark vertical stripe at x 375-410, where the dots turn into holes (the metric passes; the eye sees a
  band). At 29 px the back card turns into a grey halo. The critic suggests a 29 px variant with a 2-row band.
- `b-single`: drop the trail (a plain card), or join it to the card as `b` does.

Tooling request: a stack-aware overhang check in `design-review.py` (the front layer only, or the back card as its
own element), and a parts mode for marks with a deliberate gap (each part checked against its own rules).
