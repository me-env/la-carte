# Logo ideation with image generation (2026-11-22)

Fast, wide ideation for the la-carte logo with the OpenAI Images API, in critic-reviewed rounds. The user picks
one; design-lead then redraws it cleanly as SwiftUI `Shape`s and SVG. These images are sketches, not assets:
nothing generated here ships.

- Model: `gpt-image-2.6-flare`, quality `medium`, `1024x1024`, one image per call, about $0.044 per image
  (cost computed from the API's token usage at $5/1M text input and $30/1M image output).
- Key: read at runtime from `~/.config/la-carte/openai_api_key`, never printed or committed.
- Output: `<external SSD>/la-carte/marketing/logo-ideation/2026-11-22/`. Round 1 is at the top level, rounds 2+ are in
  `round-N/`. Each folder holds the images (`NN-V.png` = direction NN, variation V), a `.txt` prompt per image,
  `cost.json`, `sheet-NN.png` per direction, `overview.png` and `overview-small.png` (58 px and 29 px).
  `shortlist.png` and `shortlist-small.png` are at the top level. Images never go into the repo.

```bash
uv run docs/design/brand/explorations/ideation-gen/generate.py <out-dir> --round N [--only 3,7] [--dry-run]
uv run docs/design/brand/explorations/ideation-gen/generate.py <out-dir> --shortlist R2-2.3,R1-8.3  # sheet only, no API
```
Existing images are skipped, so a re-run only pays for missing ones. Each round stops at a $4.50 budget.

## Rounds and spend (user budget $20 in total, about $5 kept in reserve for after the pick)

| Round | What | Images | Spend |
|---|---|---|---|
| 1 | 12 broad directions x 5 | 60 | $2.66 |
| 2 | Knowledge graph in a card (user priority, 10 + 5) and critic refinements of R1 8.1, 8.3, 7.1, 9.4, 4.2/4.5 | 32 | $1.43 |
| 3 | The user's seeds R1-8.3 and R1-12.1, graph in a card (from R2-2.3), and their combinations | 36 | $1.61 |
| 4 | User's pick: R1-8.3 shaped as a card (dots trace a card outline, settled dot placed 5 ways), 25 + 6 dark retries | 31 | $1.39 |
| | **Total** | **159** | **$7.09** |

The user's seeds from round 1:
- **R1-8.3**, direction 8 "Dots gathering / settling", variation 3: "A ring of 24 small dots like a dial, with one larger
  dot settled at the bottom." Forest palette.
- **R1-12.1**, direction 12 "Abstract calm mark", variation 1: "A circle and a rounded rectangle overlapping, the
  overlap cut out (negative space), balanced." Paper and ink palette.

Prompt lessons: the model adds glow on dark palettes unless "strictly flat, no glow" ends the prompt; "landscape card"
draws a landscape photo (round 3 says "horizontal rounded-rectangle card, wider than tall" instead).

## Critic-approved shortlist (`shortlist.png`, numbered 1-9)

1. R2-2.3: a graph in a portrait card, with two dots settling in. 2. R3-1.2: the same on a horizontal card with a three-dot trail.
3. R1-8.3: a ring of 24 dots, one settled. 4. R1-12.1: a circle and card overlapping, the overlap cut out. 5. R3-1.8: a bold six-node graph in a
card. 6. R3-4.2: an arc of dots curving into a graph card. 7. R2-2.1: a square graph in a card, with dots beside it. 8. R3-6.1: a dot ring on a card.
9. R3-4.1: a dial ring around a graph card (a combination, shown for reference).

## Round 4: the user's pick, "8.3 shaped as a card"

The user dropped the graph idea and chose R1-8.3, reshaped as a card. Round 4 (`round-4/`) has 5 directions: the
settled dot on the bottom edge, in a corner, inside the card, falling into it, and tilted/stacked/accent variants.
Three palettes: forest, paper and ink, and dark. "Near-black" made every dark image glow like light bulbs, even with
the flat reminder; "matte dark graphite (#232325) ... printed like ink on dark card stock" fixed 4 of 6 (the glowing
ones are in `round-4/glow-rejects/`, and 1.6 and 4.3 still glow).

The critic's shortlist is in `round-4/shortlist.png` and `shortlist-small.png`:
1. R4-1.1, forest, 24 dots
2. R4-5.3, the same mark in dark
3. R4-5.4, the settled dot in amber instead of larger
4. R4-1.5, light
5. R4-2.1, the settled dot in a corner
6. R4-5.2, a dotted card on a solid card behind it

The critic rejected the landscape cards (they read as a marquee, ticket or tag) and the big dot inside the card (it
reads as a phone's home button).

### Clean redraw of #1 (`dotcard.py`, `dotcard-{forest,light,dark}.svg`)

`uv run dotcard.py out.svg --edges 4,6 --dot 0.62 --settled 1.5 --height 0.7103 --drop -0.0078` builds the
construction from the pitch p:
- Shape: a rounded rectangle whose perimeter is exactly 24p. The straight top and bottom edges are 4p, the straight
  sides are 6p, and the corner radius is 2p/pi, so each corner arc is exactly 1p long.
- Dots: 24 equal dots placed every p of arc length, starting at the bottom centre. That gives 5 dots on top, 7 on
  each side and 5 on the bottom, with no dot on the corner arcs, so the spacing is perfectly even.
- Dot size: diameter 0.62p.
- The settled dot: the bottom-centre dot, 1.5x the diameter, at the same pitch.
- Icon placement: p = 100 px in the 1024 icon, card 527 x 727 (about 5:7), side margins 217 px.

**Smoother corners (user feedback: "smaller dots on the round corners"), `dotcard-round-{forest,light,dark}.svg`.**
The critic's pick from `round-4/clean/corners-compare.png` (#0 current, #1 to #3 variants; home previews in
`corners-home.png`) is #1:
- Construction: `--edges 3,5 --arc 2 --corner-scale 0.75 --corner-end 0.75`.
- Corner arcs: 2 pitches long (radius 1.27p).
- Dots: still 24, at a constant arc-length pitch. The 2 dots on each arc are 0.75x, and only the settled dot is
  bigger (1.5x).
- Rejected alternatives: extra dots on 1-pitch arcs made bead-like clumps (first try in
  `round-4/clean/corners-try1/`); 0.6x corner dots fade out at 58 px; a 20-dot version with an apex dot reads as a
  capsule or phone.
- The scaling rule (`--corner-scale`, `--corner-end`) is the same in SwiftUI: each dot's size is a function of its
  arc-length distance to the corner apex.

`--edges 2,4` builds a 16-dot master for small sizes, in case 29 px needs it.

It maps 1:1 to a SwiftUI `Shape`:
- In `path(in:)`, take p = rect.height / (6 + 4/pi). Walk a `RoundedRectangle(cornerRadius: 2p/pi)` path by arc
  length (the same segment walk as `perimeter_point`), and add an ellipse per dot.
- The dot diameter and the settled scale come from the shared dot tokens. `DotRing` in `ConfidenceDots.swift` is
  already meant to share its dots with the logo.
- Animating `order` (as in `DotRing`) or moving the settled dot along the path gives the "dots settle into a card"
  motion for launch and transitions.

On the clean render, `scripts/design-review.py --home` passes optical centre (0.004), margins (217/217 and 109/110)
and touching (no merged dots). It fails the coverage-ramp, front and "overhang past the card" metrics. Those metrics
belong to the previous halftone-in-a-card logo and do not apply to a dotted outline. The home-screen preview reads as
a dotted card at icon size.

## Prompts

Each prompt is `STYLE + Concept + Palette`; from round 2 on, it also ends with the flat/no-glow reminder.

STYLE: Flat vector iOS 26 app icon, square 1024x1024 artwork filling the canvas edge to edge (no rounded-corner mask, no device mockup, no drop shadow around the icon, no text, no letters unless the concept is a letterform). One simple idea, two or three flat colors, generous margins, geometric shapes, crisp edges, must read clearly at 29 pixels. Calm, minimal, quiet, premium, like a first-party Apple utility icon. Original mark: do not imitate any existing brand or app icon.

Flat reminder (rounds 2+): Strictly flat: no glow, no blur, no gradients, no shadows, no 3D, no texture; solid fills only.

Palettes, rotated by variation number (rounds 1-2):
1. Warm off-white paper background (#F4F1EA), near-black ink shapes (#1C1C1E).
2. Near-black background (#121214), warm paper-white shapes (#F2EFE8).
3. Deep forest green background (#1F3A2E), cream shapes (#EFE9DC).
4. Soft paper background (#F4F1EA), ink shapes with a single small accent in muted forest green (#2F5D45).
5. Ink background (#1C1C1E), paper-white shapes with one small warm amber accent dot (#E3A64A).

Round 3 palettes (near-black kept for only one slot, because dot motifs on black sit close to the reference app):
1. Warm off-white paper background (#F4F1EA), near-black ink shapes (#1C1C1E).
2. Deep forest green background (#1F3A2E), cream shapes (#EFE9DC), and deep forest green for marks drawn on cream.
3. Paper background (#F4F1EA), ink card (#1C1C1E) with paper-colored marks, and one tiny muted amber accent (#E3A64A) at most.
4. Deep forest green background (#1F3A2E), cream shapes (#EFE9DC), one tiny muted amber accent (#E3A64A) at most.
5. Near-black background (#121214), warm paper-white shapes (#F2EFE8).

## Round 1 concepts

### R1-1. Single card
- 1.1: A single flashcard: a rounded rectangle in landscape 3:2 proportion, centered, slightly above center, nothing else.
- 1.2: A single index card in landscape proportion with one thin horizontal rule near its top, like a ruled index card.
- 1.3: A single rounded card tilted about 8 degrees, floating, with a very soft flat shadow shape beneath.
- 1.4: A single card in landscape proportion whose lower-right corner is gently folded up, showing the back.
- 1.5: A single card outlined with a thick even stroke (no fill), rounded corners, centered.

### R1-2. Stacked cards
- 2.1: Three cards stacked with small vertical offset, only their top edges visible behind the front card.
- 2.2: Two cards: a front card and one behind it offset up and to the right, back card a lighter tone.
- 2.3: A neat deck of cards seen slightly from above, the edges forming thin parallel lines along the bottom.
- 2.4: Three cards stacked, each smaller than the one in front, receding upward, like a tidy pile.
- 2.5: Two overlapping cards where the overlap region is a third tone (transparency effect), simple geometry.

### R1-3. Fanned cards
- 3.1: Three cards fanned from a common bottom pivot, like a hand of playing cards, blank faces.
- 3.2: Two cards fanned at a small angle, the back card peeking out to the left.
- 3.3: Five thin card silhouettes fanned in a quarter circle, evenly spaced, minimal.
- 3.4: Three cards fanned, the middle one solid ink, the outer two outlined only.
- 3.5: A fan of cards forming an arc that reads like a sunrise, blank faces.

### R1-4. Card + dot
- 4.1: A single landscape card with one solid dot at its center.
- 4.2: A single card with one dot sitting just above its top-right corner, as if about to land.
- 4.3: A card with one dot in the lower-right corner, like a completion mark.
- 4.4: A card outline with a solid dot inside, offset to the left, like a bullet point.
- 4.5: A card and a dot side by side, the dot exactly as tall as a third of the card.

### R1-5. Letterform c / lc
- 5.1: A lowercase letter 'c' built from a thick rounded stroke, with a small card shape nested in its opening.
- 5.2: The letters 'lc' as a geometric monogram, thick uniform strokes, the l drawn as a tall card edge.
- 5.3: A lowercase 'c' formed by a ring of evenly spaced dots, open on the right.
- 5.4: A lowercase 'c' whose opening is closed by a small rectangle card.
- 5.5: A bold geometric 'c' cut out of a card shape (negative space letter).

### R1-6. Flipping card
- 6.1: A card mid-flip, shown as a narrowing parallelogram with a curved motion arc beside it.
- 6.2: Two halves of a card: left half one tone (front), right half the other tone (back), split vertically.
- 6.3: A card rotating in 3D, seen edge-on at an angle, with a thin circular arrow arc around it.
- 6.4: A card with its top-right corner peeled over to show a differently colored back.
- 6.5: Two cards in sequence: one flat, one turned showing its back tone, simple flip suggestion.

### R1-7. Card turning into a dot
- 7.1: A sequence left to right: a card, a smaller rounded square, a circle, a dot - morphing shape, evenly spaced.
- 7.2: A card whose right edge dissolves into a row of shrinking dots.
- 7.3: A rounded card shape with corner radius so large it is nearly a circle, with a small dot beside it.
- 7.4: A card collapsing into a single dot, shown as concentric rounded shapes shrinking toward the center.
- 7.5: Half of the shape is a card corner, the other half rounds into a circle - a card-circle hybrid silhouette.

### R1-8. Dots gathering / settling
- 8.1: Scattered dots in the upper area gathering and settling into a neat grid that forms a card shape at the bottom.
- 8.2: A card shape made entirely of an even dot grid, a few loose dots above it drifting down.
- 8.3: A ring of 24 small dots like a dial, with one larger dot settled at the bottom.
- 8.4: Dots falling into a card like grains into a tray, the card filling halfway with a dot pattern.
- 8.5: A dotted card outline (dotted border) with a solid dot in the center.

### R1-9. Spacing / memory rhythm
- 9.1: A row of dots with gaps doubling between them left to right (spaced repetition rhythm), on a single baseline.
- 9.2: Concentric arcs with increasing spacing, like ripples of memory, minimal.
- 9.3: Three card silhouettes spaced farther and farther apart along a horizontal line.
- 9.4: A simple ascending curve made of dots, the dots spacing out as the curve flattens (forgetting curve).
- 9.5: Vertical bars of a card stack with widening gaps, like a calm rhythm.

### R1-10. Bookmark / tab
- 10.1: A card with a small bookmark ribbon hanging from its top edge.
- 10.2: A single bookmark ribbon shape with a notched bottom, centered, nothing else.
- 10.3: An index card with a small tab sticking up from its top-left, like a file divider.
- 10.4: A card whose top-right has a folded tab marking the place.
- 10.5: A ribbon bookmark tucked into a stack of two cards.

### R1-11. Ink on paper
- 11.1: A single solid ink dot on a paper card, the dot slightly organic as if pressed from a stamp.
- 11.2: A card with one brush-like ink stroke across it, but kept flat and geometric.
- 11.3: A drop of ink falling onto a card, flat shapes.
- 11.4: A paper card with an ink fill rising from the bottom to two thirds, like a progress level.
- 11.5: A fountain-pen nib shape whose slit forms a card outline, minimal.

### R1-12. Abstract calm mark
- 12.1: A circle and a rounded rectangle overlapping, the overlap cut out (negative space), balanced.
- 12.2: A horizon line under a card, like a card resting on a calm sea, very minimal.
- 12.3: A rounded square split diagonally into two tones, one corner holding a dot.
- 12.4: A card shape over a large soft circle (like a sun), two tones only.
- 12.5: Two parallel rounded bars of different lengths, like a question line and a shorter answer line, on a card.


## Round 2 concepts

### R2-1. Knowledge graph in a card
- 1.1: A single landscape card containing a small graph of 5 solid dots joined by thick straight lines, like a calm constellation.
- 1.2: A card holding 4 dots connected in a simple diamond with one diagonal link; thick edges, large nodes.
- 1.3: Left side: 3 loose scattered dots outside the card; right side: inside the card the dots are connected into an ordered graph.
- 1.4: A card with a 3x2 lattice of dots, some neighbours joined by thick short links, one dot slightly larger as the hub.
- 1.5: A card whose content is a triangle of 3 large dots connected by thick lines, very minimal.
- 1.6: A card containing 6 dots: 3 still loose at the top, 3 settled at the bottom and joined by links.
- 1.7: A card with one central hub dot linked to 4 surrounding dots (star graph), thick lines, generous spacing.
- 1.8: A tilted card on which 5 dots and 5 links form a small constellation, one dot in an accent color.
- 1.9: A card outline whose four corners are nodes, plus one centre node linked to them (the card itself is the graph).
- 1.10: Two stacked cards, the front one holding a tiny graph of 4 connected dots.

### R2-2. Graph in a card, refined (from 1.3 / 1.8)
- 2.1: Left: three loose dots outside a card. Right: a solid landscape card on which 4 large dots are joined by thick links into a simple graph. Max 7 dots total.
- 2.2: A solid landscape card with a constellation of 5 large dots and 4 thick links forming an open tree; one dot in the accent color.
- 2.3: A solid card whose face shows 4 dots linked as a square with one diagonal; two loose dots drift toward it from above.
- 2.4: A card made of a graph: its 4 corners and 2 mid-edge points are large nodes joined by thick links, the interior empty, landscape 3:2.
- 2.5: Dots settling into order: top half 3 scattered dots, bottom half a card with 3 dots in a row joined by a thick line.

### R2-3. A. Dots settle into a card grid (from 8.1)
- 3.1: A 4x3 grid of large dots forming a landscape 3:2 card shape (outline implied, no border), with 3 loose dots of the same size above it on a gentle diagonal. Max 16 dots, grid within 60% of canvas width.
- 3.2: A 4x3 grid of large dots forming a landscape card; the top-right grid cell is empty and one dot is falling toward exactly that empty spot.
- 3.3: A 4x3 dot grid card where the dots in the bottom rows are solid and the top row dots are smaller, as if still settling; 2 loose dots above.
- 3.4: A 4x3 grid of large dots forming a card, with 4 loose dots above it, ink on paper, very calm and sparse.
- 3.5: A 4x3 grid of large dots forming a landscape card shape with one dot mid-fall above its missing top-right cell; nothing else.

### R2-4. A x B. Settling dots + dial arc
- 4.1: A solid landscape card at the bottom center; above it an arc of 8 dots (part of a circle) leading down into the card, dots growing slightly in size toward the card.
- 4.2: A 4x3 dot grid card with a quarter-circle arc of 5 dots sweeping into its top-left corner.
- 4.3: A ring of 12 large dots with a solid landscape card in the center; the bottom dot of the ring is larger and touches the card's bottom edge.

### R2-5. B. Dial ring (from 8.3)
- 5.1: A ring of 12 large evenly spaced dots with a solid landscape card in the center; the bottom ring dot larger, in the accent color.
- 5.2: An arc of 12 dots spanning about 270 degrees, dots growing larger toward one end, where one big dot has settled; reads as a dial, not a loader.
- 5.3: A ring of 12 large dots around one big solid center dot, very calm.

### R2-6. C. Card becomes a dot (from 7.1)
- 6.1: Diagonal from top-left to bottom-right: a large landscape card, then a smaller rounded square, then a circle, then a dot, each scaled by x0.62 with equal gaps, filling the square.
- 6.2: A big landscape card with a single dot beside its lower-right corner, the dot diameter equal to the card's corner radius, as if the corner condensed into the dot.

### R2-7. D. Forgetting curve meets a card (from 9.4)
- 7.1: Five large dots on a rising curve with gaps growing by x1.4, landing on the top edge of a solid landscape card at the bottom of the icon.
- 7.2: A solid ink card with five paper-colored dots along a gentle rising curve on its face, the last dot in the accent color.

### R2-8. E. One card, one settled dot (from 4.2 / 4.5)
- 8.1: A solid landscape card with one dot resting on its top edge at the center, half overlapping it; the dot about 30% of the card height.
- 8.2: A solid landscape card tilted 6 degrees with one dot perfectly level above its center, implying it is about to land.


## Round 3 concepts

### R3-1. Graph in a card (from R2-2.3)
- 1.1: Centre: a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card, about 62% of the icon wide. On it, exactly 5 nodes: 4 at the corners of an inner rectangle and 1 in the centre, joined by the inner rectangle's 4 edges plus one spoke from the centre to one corner. Nodes equal size; edges 40% of the node diameter, round caps.
- 1.2: a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card, shifted slightly down-right, holding a small graph of 5 equal nodes and 4 edges (rectangle path plus one spoke). 3 loose dots of the same size outside the card on a 45-degree diagonal toward the top-left, evenly spaced, getting slightly smaller further out.
- 1.3: a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card holding a graph of 4 nodes and 3 edges; one loose dot outside is just touching the card's top-left edge and its edge into the graph is drawn halfway, the settling moment.
- 1.4: a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card, perfectly upright, holding 5 equal nodes joined by 4 edges forming an open zigzag path; 2 loose dots above the card on a gentle arc. One node in the accent color.
- 1.5: a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card holding 5 equal nodes: 3 joined in a horizontal line along the middle, 2 above joined to them by short edges, like a tiny tree. Nothing else.
- 1.6: a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card with 4 nodes at the corners of an inner rectangle joined by edges, and a fifth node in the centre linked to only the top-left one; 2 loose dots outside.
- 1.7: Three loose dots on the left half of the icon; on the right, a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card holding the same three dots now joined by two edges into an ordered row.
- 1.8: a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card whose face holds a 3x2 lattice of equal nodes, with horizontal edges joining each row and one vertical edge in the middle.

### R3-2. Dial ring (user seed R1-8.3)
- 2.1: A ring of 24 evenly spaced small dots (one every 15 degrees) with the bottom dot larger, the settled one. Dots large enough to read at small size.
- 2.2: A ring of 24 dot slots where only the bottom half is visible, dots growing larger toward the bottom centre where one big dot has settled.
- 2.3: A ring of 24 small dots, all the same, plus one larger dot settled inside the ring at its bottom, resting against it.
- 2.4: A ring of 24 small dots around a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card at the centre; the bottom ring dot is larger.
- 2.5: A ring of 12 large dots (one every 30 degrees), with the bottom dot filled solid and the rest as rings (outlines).
- 2.6: A 270-degree arc of dots, one every 15 degrees, growing from tiny to large, ending at the bottom with one big settled dot.

### R3-3. Circle + card overlap (user seed R1-12.1)
- 3.1: A solid circle on the left overlapping a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card on the right; the overlapping region is cut out (negative space, background color). Balanced, centred.
- 3.2: A solid circle overlapping the top-left corner of a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card; the overlap is filled with a third, intermediate tone.
- 3.3: a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card with a circle cut out of its right edge (negative space), the missing circle sitting just beside it as a solid dot, as if it popped out.
- 3.4: A solid circle and a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card of the same height side by side, just overlapping; the overlap cut out as a thin lens of background.
- 3.5: An outlined circle (thick stroke) overlapping a solid a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card; where they overlap the stroke turns to background color.
- 3.6: A solid circle half covered by a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card laid over it from below, like a sun behind a card; only two colors, the card edge cut as a gap.

### R3-4. Dial ring x graph in a card
- 4.1: a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card in the centre holding a small graph of 4 equal nodes and 3 edges; around it, a ring of 24 small dots, one every 15 degrees.
- 4.2: An arc of small dots (lower half of a 24-dot ring) sweeping into a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card, where they become 4 nodes joined by edges.
- 4.3: A ring of 12 equal dots where 4 neighbouring dots at the bottom are joined by thick edges into a short path, the rest loose: structure emerging from the dial.
- 4.4: a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card holding a graph of 5 nodes; the nodes lie on an arc, as if taken from a dial ring, joined by short edges.
- 4.5: A ring of 8 large dots; inside it, two chords join 4 of the dots into a simple graph; the ring is centered in the icon.

### R3-5. Circle + card overlap x graph
- 5.1: A solid circle overlapping a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card; inside the overlap region, 3 nodes joined by 2 edges in the background color.
- 5.2: a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card with a circle cut out of its right edge; the cut-out circle holds one node, and the card face holds 3 nodes joined by edges leading to it.
- 5.3: A circle and a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card side by side, joined by one thick edge between a node at the circle's centre and a node on the card, like two linked ideas.
- 5.4: A solid circle on the left, a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card on the right overlapping it; the card face holds a 4-node graph whose last edge reaches into the circle.
- 5.5: A large circle and a smaller card overlapping; their two centres are nodes joined by an edge, plus one more node on the card; three nodes total, minimal.

### R3-6. Dial ring x circle + card
- 6.1: A ring of 24 small dots overlapping a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card on its right; dots inside the card are cut out in background color.
- 6.2: A solid circle made of a 24-dot ring, overlapping a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card; inside the overlap the dots are solid and larger.
- 6.3: a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card with a quarter of a 24-dot ring wrapping its top-right corner, the ring's last dot settled on the card.

### R3-7. Settling grid / card to dots (critic's B and C)
- 7.1: A 3x3 grid of large equal dots with one slot empty at the top-right; the missing dot sits 1.5 grid steps away on a 45-degree path, with one smaller trailing dot.
- 7.2: Exactly three steps on one 45-degree line: a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card, then a dot 40% of the card's height, then a dot 0.6 times that, gaps following the same 0.6 ratio.
- 7.3: The reverse: two small dots growing into a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card, along one 45-degree diagonal, dots gather into a card.

## Forgetting-curve attempt (user request, drawn in code)

The user asked for the spaced-repetition forgetting curve (retention resets to 100 % at each review, each decay
shallower) simplified into basic shapes and cut like R1-12.1 (circle and card, overlap cut out). Drawn with
`forgetcurve.py`, not image generation: a decay is a rectangle minus an ellipse or circle, combined with a card
(rounded rectangle) and/or a disc by intersection or XOR. SVGs: `forgetcurve/curve-NN-ink.svg` (20 variants;
1-12 first pass, 13-20 after the critic: equal peaks, two decays and a plateau, 12.1 compositions, a card stack).

```bash
uv run docs/design/brand/explorations/ideation-gen/forgetcurve.py <out-dir> [--sheet] [--only 13,16,18] [--mode circle] [--soften 14]
```

Critic verdict: ITERATE, not yet good enough to show next to the dot-card direction. Top 3: 13 (two equal resets
and a plateau, the cleanest build), 18 (one decay cut into the card's top edge, the calmest), 16 (the best 12.1
disc-and-card cut). Main issue: the sawtooth reads as the standard factory icon, and the 12.1 compositions read as
a letter "d" (20 as an "e"). If this direction continues, start from 18 and show the repeated reviews inside the
card rather than as a skyline above it.

### Line versions (user: "not filled at the bottom, an independent line")

Variants 21-38 draw the curve as a single stroke: circle-arc decays and vertical resets, with round caps and
joins. Each one is the line alone, or the line crossing a card or disc with the 12.1 XOR cut. Variants 33-38
follow the critic's notes: two decays at most, a 104 px stroke at 1024, a flat tail, no end dots, and the card's
left edge on the reset. Dark and forest SVGs exist for 34-36. Critic's top 3: 36 (compact card, left edge on the
reset, a clean cut that holds at 29 px; lead with it), 34 (the line alone, but at small sizes it reads as a
lightning bolt or a "4"), and 35 (the tail's end cap nearly touches the card edge). Remaining issue: without a
caption, the stroke doesn't say "forgetting curve". The decay should read as a drop-off, and the reset as a visible
jump of its own.

### Line in a card: rounds 5-7 (user chose this direction)

Variants 39-94 in `forgetcurve.py` (blocks "round 5" to "round 7b"). The decays are true exponentials, steepest
right after each review. Every peak returns to 100 %, and every reset is strictly vertical.
- **Round 5 (39-72):** free lines. Even at 80+ px strokes, the critic read every free-floating line as a bolt, "4"
  or "N", and the lines sat small in the tile.
- **Round 6 (73-84):** the curve knocked out of a 3:2 card, with the card as the chart frame. Three cycles read as
  handwriting ("W") or a heartbeat, and a thin top strip read as a lid.
- **Round 7 (85-94):** one grid, set out in `chart7()`. The card is 696 px wide (0.68 of the tile), corner radius
  0.09 W, stroke s = 72. The start cap sits on the 100 % line, 1 s of card in from the left edge, followed by a
  plateau of 1 s before each decay. There are two cycles (1 : 2) with lows at 40 % and 70 %. The second decay
  leaves through the right edge while still falling (no swoosh), and inner corners are rounded to s / 2.
- **Round 7b (93-94):** 93 adds one margin rule: 1 s of card left, above the 100 % line and below the lowest low.

`design-review.py --mode flat` gates the size: knocked-out lines under about 72 px close at 29 px.

Critic's final ranking: 85, 88, 87. 93 is 85 with the critic's margin fix: it passes 0 of 12 failures and leads
the shortlist. Shortlist order: 93, 85, 87, 88, 81, 75. 93 exists in ink, dark, forest and tinted. 75, 81, 85, 87
and 88 exist in ink, dark and forest.
