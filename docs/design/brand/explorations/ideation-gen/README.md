# Logo ideation with image generation (2026-11-22)

Fast, wide ideation for the la-carte logo: 12 directions x 5 variations, generated with the OpenAI Images API.
The user picks one; design-lead then redraws it cleanly as SwiftUI `Shape`s and SVG. These images are sketches,
not assets: nothing generated here ships.

- Model: `gpt-image-2.6-flare`, quality `medium`, `1024x1024`, one image per call (about $0.044 each; 60 images = $2.66).
- Key: read at runtime from `~/.config/la-carte/openai_api_key`, never printed or committed.
- Output: `<external SSD>/la-carte/marketing/logo-ideation/2026-11-22/` (images, `.txt` prompt per image, `cost.json`,
  `sheet-NN.png` per direction, `overview.png`). Images never go into the repo.

```bash
uv run docs/design/brand/explorations/ideation-gen/generate.py <out-dir> [--only 3,7] [--dry-run]
```
Existing images are skipped, so re-runs only pay for missing ones. The script stops at a $4.50 budget.

Known artefact: on dark palettes the model often adds a soft glow around shapes; ignore it when judging the idea.

## Prompt

Every prompt is `STYLE + Concept + Palette`.

STYLE: Flat vector iOS 26 app icon, square 1024x1024 artwork filling the canvas edge to edge (no rounded-corner mask, no device mockup, no drop shadow around the icon, no text, no letters unless the concept is a letterform). One simple idea, two or three flat colors, generous margins, geometric shapes, crisp edges, must read clearly at 29 pixels. Calm, minimal, quiet, premium, like a first-party Apple utility icon. Original mark: do not imitate any existing brand or app icon.

Palettes (variation 1-5 uses palette 1-5):
1. Warm off-white paper background (#F4F1EA), near-black ink shapes (#1C1C1E).
2. Near-black background (#121214), warm paper-white shapes (#F2EFE8).
3. Deep forest green background (#1F3A2E), cream shapes (#EFE9DC).
4. Soft paper background (#F4F1EA), ink shapes with a single small accent in muted forest green (#2F5D45).
5. Ink background (#1C1C1E), paper-white shapes with one small warm amber accent dot (#E3A64A).

## Directions and concepts

### 1. Single card
- 1.1: A single flashcard: a rounded rectangle in landscape 3:2 proportion, centered, slightly above center, nothing else.
- 1.2: A single index card in landscape proportion with one thin horizontal rule near its top, like a ruled index card.
- 1.3: A single rounded card tilted about 8 degrees, floating, with a very soft flat shadow shape beneath.
- 1.4: A single card in landscape proportion whose lower-right corner is gently folded up, showing the back.
- 1.5: A single card outlined with a thick even stroke (no fill), rounded corners, centered.

### 2. Stacked cards
- 2.1: Three cards stacked with small vertical offset, only their top edges visible behind the front card.
- 2.2: Two cards: a front card and one behind it offset up and to the right, back card a lighter tone.
- 2.3: A neat deck of cards seen slightly from above, the edges forming thin parallel lines along the bottom.
- 2.4: Three cards stacked, each smaller than the one in front, receding upward, like a tidy pile.
- 2.5: Two overlapping cards where the overlap region is a third tone (transparency effect), simple geometry.

### 3. Fanned cards
- 3.1: Three cards fanned from a common bottom pivot, like a hand of playing cards, blank faces.
- 3.2: Two cards fanned at a small angle, the back card peeking out to the left.
- 3.3: Five thin card silhouettes fanned in a quarter circle, evenly spaced, minimal.
- 3.4: Three cards fanned, the middle one solid ink, the outer two outlined only.
- 3.5: A fan of cards forming an arc that reads like a sunrise, blank faces.

### 4. Card + dot
- 4.1: A single landscape card with one solid dot at its center.
- 4.2: A single card with one dot sitting just above its top-right corner, as if about to land.
- 4.3: A card with one dot in the lower-right corner, like a completion mark.
- 4.4: A card outline with a solid dot inside, offset to the left, like a bullet point.
- 4.5: A card and a dot side by side, the dot exactly as tall as a third of the card.

### 5. Letterform c / lc
- 5.1: A lowercase letter 'c' built from a thick rounded stroke, with a small card shape nested in its opening.
- 5.2: The letters 'lc' as a geometric monogram, thick uniform strokes, the l drawn as a tall card edge.
- 5.3: A lowercase 'c' formed by a ring of evenly spaced dots, open on the right.
- 5.4: A lowercase 'c' whose opening is closed by a small rectangle card.
- 5.5: A bold geometric 'c' cut out of a card shape (negative space letter).

### 6. Flipping card
- 6.1: A card mid-flip, shown as a narrowing parallelogram with a curved motion arc beside it.
- 6.2: Two halves of a card: left half one tone (front), right half the other tone (back), split vertically.
- 6.3: A card rotating in 3D, seen edge-on at an angle, with a thin circular arrow arc around it.
- 6.4: A card with its top-right corner peeled over to show a differently colored back.
- 6.5: Two cards in sequence: one flat, one turned showing its back tone, simple flip suggestion.

### 7. Card turning into a dot
- 7.1: A sequence left to right: a card, a smaller rounded square, a circle, a dot - morphing shape, evenly spaced.
- 7.2: A card whose right edge dissolves into a row of shrinking dots.
- 7.3: A rounded card shape with corner radius so large it is nearly a circle, with a small dot beside it.
- 7.4: A card collapsing into a single dot, shown as concentric rounded shapes shrinking toward the center.
- 7.5: Half of the shape is a card corner, the other half rounds into a circle - a card-circle hybrid silhouette.

### 8. Dots gathering / settling
- 8.1: Scattered dots in the upper area gathering and settling into a neat grid that forms a card shape at the bottom.
- 8.2: A card shape made entirely of an even dot grid, a few loose dots above it drifting down.
- 8.3: A ring of 24 small dots like a dial, with one larger dot settled at the bottom.
- 8.4: Dots falling into a card like grains into a tray, the card filling halfway with a dot pattern.
- 8.5: A dotted card outline (dotted border) with a solid dot in the center.

### 9. Spacing / memory rhythm
- 9.1: A row of dots with gaps doubling between them left to right (spaced repetition rhythm), on a single baseline.
- 9.2: Concentric arcs with increasing spacing, like ripples of memory, minimal.
- 9.3: Three card silhouettes spaced farther and farther apart along a horizontal line.
- 9.4: A simple ascending curve made of dots, the dots spacing out as the curve flattens (forgetting curve).
- 9.5: Vertical bars of a card stack with widening gaps, like a calm rhythm.

### 10. Bookmark / tab
- 10.1: A card with a small bookmark ribbon hanging from its top edge.
- 10.2: A single bookmark ribbon shape with a notched bottom, centered, nothing else.
- 10.3: An index card with a small tab sticking up from its top-left, like a file divider.
- 10.4: A card whose top-right has a folded tab marking the place.
- 10.5: A ribbon bookmark tucked into a stack of two cards.

### 11. Ink on paper
- 11.1: A single solid ink dot on a paper card, the dot slightly organic as if pressed from a stamp.
- 11.2: A card with one brush-like ink stroke across it, but kept flat and geometric.
- 11.3: A drop of ink falling onto a card, flat shapes.
- 11.4: A paper card with an ink fill rising from the bottom to two thirds, like a progress level.
- 11.5: A fountain-pen nib shape whose slit forms a card outline, minimal.

### 12. Abstract calm mark
- 12.1: A circle and a rounded rectangle overlapping, the overlap cut out (negative space), balanced.
- 12.2: A horizon line under a card, like a card resting on a calm sea, very minimal.
- 12.3: A rounded square split diagonally into two tones, one corner holding a dot.
- 12.4: A card shape over a large soft circle (like a sun), two tones only.
- 12.5: Two parallel rounded bars of different lengths, like a question line and a shorter answer line, on a card.
