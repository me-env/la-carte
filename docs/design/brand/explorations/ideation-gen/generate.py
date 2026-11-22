# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow>=11"]
# ///
"""Logo ideation with the OpenAI Images API: N directions x M variations, numbered contact sheets.

Usage:
    uv run docs/design/brand/explorations/ideation-gen/generate.py <out-dir> [--round 2] [--only 3,7] [--dry-run]

Round 1 writes into <out-dir>; round N > 1 writes into <out-dir>/round-N/.

The API key is read at runtime from ~/.config/la-carte/openai_api_key (never printed or logged).
Images are written to <out-dir>, which must be outside the repo (the external SSD). Re-running skips
images that already exist, so a failed call can be retried without paying twice.
"""

from __future__ import annotations

import argparse
import base64
import json
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

MODEL = "gpt-image-2.6-flare"  # "fast iteration" model of the 2.6 family
QUALITY = "medium"
SIZE = "1024x1024"
# Standard-tier token prices (USD per 1M tokens) for gpt-image-2.x.
PRICE_TEXT_IN, PRICE_IMAGE_OUT = 5.00, 30.00
BUDGET_USD = 4.50

STYLE = (
    "Flat vector iOS 26 app icon, square 1024x1024 artwork filling the canvas edge to edge "
    "(no rounded-corner mask, no device mockup, no drop shadow around the icon, no text, no letters "
    "unless the concept is a letterform). One simple idea, two or three flat colors, generous margins, "
    "geometric shapes, crisp edges, must read clearly at 29 pixels. Calm, minimal, quiet, premium, "
    "like a first-party Apple utility icon. Original mark: do not imitate any existing brand or app icon."
)

# Palette sentences, rotated across variations so each direction is seen in several themes.
PALETTES = [
    "Warm off-white paper background (#F4F1EA), near-black ink shapes (#1C1C1E).",
    "Near-black background (#121214), warm paper-white shapes (#F2EFE8).",
    "Deep forest green background (#1F3A2E), cream shapes (#EFE9DC).",
    "Soft paper background (#F4F1EA), ink shapes with a single small accent in muted forest green (#2F5D45).",
    "Ink background (#1C1C1E), paper-white shapes with one small warm amber accent dot (#E3A64A).",
]

DIRECTIONS: list[tuple[str, list[str]]] = [
    ("Single card", [
        "A single flashcard: a rounded rectangle in landscape 3:2 proportion, centered, slightly above center, nothing else.",
        "A single index card in landscape proportion with one thin horizontal rule near its top, like a ruled index card.",
        "A single rounded card tilted about 8 degrees, floating, with a very soft flat shadow shape beneath.",
        "A single card in landscape proportion whose lower-right corner is gently folded up, showing the back.",
        "A single card outlined with a thick even stroke (no fill), rounded corners, centered.",
    ]),
    ("Stacked cards", [
        "Three cards stacked with small vertical offset, only their top edges visible behind the front card.",
        "Two cards: a front card and one behind it offset up and to the right, back card a lighter tone.",
        "A neat deck of cards seen slightly from above, the edges forming thin parallel lines along the bottom.",
        "Three cards stacked, each smaller than the one in front, receding upward, like a tidy pile.",
        "Two overlapping cards where the overlap region is a third tone (transparency effect), simple geometry.",
    ]),
    ("Fanned cards", [
        "Three cards fanned from a common bottom pivot, like a hand of playing cards, blank faces.",
        "Two cards fanned at a small angle, the back card peeking out to the left.",
        "Five thin card silhouettes fanned in a quarter circle, evenly spaced, minimal.",
        "Three cards fanned, the middle one solid ink, the outer two outlined only.",
        "A fan of cards forming an arc that reads like a sunrise, blank faces.",
    ]),
    ("Card + dot", [
        "A single landscape card with one solid dot at its center.",
        "A single card with one dot sitting just above its top-right corner, as if about to land.",
        "A card with one dot in the lower-right corner, like a completion mark.",
        "A card outline with a solid dot inside, offset to the left, like a bullet point.",
        "A card and a dot side by side, the dot exactly as tall as a third of the card.",
    ]),
    ("Letterform c / lc", [
        "A lowercase letter 'c' built from a thick rounded stroke, with a small card shape nested in its opening.",
        "The letters 'lc' as a geometric monogram, thick uniform strokes, the l drawn as a tall card edge.",
        "A lowercase 'c' formed by a ring of evenly spaced dots, open on the right.",
        "A lowercase 'c' whose opening is closed by a small rectangle card.",
        "A bold geometric 'c' cut out of a card shape (negative space letter).",
    ]),
    ("Flipping card", [
        "A card mid-flip, shown as a narrowing parallelogram with a curved motion arc beside it.",
        "Two halves of a card: left half one tone (front), right half the other tone (back), split vertically.",
        "A card rotating in 3D, seen edge-on at an angle, with a thin circular arrow arc around it.",
        "A card with its top-right corner peeled over to show a differently colored back.",
        "Two cards in sequence: one flat, one turned showing its back tone, simple flip suggestion.",
    ]),
    ("Card turning into a dot", [
        "A sequence left to right: a card, a smaller rounded square, a circle, a dot - morphing shape, evenly spaced.",
        "A card whose right edge dissolves into a row of shrinking dots.",
        "A rounded card shape with corner radius so large it is nearly a circle, with a small dot beside it.",
        "A card collapsing into a single dot, shown as concentric rounded shapes shrinking toward the center.",
        "Half of the shape is a card corner, the other half rounds into a circle - a card-circle hybrid silhouette.",
    ]),
    ("Dots gathering / settling", [
        "Scattered dots in the upper area gathering and settling into a neat grid that forms a card shape at the bottom.",
        "A card shape made entirely of an even dot grid, a few loose dots above it drifting down.",
        "A ring of 24 small dots like a dial, with one larger dot settled at the bottom.",
        "Dots falling into a card like grains into a tray, the card filling halfway with a dot pattern.",
        "A dotted card outline (dotted border) with a solid dot in the center.",
    ]),
    ("Spacing / memory rhythm", [
        "A row of dots with gaps doubling between them left to right (spaced repetition rhythm), on a single baseline.",
        "Concentric arcs with increasing spacing, like ripples of memory, minimal.",
        "Three card silhouettes spaced farther and farther apart along a horizontal line.",
        "A simple ascending curve made of dots, the dots spacing out as the curve flattens (forgetting curve).",
        "Vertical bars of a card stack with widening gaps, like a calm rhythm.",
    ]),
    ("Bookmark / tab", [
        "A card with a small bookmark ribbon hanging from its top edge.",
        "A single bookmark ribbon shape with a notched bottom, centered, nothing else.",
        "An index card with a small tab sticking up from its top-left, like a file divider.",
        "A card whose top-right has a folded tab marking the place.",
        "A ribbon bookmark tucked into a stack of two cards.",
    ]),
    ("Ink on paper", [
        "A single solid ink dot on a paper card, the dot slightly organic as if pressed from a stamp.",
        "A card with one brush-like ink stroke across it, but kept flat and geometric.",
        "A drop of ink falling onto a card, flat shapes.",
        "A paper card with an ink fill rising from the bottom to two thirds, like a progress level.",
        "A fountain-pen nib shape whose slit forms a card outline, minimal.",
    ]),
    ("Abstract calm mark", [
        "A circle and a rounded rectangle overlapping, the overlap cut out (negative space), balanced.",
        "A horizon line under a card, like a card resting on a calm sea, very minimal.",
        "A rounded square split diagonally into two tones, one corner holding a dot.",
        "A card shape over a large soft circle (like a sun), two tones only.",
        "Two parallel rounded bars of different lengths, like a question line and a shorter answer line, on a card.",
    ]),
]


# Round 2+ prompts: added after the design-critic review of the previous round.
NO_GLOW = (
    " Strictly flat: no glow, no blur, no gradients, no shadows, no 3D, no texture; solid fills only."
)
ROUND_STYLE: dict[int, str] = {2: STYLE + NO_GLOW}

# User-requested priority direction: a knowledge graph inside a card, echoing the app's dots that settle
# into order. Few nodes, thick edges, so it survives 29 px.
GRAPH = ("Knowledge graph in a card", [
    "A single landscape card containing a small graph of 5 solid dots joined by thick straight lines, like a calm constellation.",
    "A card holding 4 dots connected in a simple diamond with one diagonal link; thick edges, large nodes.",
    "Left side: 3 loose scattered dots outside the card; right side: inside the card the dots are connected into an ordered graph.",
    "A card with a 3x2 lattice of dots, some neighbours joined by thick short links, one dot slightly larger as the hub.",
    "A card whose content is a triangle of 3 large dots connected by thick lines, very minimal.",
    "A card containing 6 dots: 3 still loose at the top, 3 settled at the bottom and joined by links.",
    "A card with one central hub dot linked to 4 surrounding dots (star graph), thick lines, generous spacing.",
    "A tilted card on which 5 dots and 5 links form a small constellation, one dot in an accent color.",
    "A card outline whose four corners are nodes, plus one centre node linked to them (the card itself is the graph).",
    "Two stacked cards, the front one holding a tiny graph of 4 connected dots.",
])
# Round 2 refinements from the design-critic's review of round 1 (letters = critic's shortlist).
ROUND2 = [
    GRAPH,  # generated first, before the critic notes; prompts without the trailing flat reminder
    ("Graph in a card, refined (from 1.3 / 1.8)", [
        "Left: three loose dots outside a card. Right: a solid landscape card on which 4 large dots are joined by thick links into a simple graph. Max 7 dots total.",
        "A solid landscape card with a constellation of 5 large dots and 4 thick links forming an open tree; one dot in the accent color.",
        "A solid card whose face shows 4 dots linked as a square with one diagonal; two loose dots drift toward it from above.",
        "A card made of a graph: its 4 corners and 2 mid-edge points are large nodes joined by thick links, the interior empty, landscape 3:2.",
        "Dots settling into order: top half 3 scattered dots, bottom half a card with 3 dots in a row joined by a thick line.",
    ]),
    ("A. Dots settle into a card grid (from 8.1)", [
        "A 4x3 grid of large dots forming a landscape 3:2 card shape (outline implied, no border), with 3 loose dots of the same size above it on a gentle diagonal. Max 16 dots, grid within 60% of canvas width.",
        "A 4x3 grid of large dots forming a landscape card; the top-right grid cell is empty and one dot is falling toward exactly that empty spot.",
        "A 4x3 dot grid card where the dots in the bottom rows are solid and the top row dots are smaller, as if still settling; 2 loose dots above.",
        "A 4x3 grid of large dots forming a card, with 4 loose dots above it, ink on paper, very calm and sparse.",
        "A 4x3 grid of large dots forming a landscape card shape with one dot mid-fall above its missing top-right cell; nothing else.",
    ]),
    ("A x B. Settling dots + dial arc", [
        "A solid landscape card at the bottom center; above it an arc of 8 dots (part of a circle) leading down into the card, dots growing slightly in size toward the card.",
        "A 4x3 dot grid card with a quarter-circle arc of 5 dots sweeping into its top-left corner.",
        "A ring of 12 large dots with a solid landscape card in the center; the bottom dot of the ring is larger and touches the card's bottom edge.",
    ]),
    ("B. Dial ring (from 8.3)", [
        "A ring of 12 large evenly spaced dots with a solid landscape card in the center; the bottom ring dot larger, in the accent color.",
        "An arc of 12 dots spanning about 270 degrees, dots growing larger toward one end, where one big dot has settled; reads as a dial, not a loader.",
        "A ring of 12 large dots around one big solid center dot, very calm.",
    ]),
    ("C. Card becomes a dot (from 7.1)", [
        "Diagonal from top-left to bottom-right: a large landscape card, then a smaller rounded square, then a circle, then a dot, each scaled by x0.62 with equal gaps, filling the square.",
        "A big landscape card with a single dot beside its lower-right corner, the dot diameter equal to the card's corner radius, as if the corner condensed into the dot.",
    ]),
    ("D. Forgetting curve meets a card (from 9.4)", [
        "Five large dots on a rising curve with gaps growing by x1.4, landing on the top edge of a solid landscape card at the bottom of the icon.",
        "A solid ink card with five paper-colored dots along a gentle rising curve on its face, the last dot in the accent color.",
    ]),
    ("E. One card, one settled dot (from 4.2 / 4.5)", [
        "A solid landscape card with one dot resting on its top edge at the center, half overlapping it; the dot about 30% of the card height.",
        "A solid landscape card tilted 6 degrees with one dot perfectly level above its center, implying it is about to land.",
    ]),
]
# Round 3: the user's seeds from round 1 (8.3 dial ring, 12.1 circle/card overlap), the graph-in-a-card
# priority (critic's round-2 construction notes, from R2-2.3), and their combinations. "Landscape" is avoided:
# in round 2 the model drew landscape photos.
CARD = "a horizontal rounded-rectangle card, wider than tall (3:2), blank flat face like an index card"
ROUND3 = [
    ("Graph in a card (from R2-2.3)", [
        f"Centre: {CARD}, about 62% of the icon wide. On it, exactly 5 nodes: 4 at the corners of an inner rectangle and 1 in the centre, joined by the inner rectangle's 4 edges plus one spoke from the centre to one corner. Nodes equal size; edges 40% of the node diameter, round caps.",
        f"{CARD}, shifted slightly down-right, holding a small graph of 5 equal nodes and 4 edges (rectangle path plus one spoke). 3 loose dots of the same size outside the card on a 45-degree diagonal toward the top-left, evenly spaced, getting slightly smaller further out.",
        f"{CARD} holding a graph of 4 nodes and 3 edges; one loose dot outside is just touching the card's top-left edge and its edge into the graph is drawn halfway, the settling moment.",
        f"{CARD}, perfectly upright, holding 5 equal nodes joined by 4 edges forming an open zigzag path; 2 loose dots above the card on a gentle arc. One node in the accent color.",
        f"{CARD} holding 5 equal nodes: 3 joined in a horizontal line along the middle, 2 above joined to them by short edges, like a tiny tree. Nothing else.",
        f"{CARD} with 4 nodes at the corners of an inner rectangle joined by edges, and a fifth node in the centre linked to only the top-left one; 2 loose dots outside.",
        f"Three loose dots on the left half of the icon; on the right, {CARD} holding the same three dots now joined by two edges into an ordered row.",
        f"{CARD} whose face holds a 3x2 lattice of equal nodes, with horizontal edges joining each row and one vertical edge in the middle.",
    ]),
    ("Dial ring (user seed R1-8.3)", [
        "A ring of 24 evenly spaced small dots (one every 15 degrees) with the bottom dot larger, the settled one. Dots large enough to read at small size.",
        "A ring of 24 dot slots where only the bottom half is visible, dots growing larger toward the bottom centre where one big dot has settled.",
        "A ring of 24 small dots, all the same, plus one larger dot settled inside the ring at its bottom, resting against it.",
        f"A ring of 24 small dots around {CARD} at the centre; the bottom ring dot is larger.",
        "A ring of 12 large dots (one every 30 degrees), with the bottom dot filled solid and the rest as rings (outlines).",
        "A 270-degree arc of dots, one every 15 degrees, growing from tiny to large, ending at the bottom with one big settled dot.",
    ]),
    ("Circle + card overlap (user seed R1-12.1)", [
        f"A solid circle on the left overlapping {CARD} on the right; the overlapping region is cut out (negative space, background color). Balanced, centred.",
        f"A solid circle overlapping the top-left corner of {CARD}; the overlap is filled with a third, intermediate tone.",
        f"{CARD} with a circle cut out of its right edge (negative space), the missing circle sitting just beside it as a solid dot, as if it popped out.",
        f"A solid circle and {CARD} of the same height side by side, just overlapping; the overlap cut out as a thin lens of background.",
        f"An outlined circle (thick stroke) overlapping a solid {CARD}; where they overlap the stroke turns to background color.",
        f"A solid circle half covered by {CARD} laid over it from below, like a sun behind a card; only two colors, the card edge cut as a gap.",
    ]),
    ("Dial ring x graph in a card", [
        f"{CARD} in the centre holding a small graph of 4 equal nodes and 3 edges; around it, a ring of 24 small dots, one every 15 degrees.",
        f"An arc of small dots (lower half of a 24-dot ring) sweeping into {CARD}, where they become 4 nodes joined by edges.",
        "A ring of 12 equal dots where 4 neighbouring dots at the bottom are joined by thick edges into a short path, the rest loose: structure emerging from the dial.",
        f"{CARD} holding a graph of 5 nodes; the nodes lie on an arc, as if taken from a dial ring, joined by short edges.",
        "A ring of 8 large dots; inside it, two chords join 4 of the dots into a simple graph; the ring is centered in the icon.",
    ]),
    ("Circle + card overlap x graph", [
        f"A solid circle overlapping {CARD}; inside the overlap region, 3 nodes joined by 2 edges in the background color.",
        f"{CARD} with a circle cut out of its right edge; the cut-out circle holds one node, and the card face holds 3 nodes joined by edges leading to it.",
        f"A circle and {CARD} side by side, joined by one thick edge between a node at the circle's centre and a node on the card, like two linked ideas.",
        f"A solid circle on the left, {CARD} on the right overlapping it; the card face holds a 4-node graph whose last edge reaches into the circle.",
        "A large circle and a smaller card overlapping; their two centres are nodes joined by an edge, plus one more node on the card; three nodes total, minimal.",
    ]),
    ("Dial ring x circle + card", [
        f"A ring of 24 small dots overlapping {CARD} on its right; dots inside the card are cut out in background color.",
        f"A solid circle made of a 24-dot ring, overlapping {CARD}; inside the overlap the dots are solid and larger.",
        f"{CARD} with a quarter of a 24-dot ring wrapping its top-right corner, the ring's last dot settled on the card.",
    ]),
    ("Settling grid / card to dots (critic's B and C)", [
        "A 3x3 grid of large equal dots with one slot empty at the top-right; the missing dot sits 1.5 grid steps away on a 45-degree path, with one smaller trailing dot.",
        f"Exactly three steps on one 45-degree line: {CARD}, then a dot 40% of the card's height, then a dot 0.6 times that, gaps following the same 0.6 ratio.",
        f"The reverse: two small dots growing into {CARD}, along one 45-degree diagonal, dots gather into a card.",
    ]),
]
# Round 3 avoids near-black for dot motifs (too close to Vyst's grain-on-black); one dark palette kept for themes.
ROUND_PALETTES: dict[int, list[str]] = {3: [
    "Warm off-white paper background (#F4F1EA), near-black ink shapes (#1C1C1E).",
    "Deep forest green background (#1F3A2E), cream shapes (#EFE9DC), and deep forest green for marks drawn on cream.",
    "Paper background (#F4F1EA), ink card (#1C1C1E) with paper-colored marks, and one tiny muted amber accent (#E3A64A) at most.",
    "Deep forest green background (#1F3A2E), cream shapes (#EFE9DC), one tiny muted amber accent (#E3A64A) at most.",
    "Near-black background (#121214), warm paper-white shapes (#F2EFE8).",
]}
ROUNDS: dict[int, list[tuple[str, list[str]]]] = {1: DIRECTIONS, 2: ROUND2, 3: ROUND3}
ROUND_STYLE[3] = STYLE + NO_GLOW


def read_key() -> str:
    path = Path.home() / ".config/la-carte/openai_api_key"
    return path.read_text().strip()


def generate(key: str, prompt: str) -> tuple[bytes, dict]:
    body = json.dumps({"model": MODEL, "prompt": prompt, "size": SIZE, "quality": QUALITY, "n": 1}).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/images/generations",
        data=body,
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        data = json.load(resp)
    return base64.b64decode(data["data"][0]["b64_json"]), data.get("usage", {})


def cost(usage: dict) -> float:
    return (usage.get("input_tokens", 0) * PRICE_TEXT_IN + usage.get("output_tokens", 0) * PRICE_IMAGE_OUT) / 1e6


def font(size: int) -> ImageFont.ImageFont:
    for name in ("/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            pass
    return ImageFont.load_default(size)


def sheet(cells: list[tuple[str, Path]], title: str, cols: int, thumb: int, out: Path) -> None:
    pad, label_h, title_h = 24, int(thumb * 0.16) + 8, 90
    rows = (len(cells) + cols - 1) // cols
    w = pad + cols * (thumb + pad)
    h = title_h + rows * (thumb + label_h + pad) + pad
    img = Image.new("RGB", (w, h), "white")
    d = ImageDraw.Draw(img)
    d.text((pad, 24), title, fill="black", font=font(44))
    for i, (label, path) in enumerate(cells):
        x = pad + (i % cols) * (thumb + pad)
        y = title_h + (i // cols) * (thumb + label_h + pad)
        if path.exists():
            img.paste(Image.open(path).convert("RGB").resize((thumb, thumb), Image.LANCZOS), (x, y))
        d.text((x, y + thumb + 4), label, fill="black", font=font(int(thumb * 0.16)))
    img.save(out)


def small_sheet(cells: list[tuple[str, Path]], out: Path) -> None:
    """Each image at 58 px and 29 px (1:1 pixels) on a grey home-screen-like ground, for legibility checks."""
    cols, cell_w, cell_h = 10, 130, 100
    rows = (len(cells) + cols - 1) // cols
    img = Image.new("RGB", (cols * cell_w + 20, rows * cell_h + 20), (128, 128, 132))
    d = ImageDraw.Draw(img)
    for i, (label, path) in enumerate(cells):
        x, y = 10 + (i % cols) * cell_w, 10 + (i // cols) * cell_h
        if path.exists():
            src = Image.open(path).convert("RGB")
            img.paste(src.resize((58, 58), Image.LANCZOS), (x, y))
            img.paste(src.resize((29, 29), Image.LANCZOS), (x + 66, y + 29))
        d.text((x, y + 64), label, fill="white", font=font(20))
    img.save(out)


def shortlist(root: Path, ids: list[str]) -> None:
    """Numbered sheet (1..n, with each image's round id) plus its 58/29 px legibility strip."""
    cells = []
    for n, ident in enumerate(ids, 1):
        rnd, dv = ident.strip().removeprefix("R").split("-")
        d, v = dv.split(".")
        folder = root if rnd == "1" else root / f"round-{rnd}"
        cells.append((f"{n}  ({ident.strip()})", folder / f"{int(d):02d}-{v}.png"))
    sheet(cells, "la-carte logo: critic-approved shortlist (pick a number)", cols=4, thumb=440,
          out=root / "shortlist.png")
    small_sheet(cells, root / "shortlist-small.png")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("out", type=Path)
    ap.add_argument("--round", type=int, default=1)
    ap.add_argument("--only", default="", help="comma-separated direction numbers")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--shortlist", default="", help="ids like R3-1.2,R1-8.3: build shortlist.png, no API calls")
    args = ap.parse_args()
    if args.shortlist:
        return shortlist(args.out, args.shortlist.split(","))
    out: Path = args.out if args.round == 1 else args.out / f"round-{args.round}"
    directions = ROUNDS[args.round]
    style = ROUND_STYLE.get(args.round, STYLE)
    palettes = ROUND_PALETTES.get(args.round, PALETTES)
    out.mkdir(parents=True, exist_ok=True)
    only = {int(x) for x in args.only.split(",") if x}

    jobs = []
    for di, (name, variants) in enumerate(directions, 1):
        if only and di not in only:
            continue
        for vi, concept in enumerate(variants, 1):
            path = out / f"{di:02d}-{vi}.png"
            prompt = f"{style} Concept: {concept} Palette: {palettes[(vi - 1) % len(palettes)]}"
            if args.round > 1:
                prompt += NO_GLOW  # repeated last: the model ignores it mid-prompt on dark palettes
            if not path.exists():
                jobs.append((path, prompt))
    print(f"{len(jobs)} images to generate with {MODEL} ({QUALITY})")
    if args.dry_run:
        return

    key = read_key()
    ledger = out / "cost.json"
    spent = json.loads(ledger.read_text())["usd"] if ledger.exists() else 0.0

    def run(job: tuple[Path, str]) -> float:
        path, prompt = job
        try:
            png, usage = generate(key, prompt)
        except urllib.error.HTTPError as e:
            print(f"FAIL {path.name}: HTTP {e.code} {e.read()[:200]!r}", file=sys.stderr)
            return 0.0
        path.write_bytes(png)
        (path.with_suffix(".txt")).write_text(prompt + "\n")
        c = cost(usage)
        print(f"ok {path.name} ${c:.3f}")
        return c

    # Batches of 8 so the budget check stops the run before it overshoots.
    with ThreadPoolExecutor(8) as pool:
        for i in range(0, len(jobs), 8):
            if spent >= BUDGET_USD:
                print(f"budget reached (${spent:.2f}), stopping")
                break
            spent += sum(pool.map(run, jobs[i : i + 8]))
            ledger.write_text(json.dumps({"usd": round(spent, 4), "model": MODEL, "quality": QUALITY}))
    print(f"total spent so far: ${spent:.2f}")

    overview = []
    for di, (name, variants) in enumerate(directions, 1):
        cells = [(f"{di}.{vi}", out / f"{di:02d}-{vi}.png") for vi in range(1, len(variants) + 1)]
        sheet(cells, f"{di}. {name}", cols=5, thumb=360, out=out / f"sheet-{di:02d}.png")
        overview += cells
        if args.round > 1:  # one row per direction (blank padding) so rows match directions
            overview += [("", Path("/nonexistent"))] * (max(len(v) for _, v in directions) - len(cells))
    small_sheet(overview, out / "overview-small.png")
    cols = 10 if args.round == 1 else max(len(v) for _, v in directions)
    sheet(overview, f"la-carte logo ideation, round {args.round} (direction.variation)", cols=cols, thumb=220,
          out=out / "overview.png")


if __name__ == "__main__":
    main()
