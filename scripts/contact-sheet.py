#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = [
#   "pillow==12.0.0",
# ]
# ///
"""One contact sheet per UI-test screenshot run: a row per screen, appearances side by side.

    uv run scripts/contact-sheet.py qa/screenshots/<run> [--out FILE] [--width PX]

Files are `<screen>-light.png` / `<screen>-dark.png`; a `forest` part in the name moves the shot to the
forest columns (`study-revealed-forest-xl-dark` -> screen `study-revealed-xl`, column `forest dark`).
Anything else goes in an "other" section. Columns with no shot at all are dropped. More than ROWS rows
are split into contact-sheet-1.png, -2.png, ... Input PNGs are only read.
"""

import argparse
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

COLUMNS = ["light", "dark", "forest light", "forest dark"]
ROWS = 12  # rows per page
PAD, LABEL = 12, 26  # px around cells; px for a text line
BG, INK, MUTED = (255, 255, 255), (20, 20, 20), (235, 235, 235)


def classify(stem: str) -> tuple[str, str] | None:
    """`deck-forest-dark` -> ("deck", "forest dark"); None when the name has no -light/-dark suffix."""
    base, _, appearance = stem.rpartition("-")
    if not base or appearance not in ("light", "dark"):
        return None
    if "forest" in base.split("-"):
        parts = [p for p in base.split("-") if p != "forest"]
        return "-".join(parts) or "forest", f"forest {appearance}"
    return base, appearance


def group(files: list[Path]) -> tuple[dict[str, dict[str, Path]], list[Path]]:
    screens: dict[str, dict[str, Path]] = {}
    other: list[Path] = []
    for f in files:
        match = classify(f.stem)
        if match is None or match[1] in screens.get(match[0], {}):
            other.append(f)
        else:
            screens.setdefault(match[0], {})[match[1]] = f
    return dict(sorted(screens.items())), other


def thumb(path: Path, width: int) -> Image.Image:
    with Image.open(path) as im:
        im = im.convert("RGB")
        return im.resize((width, round(im.height * width / im.width)), Image.LANCZOS)


def render(rows: list[tuple[str, list[Path | None]]], header: list[str], width: int, height: int) -> Image.Image:
    font, bold = ImageFont.load_default(size=16), ImageFont.load_default(size=20)
    cell_w, row_h = width + PAD, LABEL + height + LABEL + PAD
    sheet = Image.new("RGB", (PAD + cell_w * len(header), LABEL + PAD + row_h * len(rows)), BG)
    draw = ImageDraw.Draw(sheet)
    for c, name in enumerate(header):
        draw.text((PAD + c * cell_w, PAD // 2), name.upper(), fill=INK, font=bold)
    for r, (title, cells) in enumerate(rows):
        y = LABEL + PAD + r * row_h
        draw.text((PAD, y), title, fill=INK, font=bold)
        for c, path in enumerate(cells):
            x = PAD + c * cell_w
            if path is None:
                draw.rectangle((x, y + LABEL, x + width - 1, y + LABEL + height - 1), fill=MUTED)
                continue
            im = thumb(path, width)
            sheet.paste(im.crop((0, 0, width, min(im.height, height))), (x, y + LABEL))
            draw.text((x, y + LABEL + height + 4), path.stem, fill=INK, font=font)
    return sheet


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("run_dir", type=Path)
    ap.add_argument("--out", type=Path, help="output PNG (default <run_dir>/contact-sheet.png)")
    ap.add_argument("--width", type=int, default=240, help="thumbnail width in px (default 240)")
    args = ap.parse_args()

    if not args.run_dir.is_dir():
        sys.exit(f"contact-sheet: no such directory: {args.run_dir}")
    files = sorted(p for p in args.run_dir.glob("*.png") if not p.name.startswith("contact-sheet"))
    if not files:
        sys.exit(f"contact-sheet: no screenshots (*.png) in {args.run_dir}")

    screens, other = group(files)
    header = [c for c in COLUMNS if any(c in cols for cols in screens.values())]
    rows = [(name, [cols.get(c) for c in header]) for name, cols in screens.items()]
    n = len(header) or 3
    rows += [("other", other[i : i + n]) for i in range(0, len(other), n)]
    header = header or [""] * n
    with Image.open(files[0]) as first:
        height = round(first.height * args.width / first.width)

    out = args.out or args.run_dir / "contact-sheet.png"
    pages = [rows[i : i + ROWS] for i in range(0, len(rows), ROWS)]
    for i, page in enumerate(pages, 1):
        path = out if len(pages) == 1 else out.with_stem(f"{out.stem}-{i}")
        render(page, header, args.width, height).save(path, optimize=True)
        print(path)
    print(f"{len(screens)} screens, {len(other)} other, {len(pages)} page(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
