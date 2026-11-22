# /// script
# requires-python = ">=3.12"
# dependencies = ["shapely==2.1.2", "pillow==12.0.0"]
# ///
"""Logo exploration: the spaced-repetition forgetting curve, simplified into basic shapes and cut like R1-12.1
(two flat shapes overlapping, the overlap cut out, even-odd / XOR). Writes flat SVGs (one evenodd path, no
filters) and, with --sheet, review PNGs (numbered sheet, 58/29 px sheet, home-screen preview).

    uv run docs/design/brand/explorations/ideation-gen/forgetcurve.py <out-dir> [--sheet] [--palette ink|dark|forest]

The curve, in basic shapes. Retention starts at 100 % (the peak line), decays, and each review jumps it straight
back up; intervals widen and decays get shallower. One "tooth" (the area under one decay) is

    tooth(x0, w, d) = rectangle [x0, x0 + w] x [peak, base]  minus  ellipse centred (x0 + w, peak), radii (w, d)

so the decay is a quarter ellipse (vertical at the peak, flat at the next review) and the jump is the rectangle's
straight right side. Teeth widths grow and drops shrink (`WIDTHS`, `DROPS`). Every variant is a union, difference
or symmetric difference (XOR, the 12.1 cut) of those teeth with a card (rounded rectangle) and/or a circle, so a
SwiftUI `Shape` can rebuild it from `RoundedRectangle`, `Ellipse` and `Rectangle` paths with `eoFill`.
"""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path

from shapely import affinity
from shapely.geometry import LineString, MultiPolygon, Point, Polygon, box
from shapely.ops import unary_union

S = 1024
PALETTES = {"ink": ("#F4F1EA", "#1C1C1E"), "dark": ("#1C1C1E", "#F2EFE8"), "forest": ("#1F3A2E", "#EFE9DC")}


# ---------------------------------------------------------------- basic shapes

def ellipse(cx: float, cy: float, rx: float, ry: float):
    return affinity.scale(Point(cx, cy).buffer(1, quad_segs=128), rx, ry)


def card(x0: float, y0: float, x1: float, y1: float, r: float):
    return box(x0 + r, y0 + r, x1 - r, y1 - r).buffer(r, quad_segs=64)


MODE = "ellipse"  # "ellipse": quarter ellipse, vertical at the peak; "circle": one circle, finite slope at the peak


def tooth(x0: float, w: float, d: float, peak: float, base: float):
    if MODE == "circle":  # circle through (x0, peak), flat at (x0 + w, peak + d): R = (w^2 + d^2) / 2d
        r = (w * w + d * d) / (2 * d)
        cut = ellipse(x0 + w, peak + d - r, r, r)
    else:
        cut = ellipse(x0 + w, peak, w, d)
    return box(x0, peak, x0 + w, base).difference(cut)


def teeth(x0: float, x1: float, peak: float, base: float, widths, drops, rise: float = 0.0):
    """Union of teeth filling [x0, x1]; widths are relative, drops are px. rise lifts each next peak by px."""
    total = sum(widths)
    parts, x = [], x0
    for i, (w, d) in enumerate(zip(widths, drops)):
        ww = (x1 - x0) * w / total
        parts.append(tooth(x, ww, d, peak - i * rise, base))
        x += ww
    return unary_union(parts)


def curve_line(x0: float, x1: float, peak: float, widths, drops, stroke: float, rise: float = 0.0):
    """The curve itself as a stroke: quarter-ellipse decays joined by vertical review jumps."""
    import math

    total = sum(widths)
    pts, x = [], x0
    for i, (w, d) in enumerate(zip(widths, drops)):
        ww = (x1 - x0) * w / total
        p = peak - i * rise
        for k in range(65):
            if MODE == "circle":
                r = (ww * ww + d * d) / (2 * d)
                xx = x + ww * k / 64
                pts.append((xx, p + d - r + math.sqrt(max(r * r - (x + ww - xx) ** 2, 0))))
            else:
                t = k / 64 * math.pi / 2
                pts.append((x + ww - ww * math.cos(t), p + d * math.sin(t)))
        x += ww
        if i < len(widths) - 1:
            pts.append((x, peak - (i + 1) * rise))
    return LineString(pts).buffer(stroke / 2, cap_style="flat", join_style="round", quad_segs=32)


# ---------------------------------------------------------------- variants (1024 canvas, centred by hand)

W3, D3 = (1.0, 1.55, 2.3), (250, 175, 110)  # three reviews: wider intervals, shallower decays


def v01():  # the bitten card: a landscape card whose top edge is the sawtooth (card minus the forgotten parts)
    c = card(160, 300, 864, 724, 84)
    return c.intersection(teeth(160, 864, 300, 724, W3, D3).buffer(0))


def v02():  # 12.1 logic: disc XOR the three teeth (the curve runs across the disc, the overlap cut out)
    return ellipse(470, 470, 270, 270).symmetric_difference(teeth(220, 860, 470, 790, W3, (210, 150, 95)))


def v03():  # 12.1 logic: card on the right XOR the teeth on the left, overlap cut out
    return card(470, 210, 840, 790, 80).symmetric_difference(teeth(170, 680, 360, 690, W3, (190, 135, 85)))


def v04():  # the curve as a negative line through a portrait card
    c = card(250, 160, 774, 864, 92)
    return c.difference(curve_line(250, 774, 360, W3, (200, 140, 90), 58))


def v05():  # three separate teeth, cards of widening width (gaps = the reviews), rounded feet
    out, x, gap = [], 170, 34
    widths = [w * (684 - 2 * gap) / sum(W3) for w in W3]
    for w, d in zip(widths, (230, 165, 105)):
        t = tooth(x, w, d, 300, 724).intersection(card(x, 160, x + w, 724, 46))
        out.append(t)
        x += w + gap
    return unary_union(out)


def v06():  # two reviews only: bigger, calmer teeth in a card
    c = card(190, 290, 834, 734, 90)
    return c.intersection(teeth(190, 834, 290, 734, (1.0, 1.7), (260, 140)))


def v07():  # four reviews: the full rhythm, in a card
    c = card(150, 310, 874, 714, 76)
    return c.intersection(teeth(150, 874, 310, 714, (1.0, 1.35, 1.8, 2.4), (220, 160, 110, 70)))


def v08():  # rising peaks (each review lands higher), in a card
    c = card(160, 230, 864, 794, 84)
    return c.intersection(teeth(160, 864, 420, 794, W3, (220, 150, 95), rise=95))


def v09():  # the forgotten parts as ink: three circles of growing size XOR the card's top edge (12.1 per review)
    c = card(170, 400, 854, 800, 80)
    total, x, parts = sum(W3), 170, []
    for w in W3:
        ww = 684 * w / total
        r = ww * 0.42
        parts.append(ellipse(x + ww / 2, 400, r, r))
        x += ww
    return c.symmetric_difference(unary_union(parts))


def v10():  # card XOR disc (exact 12.1 composition), the card's top edge carries the sawtooth
    c = card(400, 220, 850, 800, 80).intersection(teeth(400, 850, 220, 800, (1.0, 1.7), (230, 120)))
    return c.symmetric_difference(ellipse(380, 540, 230, 230))


def v11():  # the curve line knocked out of a disc (a dial of memory)
    return ellipse(512, 512, 350, 350).difference(curve_line(162, 862, 380, W3, (230, 160, 100), 56))


def v12():  # the teeth XOR a smaller card resting on them, offset (card held in memory)
    t = teeth(150, 874, 330, 720, W3, (230, 160, 100))
    return t.symmetric_difference(card(560, 200, 790, 560, 56))


# ---- round 2 (after the critic): equal peaks (every review resets to 100 %), the low points rise, fewer teeth,
# 12.1's corner radius (about 0.15 of the card height), mark about 62-68 % of the canvas, seams >= 24 px.

def under_curve(x0: float, peak: float, base: float, segs):
    """Region under the curve. segs = [(width px, retention at the end of the decay 0..1)], all peaks at `peak`.
    A decay is a circle arc (vertical at no point) when it is wider than deep, else a quarter ellipse."""
    parts, x, h = [], x0, base - peak
    for w, keep in segs:
        d = (1 - keep) * h
        if d <= 0:  # no decay: full height (a reset that stays)
            cut = Polygon()
        elif w >= d:
            r = (w * w + d * d) / (2 * d)
            cut = ellipse(x + w, peak + d - r, r, r)
        else:
            cut = ellipse(x + w, peak, w, d)
        parts.append(box(x, peak, x + w, base).difference(cut))
        x += w
    return unary_union(parts).buffer(0.01).buffer(-0.01)


def v13():  # critic's base: one card, two decays and a plateau, equal sharp peaks (low points 40 / 70 / 85 %)
    x0, x1, y0, y1 = 192, 832, 312, 712
    c = card(x0, y0, x1, y1, 60)
    return c.intersection(under_curve(x0, y0, y1, [(200, 0.40), (260, 0.70), (180, 0.85)]))


def v14():  # the same, two decays only, the second one ends the card (no plateau)
    x0, x1, y0, y1 = 192, 832, 312, 712
    c = card(x0, y0, x1, y1, 60)
    return c.intersection(under_curve(x0, y0, y1, [(250, 0.40), (390, 0.75)]))


def v15():  # 12.1 exactly: disc XOR card; the card's top edge is one decay and a reset to full height
    c = card(470, 200, 860, 800, 90)
    c = c.intersection(under_curve(470, 200, 800, [(240, 0.62), (150, 1.0)]).union(box(710, 200, 860, 800)))
    return c.symmetric_difference(ellipse(395, 500, 235, 235))


def v16():  # as 15, the disc lower so the decay sits clear above it (seams stay wide)
    c = card(470, 200, 860, 800, 90)
    c = c.intersection(under_curve(470, 200, 800, [(250, 0.66), (140, 1.0)]).union(box(720, 200, 860, 800)))
    return c.symmetric_difference(ellipse(400, 580, 220, 220))


def v17():  # as 15 with two decays on the card's top edge
    c = card(450, 190, 870, 810, 90)
    c = c.intersection(under_curve(450, 190, 810, [(170, 0.62), (250, 0.85)]))
    return c.symmetric_difference(ellipse(370, 600, 215, 215))  # disc low: clear of the first decay


def v18():  # one card alone, its top edge one decay then a reset (one idea, no disc)
    x0, x1, y0, y1 = 262, 762, 232, 792
    c = card(x0, y0, x1, y1, 84)
    return c.intersection(under_curve(x0, y0, y1, [(300, 0.55), (200, 1.0)]).union(box(x0 + 300, y0, x1, y1)))


def v19():  # two stacked cards, each top edge one decay (back card shallower), overlap cut out
    back = card(380, 190, 840, 700, 76)
    back = back.intersection(under_curve(380, 190, 700, [(460, 0.78)]))
    front = card(184, 330, 644, 840, 76)
    front = front.intersection(under_curve(184, 330, 840, [(460, 0.55)]))
    return back.symmetric_difference(front)


def v20():  # landscape card, two decays, the disc XOR on the left (A10 idea on the critic's base)
    x0, x1, y0, y1 = 360, 870, 300, 724
    c = card(x0, y0, x1, y1, 64).intersection(under_curve(x0, y0, y1, [(200, 0.45), (310, 0.75)]))
    return c.symmetric_difference(ellipse(330, 560, 180, 180))  # disc low: clear of the first decay tip


# ---- round 3 (user: "not filled at the bottom, an independent line"): the curve as one stroke, round caps and
# joins; decays are circle arcs (finite slope at the peak, so no hairpin spike), resets are vertical. Strokes are
# 80-96 px at 1024 (about 2.3-2.7 px at 29 px). Cards and discs meet the stroke with the 12.1 XOR cut.

def curve_pts(x0: float, peak: float, h: float, segs, jump_last: bool = False):
    """Points of the curve: for each (width, retention kept) a decay from `peak`, then a vertical reset to `peak`
    (none after the last decay unless jump_last). A decay is a circle arc when wider than deep, else a quarter ellipse."""
    import math

    pts, x = [(x0, peak)], x0
    for i, (w, keep) in enumerate(segs):
        d = (1 - keep) * h
        for k in range(1, 97):
            t = k / 96
            if w >= d:
                r = (w * w + d * d) / (2 * d)
                xx = x + w * t
                y = peak + d - r + math.sqrt(max(r * r - (x + w - xx) ** 2, 0))
            else:
                a = t * math.pi / 2
                xx, y = x + w - w * math.cos(a), peak + d * math.sin(a)
            pts.append((xx, y))
        x += w
        if i < len(segs) - 1 or jump_last:
            pts.append((x, peak))
    return pts


def stroke(pts, width: float):
    return LineString(pts).buffer(width / 2, cap_style="round", join_style="round", quad_segs=32)


def dot(p, r: float):
    return ellipse(p[0], p[1], r, r)


S3 = [(190, 0.45), (230, 0.68), (260, 0.84)]  # three reviews, widening, shallower; every decay wider than deep


def v21():  # the line alone, three decays
    return stroke(curve_pts(172, 420, 240, S3), 84)


def v22():  # the line alone, two decays and a long flat tail
    return stroke(curve_pts(182, 400, 260, [(250, 0.42), (420, 0.82)]), 92)


def v23():  # the line ending in a dot (the card that stays): dot = 1.9 x the stroke
    pts = curve_pts(150, 420, 240, [(190, 0.45), (220, 0.68), (230, 0.85)])
    return stroke(pts, 80).union(dot(pts[-1], 76))


def v24():  # the line knocked out of a disc, running across it
    pts = curve_pts(150, 430, 230, S3)
    return ellipse(512, 512, 360, 360).difference(stroke(pts, 66))


def v25():  # the line inside a portrait card, knocked out
    c = card(262, 172, 762, 852, 96)
    return c.difference(stroke(curve_pts(322, 400, 200, [(120, 0.45), (140, 0.68), (120, 0.85)]), 60))


def v26():  # the line crossing a card, overlap inverted (12.1 XOR on a stroke)
    c = card(340, 250, 740, 800, 84)
    return c.symmetric_difference(stroke(curve_pts(150, 440, 260, [(230, 0.42), (250, 0.68), (250, 0.86)]), 84))


def v27():  # as 26, two decays, a landscape card below the peaks: the line dips into the card, inverted there
    c = card(170, 470, 854, 820, 80)
    return c.symmetric_difference(stroke(curve_pts(200, 330, 300, [(260, 0.40), (370, 0.80)]), 88))


def v28():  # 12.1 with a disc: the line crossing a disc, overlap inverted, ending in a dot
    pts = curve_pts(140, 420, 240, [(200, 0.45), (250, 0.70), (250, 0.86)])
    return ellipse(500, 560, 250, 250).symmetric_difference(stroke(pts, 76)).union(dot(pts[-1], 72))


def v29():  # four decays, lighter line, in a landscape card, knocked out
    c = card(150, 250, 874, 774, 96)
    segs = [(130, 0.50), (150, 0.66), (170, 0.78), (150, 0.88)]
    return c.difference(stroke(curve_pts(222, 430, 200, segs), 58))


def v30():  # the line rising out of a card: lower half of the line inside the card (inverted), upper half outside
    c = card(190, 520, 834, 860, 80)
    return c.symmetric_difference(stroke(curve_pts(180, 360, 300, S3), 84))


def v31():  # the line runs into a card and ends in a dot inside it (inverted): learning lands on the card
    c = card(560, 250, 860, 780, 72)
    pts = curve_pts(150, 440, 240, [(190, 0.45), (230, 0.68), (180, 0.86)])
    return c.symmetric_difference(stroke(pts, 76).union(dot(pts[-1], 70)))


def v32():  # the line alone, three decays, the start a dot and the end a dot (first sight, kept)
    pts = curve_pts(170, 420, 240, [(190, 0.45), (230, 0.68), (250, 0.86)])
    return stroke(pts, 76).union(dot(pts[0], 66)).union(dot(pts[-1], 66))


# ---- round 4 (critic on round 3): two decays at most, stroke 104 px, decay 1 = 240 wide x 0.55 of the reset,
# decay 2 = 1.5x wider x 0.30, a flat tail, no end dots; the card's left edge sits on the reset (straight meets curve).

def line2(x0: float, peak: float, k: float = 1.0, h: float = 220, tail: float = 120):
    """Two decays and a flat tail, scaled by k."""
    pts = curve_pts(x0, peak, h * k, [(240 * k, 0.45), (360 * k, 0.70)])
    return pts + [(pts[-1][0] + tail * k, pts[-1][1])]


def v33():  # the line alone, full size (mark about 820 px wide)
    return stroke(line2(150, 420), 104)


def v34():  # the line alone at 0.72 scale (mark about 620 px wide, critic's margin)
    return stroke(line2(200, 420, 0.72), 104)


def v35():  # line + card, card's left edge on the reset, the second decay and the tail inside the card
    k, x0, peak = 0.72, 150, 380
    pts = line2(x0, peak, k)
    xr = x0 + 240 * k
    c = card(xr, peak - 150, pts[-1][0] + 60, peak + 330, 64)
    return c.symmetric_difference(stroke(pts, 104))


def v36():  # line + 300 x 400 card (critic's size), the second decay shortened to fit inside it
    x0, peak = 170, 400
    pts = curve_pts(x0, peak, 200, [(230, 0.45), (190, 0.70)])
    pts = pts + [(pts[-1][0] + 30, pts[-1][1])]
    c = card(x0 + 230, peak - 160, x0 + 530, peak + 240, 64)
    return c.symmetric_difference(stroke(pts, 104))


def v37():  # line + card, the card below the peaks: only the decays dip into it, the resets stay outside
    k, x0, peak = 0.72, 190, 360
    pts = line2(x0, peak, k)
    c = card(x0 + 240 * k, peak + 60, pts[-1][0] + 60, peak + 460, 64)
    return c.symmetric_difference(stroke(pts, 104))


def v38():  # line across a disc, overlap inverted, the reset on the disc's vertical diameter
    k, x0, peak = 0.8, 130, 420
    pts = line2(x0, peak, k)
    xr = x0 + 240 * k
    return ellipse(xr + 40, 520, 250, 250).symmetric_difference(stroke(pts, 104))


VARIANTS = [v01, v02, v03, v04, v05, v06, v07, v08, v09, v10, v11, v12, v13, v14, v15, v16, v17, v18, v19, v20, v21, v22, v23, v24, v25, v26, v27, v28, v29, v30, v31, v32, v33, v34, v35, v36, v37, v38]


# ---------------------------------------------------------------- output

def recentre(g):
    """Centre the mark's bounding box on the canvas (optical tweaks stay in the variant)."""
    x0, y0, x1, y1 = g.bounds
    return affinity.translate(g, S / 2 - (x0 + x1) / 2, S / 2 - (y0 + y1) / 2)


def path_d(g) -> str:
    polys = list(g.geoms) if isinstance(g, MultiPolygon) else [g] if isinstance(g, Polygon) else [
        p for p in getattr(g, "geoms", []) if isinstance(p, Polygon)]
    out = []
    for p in polys:
        for ring in [p.exterior, *p.interiors]:
            c = list(ring.coords)
            out.append("M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in c[:-1]) + "Z")
    return " ".join(out)


def svg(g, bg: str, fg: str) -> str:
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">\n'
            f'  <rect width="{S}" height="{S}" fill="{bg}"/>\n'
            f'  <path fill="{fg}" fill-rule="evenodd" d="{path_d(g)}"/>\n</svg>\n')


def png(svg_path: Path, size: int) -> "Image.Image":
    from io import BytesIO

    from PIL import Image

    data = subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), str(svg_path)],
                          check=True, capture_output=True).stdout
    return Image.open(BytesIO(data)).convert("RGB")


def sheets(files: list[Path], out: Path) -> None:
    from PIL import Image, ImageDraw, ImageFont

    font = ImageFont.load_default(size=28)
    cols, cell, pad = 4, 300, 20
    rows = (len(files) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * (cell + pad) + pad, rows * (cell + pad + 36) + pad), "white")
    d = ImageDraw.Draw(sheet)
    for i, f in enumerate(files):
        x, y = pad + (i % cols) * (cell + pad), pad + (i // cols) * (cell + pad + 36)
        sheet.paste(png(f, cell), (x, y + 36))
        d.text((x, y), f.stem.split("-")[1], fill="black", font=font)  # the variant number
    sheet.save(out / "sheet.png")

    # small sizes: each mark at 58 and 29 px, on its tile, in a squircle-ish rounded mask
    small = Image.new("RGB", (len(files) * 110 + 20, 170), "#DADADA")
    d = ImageDraw.Draw(small)
    for i, f in enumerate(files):
        x = 20 + i * 110
        for size, y in ((58, 40), (29, 120)):
            im = png(f, size)
            m = Image.new("L", (size, size), 0)
            ImageDraw.Draw(m).rounded_rectangle((0, 0, size - 1, size - 1), radius=size * 0.225, fill=255)
            small.paste(im, (x, y), m)
        d.text((x, 6), f.stem.split("-")[1], fill="black", font=font)
    small.save(out / "small.png")

    # home-screen preview: 4 x 6 grid on a soft wallpaper; the candidates mixed with plain grey "other apps"
    icon, gap = 64 * 2, 30 * 2
    for start in range(0, len(files), 12):
        chunk = files[start:start + 12]
        home = Image.new("RGB", (4 * icon + 5 * gap, 6 * (icon + gap) + gap), "#8FA3B8")
        for j in range(24):
            x, y = gap + (j % 4) * (icon + gap), gap + (j // 4) * (icon + gap)
            m = Image.new("L", (icon, icon), 0)
            ImageDraw.Draw(m).rounded_rectangle((0, 0, icon - 1, icon - 1), radius=icon * 0.225, fill=255)
            if j % 2 == 0 and j // 2 < len(chunk):
                home.paste(png(chunk[j // 2], icon), (x, y), m)
            else:
                home.paste(Image.new("RGB", (icon, icon), ("#E9E9EE", "#3A6EA5", "#F2B134", "#4CAF7A")[j % 4]),
                           (x, y), m)
        home.save(out / f"home-{start // 12 + 1}.png")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("out", type=Path)
    ap.add_argument("--palette", choices=PALETTES, default="ink")
    ap.add_argument("--only", default="", help="comma list of variant numbers")
    ap.add_argument("--mode", choices=["ellipse", "circle"], default="ellipse", help="decay shape")
    ap.add_argument("--soften", type=float, default=0.0, help="round convex corners (the peaks) by this many px")
    ap.add_argument("--sheet", action="store_true", help="also render sheet.png, small.png, home-N.png")
    a = ap.parse_args()
    global MODE
    MODE = a.mode
    a.out.mkdir(parents=True, exist_ok=True)
    bg, fg = PALETTES[a.palette]
    only = {int(x) for x in a.only.split(",") if x}
    files = []
    for i, fn in enumerate(VARIANTS, 1):
        if only and i not in only:
            continue
        f = a.out / f"curve-{i:02d}-{a.palette}.svg"
        g = fn()
        if a.soften:  # morphological opening: rounds convex corners (peaks), leaves concave ones sharp
            g = g.buffer(-a.soften, quad_segs=32).buffer(a.soften, quad_segs=32)
        f.write_text(svg(recentre(g), bg, fg))
        files.append(f)
    if a.sheet:
        sheets(files, a.out)
    print(a.out)


if __name__ == "__main__":
    main()
