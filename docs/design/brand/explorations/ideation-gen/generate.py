# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow>=11"]
# ///
"""Logo ideation with the OpenAI Images API: N directions x M variations, numbered contact sheets.

Usage:
    uv run docs/design/brand/explorations/ideation-gen/generate.py <out-dir> [--only 3,7] [--dry-run]

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


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("out", type=Path)
    ap.add_argument("--only", default="", help="comma-separated direction numbers")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    out: Path = args.out
    out.mkdir(parents=True, exist_ok=True)
    only = {int(x) for x in args.only.split(",") if x}

    jobs = []
    for di, (name, variants) in enumerate(DIRECTIONS, 1):
        if only and di not in only:
            continue
        for vi, concept in enumerate(variants, 1):
            path = out / f"{di:02d}-{vi}.png"
            prompt = f"{STYLE} Concept: {concept} Palette: {PALETTES[(vi - 1) % len(PALETTES)]}"
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
    for di, (name, variants) in enumerate(DIRECTIONS, 1):
        cells = [(f"{di}.{vi}", out / f"{di:02d}-{vi}.png") for vi in range(1, len(variants) + 1)]
        sheet(cells, f"{di}. {name}", cols=5, thumb=360, out=out / f"sheet-{di:02d}.png")
        overview += cells
    sheet(overview, "la-carte logo ideation: overview (direction.variation)", cols=10, thumb=220,
          out=out / "overview.png")


if __name__ == "__main__":
    main()
