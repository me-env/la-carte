# /// script
# requires-python = ">=3.12"
# dependencies = ["shapely==2.1.2", "pillow==12.0.0"]
# ///
"""Round 11: accent treatments on the user's pick, forgetcurve variant 131 (geometry unchanged).

    uv run docs/design/brand/explorations/ideation-gen/accent131.py <out-dir> [--sheet]

The accent is the app's pink (`Theme.accent` / `Theme.accentOnInk`): #B8325A on light grounds, #ED6E8C on ink
grounds. Forest is only a theme render, never the brand colour. Each treatment is a list of flat layers drawn in
order over the tile, each with a role:
  mark: the ink (light palette) or the light mark (dark palettes)
  acc_bg: pink on the tile ground, acc_mark: pink on the mark colour (the contrasting pair, as in Theme.swift)
Tinted is one colour: both pinks become a mid grey (iOS tints by luminance).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import forgetcurve as fc  # noqa: E402
from shapely import affinity  # noqa: E402
from shapely.geometry import LineString, box  # noqa: E402

S = fc.S
STROKE = 84.0  # at 1024, as 131
FIT = 800.0
PALETTES = {  # bg, mark, acc_bg (pink on the ground), acc_mark (pink on the mark colour)
    "light": ("#F4F1EA", "#1C1C1E", "#B8325A", "#ED6E8C"),
    "dark": ("#1C1C1E", "#F2EFE8", "#ED6E8C", "#B8325A"),
    "forest": ("#1F3A2E", "#EFE9DC", "#ED6E8C", "#B8325A"),  # theme render only
    "tinted": ("#000000", "#FFFFFF", "#8E8E8E", "#8E8E8E"),
}


def parts_131():
    """card, line (stroke + reset bar), centreline points, bar strip: scaled and placed exactly like v131."""
    b = fc.side_split(rw=1.9, bar_r=60, out=-90, exit_=0.54, w1=200, d1=0.40, k1=3.2)
    k = 1.0
    for _ in range(4):
        sw = STROKE / k
        g = b(sw)
        x0, y0, x1, y1 = g.bounds
        k = FIT / max(x1 - x0, y1 - y0)
    p = dict(b.parts)
    p["strip"] = box(-1.9 * sw / 2 - 1, -1e4, 1.9 * sw / 2 + 1, 1e4)  # the reset bar's x range (card edge at 0)
    p["pts"] = LineString(p["pts"])
    g = affinity.scale(g, k, k, origin=(0, 0))
    placed = fc.recentre(g, optical="half")
    dx, dy = placed.bounds[0] - g.bounds[0], placed.bounds[1] - g.bounds[1]

    def tf(x):
        return affinity.translate(affinity.scale(x, k, k, origin=(0, 0)), dx, dy)

    return {n: tf(v) for n, v in p.items()}


def treatments(p):
    C, L, pts = p["card"], p["line"], p["pts"]
    out, inside = L.difference(C), C.intersection(L)
    body = C.difference(L)
    xor = body.union(out)
    bar = L.intersection(p["strip"])
    end = pts.coords[-1]
    tail = fc.ellipse(end[0], end[1], STROKE * 1.6, STROKE * 1.6).intersection(L)  # last ~1.6 strokes of decay 2
    x0, y0, x1, y1 = C.bounds
    r = 0.15 * (x1 - x0)

    def ring(inset, w):
        o = fc.card(x0 + inset, y0 + inset, x1 - inset, y1 - inset, max(r - inset, 8))
        i = fc.card(x0 + inset + w, y0 + inset + w, x1 - inset - w, y1 - inset - w, max(r - inset - w, 4))
        return o.difference(i)

    echo = pts.offset_curve(-STROKE * 1.55)  # parallel to the curve, below it
    echo_line = echo.buffer(13, cap_style="round").intersection(C).difference(L.buffer(STROKE * 0.5))
    return [
        ("base (131, fixed bar foot)", [("mark", xor)], None),
        ("line outside the card in pink", [("mark", body), ("acc_bg", out)], None),
        ("line inside the card in pink (on the ink card)", [("mark", xor), ("acc_mark", inside)], None),
        ("the whole line one pink, over the card", [("mark", body), ("acc_bg", L)], None),
        ("the reset bar pink (both halves)", [("mark", xor.difference(bar)), ("acc_bg", bar.difference(C)),
                                             ("acc_mark", bar.intersection(C))], None),
        ("decay 2's end pink (today's card)", [("mark", xor), ("acc_mark", tail.intersection(C))], None),
        ("pink hairline inside the card (26 px: large sizes only)",
         [("mark", xor.difference(ring(44, 26))), ("acc_mark", ring(44, 26).difference(L))], None),
        ("pink echo line under decay 2 (26 px: large sizes only)", [("mark", xor), ("acc_mark", echo_line)], None),
        ("pink card, ink line", [("acc_bg", body), ("mark", out)], None),
        ("pink tile, light mark", [("mark", xor)], "pink-tile"),
        ("the reset bar one pink (no two-tone seam at the card edge)",
         [("mark", xor.difference(bar)), ("acc_bg", bar)], None),
    ]


def path_d(g) -> str:
    return fc.path_d(g)


def svg(layers, pal: str, tile) -> str:
    bg, mark, acc_bg, acc_mark = PALETTES[pal]
    if tile == "pink-tile" and pal != "tinted":
        bg, mark = (acc_bg if pal == "light" else acc_mark), ("#F4F1EA" if pal == "light" else "#F2EFE8")
    col = {"mark": mark, "acc_bg": acc_bg, "acc_mark": acc_mark}
    body = "".join(f'  <path fill="{col[r]}" fill-rule="evenodd" d="{path_d(g)}"/>\n' for r, g in layers if not g.is_empty)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">\n'
            f'  <rect width="{S}" height="{S}" fill="{bg}"/>\n{body}</svg>\n')


def sheet(out: Path, names, pals) -> None:
    from PIL import Image, ImageDraw, ImageFont

    font = ImageFont.load_default(size=26)
    c, pad, lab = 240, 20, 40
    im = Image.new("RGB", (pad + len(pals) * (c + pad) + 3 * 80, pad + len(names) * (c + pad + lab)), "white")
    d = ImageDraw.Draw(im)
    for r, name in enumerate(names):
        y = pad + r * (c + pad + lab)
        d.text((pad, y), f"{r}  {name}", fill="black", font=font)
        for k, pal in enumerate(pals):
            t = fc.png(out / f"accent-{r}-{pal}.svg", c)
            m = Image.new("L", (c, c), 0)
            ImageDraw.Draw(m).rounded_rectangle((0, 0, c - 1, c - 1), radius=c * 0.225, fill=255)
            im.paste(t, (pad + k * (c + pad), y + lab), m)
        x = pad + len(pals) * (c + pad)
        for size, yy in ((58, 20), (29, 100)):  # light at 58 and 29 px, then dark
            for j, pal in enumerate(("light", "dark")):
                t = fc.png(out / f"accent-{r}-{pal}.svg", size)
                m = Image.new("L", (size, size), 0)
                ImageDraw.Draw(m).rounded_rectangle((0, 0, size - 1, size - 1), radius=size * 0.225, fill=255)
                im.paste(t, (x + j * 80, y + lab + yy), m)
    im.save(out / "sheet.png")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("out", type=Path)
    ap.add_argument("--sheet", action="store_true")
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    ts = treatments(parts_131())
    for i, (_, layers, tile) in enumerate(ts):
        for pal in PALETTES:
            (a.out / f"accent-{i}-{pal}.svg").write_text(svg(layers, pal, tile))
    if a.sheet:
        sheet(a.out, [t[0] for t in ts], list(PALETTES))
    print(a.out)


if __name__ == "__main__":
    main()
