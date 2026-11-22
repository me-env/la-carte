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
PALETTES = {"ink": ("#F4F1EA", "#1C1C1E"), "dark": ("#1C1C1E", "#F2EFE8"), "forest": ("#1F3A2E", "#EFE9DC"),
            "tinted": ("#000000", "#FFFFFF")}  # tinted: the grayscale source iOS tints


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


WEIGHT = 1.0  # --weight: multiplies every stroke width (to test what holds at 29 px)


def stroke(pts, width: float):
    width *= WEIGHT
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


# ---- round 5 (user chose this direction; critic: the stroke doesn't say "forgetting curve"): decays are true
# exponentials (steep at the top, flattening), every peak back at 100 %, resets strictly vertical, 2-3 cycles with
# visibly longer, shallower decays. Stroke 64-76 px at 1024 (1.8-2.2 px at 29). Line-alone variants try a short
# plateau at 100 % (so the reset and the decay don't fold into a hook) and gaps that isolate the reset.

def decay(x: float, peak: float, w: float, d: float, k: float = 3.0, n: int = 96):
    """Exponential drop from (x, peak) by d over width w: steep start, flat end."""
    import math

    return [(x + w * t, peak + d * (1 - math.exp(-k * t)) / (1 - math.exp(-k))) for t in (i / n for i in range(n + 1))]


def fc_paths(x0: float, peak: float, segs, plateau: float = 0.0, k: float = 3.0, tail: float = 0.0):
    """One polyline: [plateau, decay, vertical reset] per (w, d) seg, no reset after the last; optional flat tail."""
    pts, x = [], x0
    for i, (w, d) in enumerate(segs):
        if plateau:
            pts.append((x, peak))
            x += plateau
        pts += decay(x, peak, w, d, k)
        x += w
        if i < len(segs) - 1:
            pts.append((x, peak))
    if tail:
        pts.append((pts[-1][0] + tail, pts[-1][1]))
    return pts


def fc_split(x0: float, peak: float, segs, gap: float, k: float = 3.0, draw_reset: bool = True):
    """Separate strokes: each decay, and (optionally) each reset as its own vertical with a gap at the low corner."""
    lines, x = [], x0
    for i, (w, d) in enumerate(segs):
        lines.append(decay(x, peak, w, d, k))
        x += w
        if i < len(segs) - 1 and draw_reset:
            lines.append([(x + gap, peak + d - gap * 0.2), (x + gap, peak)])
            x += gap
        elif i < len(segs) - 1:
            x += gap
    return lines


def strokes(lines, width: float, cap: str = "round"):
    width *= WEIGHT
    return unary_union([LineString(p).buffer(width / 2, cap_style=cap, join_style="round", quad_segs=32) for p in lines])


R5_3 = [(170, 250), (250, 170), (330, 100)]  # three cycles: wider, shallower
R5_2 = [(230, 260), (400, 150)]  # two cycles


def v39():  # line alone, three exponential decays, sharp vertical resets
    return stroke(fc_paths(0, 0, R5_3), 68)


def v40():  # as 39 with a short plateau at 100 % before each decay (reset reads as a step, not a hook)
    return stroke(fc_paths(0, 0, R5_3, plateau=60), 68)


def v41():  # two cycles, plateau, flat tail
    return stroke(fc_paths(0, 0, R5_2, plateau=70, tail=60), 76)


def v42():  # decays only, each a separate stroke from the 100 % line: the reset is the gap (implied jump)
    return strokes(fc_split(0, 0, R5_3, gap=70, draw_reset=False), 68)


def v43():  # decays and resets as separate strokes, a gap at each low corner
    return strokes(fc_split(0, 0, R5_3, gap=56), 64)


def v44():  # flat-cap strokes, mitred corners: crisper chart corner at the reset
    pts = fc_paths(0, 0, R5_3, plateau=40)
    return LineString(pts).buffer(34, cap_style="flat", join_style="mitre", mitre_limit=3)


def v45():  # line over a landscape card: decays dip into the card (inverted), resets cross its top edge mid-card
    pts = fc_paths(0, 0, R5_3, plateau=50)
    xs = [p[0] for p in pts]
    c = card(min(xs) - 70, 140, max(xs) + 70, 520, 72)
    return c.symmetric_difference(stroke(pts, 68))


def v46():  # line knocked out of a landscape card, two cycles, the line running edge to edge
    pts = fc_paths(0, 0, R5_2, plateau=60)
    xs = [p[0] for p in pts]
    pts = [(min(xs) - 120, 0)] + pts + [(max(xs) + 120, pts[-1][1])]
    c = card(min(xs) - 60, -200, max(xs) + 60, 420, 80)
    return c.difference(stroke(pts, 64))


def v47():  # from 36: compact card on the right, the second reset INSIDE the card (inverted), not on its edge
    pts = fc_paths(0, 0, R5_2, plateau=50, tail=40)
    xr = 50 + 230  # first reset
    c = card(xr + 90, -150, pts[-1][0] + 60, 380, 64)
    return c.symmetric_difference(stroke(pts, 72))


def v48():  # from 36: card holds the whole second cycle; reset falls in a gap left of the card
    pts = fc_paths(0, 0, R5_2, plateau=50)
    c = card(230 + 50 + 60, -120, pts[-1][0] + 70, 360, 64)
    return c.symmetric_difference(stroke(pts, 72))


def v49():  # card frame as the chart: an outlined card, the curve inside it
    pts = fc_paths(0, 0, R5_3, k=3.2)
    xs = [p[0] for p in pts]
    frame = card(min(xs) - 110, -140, max(xs) + 110, 400, 80)
    return frame.difference(frame.buffer(-52)).union(stroke(pts, 60))


def v50():  # line alone, three cycles, the first starts with the learning rise from the baseline
    pts = [(0, 300)] + fc_paths(0, 0, R5_3, plateau=50)
    return stroke(pts, 68)


R5_FIRST = 39
FIT = 660  # round 5+: the longer side of the mark at 1024 (about 64 %)
VARIANTS += [v39, v40, v41, v42, v43, v44, v45, v46, v47, v48, v49, v50]


# ---- round 5b (own review of 39-50): k = 3 decays are near-vertical at the top and read as a handwritten "w";
# wider, shallower decays (every decay wider than deep), k = 2.2, drawn at final size (about 660 px wide) so the
# stroke is the final stroke; plateaus only after a reset (a plateau at the very start reads as a serif).

def fc2(x0=0.0, peak=0.0, segs=((220, 230), (360, 130)), plateau=0.0, start=0.0, tail=0.0, k=2.2):
    """Like fc_paths, but the plateau follows resets only; `start` is a flat lead-in at 100 %."""
    pts, x = [], x0
    if start:
        pts.append((x, peak))
        x += start
    for i, (w, d) in enumerate(segs):
        if i and plateau:
            pts.append((x, peak))
            x += plateau
        pts += decay(x, peak, w, d, k)
        x += w
        if i < len(segs) - 1:
            pts.append((x, peak))
    if tail:
        pts.append((pts[-1][0] + tail, pts[-1][1]))
    return pts


T2 = ((230, 240), (380, 130))
T3 = ((160, 250), (210, 165), (290, 95))


def v51():  # line alone, two cycles, stroke 76
    return stroke(fc2(segs=T2, tail=40), 76)


def v52():  # two cycles, a short plateau at 100 % after the reset
    return stroke(fc2(segs=((210, 240), (350, 130)), plateau=60, tail=40), 76)


def v53():  # line alone, three cycles, stroke 68
    return stroke(fc2(segs=T3), 68)


def v54():  # three cycles, plateaus after the resets
    return stroke(fc2(segs=((140, 250), (190, 165), (250, 95)), plateau=40), 68)


def v55():  # two cycles, the reset its own stroke with a gap at the low corner
    return strokes(fc_split(0, 0, ((230, 240), (370, 130)), gap=60, k=2.2), 76)


def v56():  # from 36/47: card holds the second cycle, the reset stays outside it with a clear gap
    pts = fc2(segs=((200, 240), (330, 130)), plateau=50, tail=20)
    return card(200 + 50 + 40, -140, pts[-1][0] + 70, 330, 60).symmetric_difference(stroke(pts, 76))


def v57():  # card holds the reset: the jump is inverted inside the card, the first decay enters through its edge
    pts = fc2(segs=((230, 240), (330, 130)), plateau=40, tail=20)
    return card(150, -150, pts[-1][0] + 70, 340, 60).symmetric_difference(stroke(pts, 76))


def v58():  # line knocked out of a 3:2 card, edge to edge, two cycles
    pts = fc2(segs=((200, 230), (330, 125)), plateau=40, start=90, tail=90)
    xs = [p[0] for p in pts]
    c = card(0, -190, xs[-1], -190 + xs[-1] / 1.5, 72)
    return c.difference(stroke(pts, 70))


def v59():  # line over a landscape card: the decays dip into it (inverted), the reset crosses its top edge
    pts = fc2(segs=T2, tail=40)
    return card(-70, 130, pts[-1][0] + 70, 480, 72).symmetric_difference(stroke(pts, 76))


def v60():  # line knocked out of a portrait card, ends inside the card
    pts = fc2(segs=((150, 200), (230, 110)), plateau=30)
    xs = [p[0] for p in pts]
    return card(-80, -200, xs[-1] + 80, 420, 80).difference(stroke(pts, 64))


def v61():  # line alone, a long lead-in at 100 % (known), then two cycles
    return stroke(fc2(segs=((200, 240), (320, 130)), start=110, tail=30), 76)


def v62():  # three cycles over a landscape card (45 at final size)
    pts = fc2(segs=T3)
    return card(-70, 150, pts[-1][0] + 70, 470, 72).symmetric_difference(stroke(pts, 68))


VARIANTS += [v51, v52, v53, v54, v55, v56, v57, v58, v59, v60, v61, v62]


# ---- round 5c (own review of 51-62): drops about as deep as wide still read as a "V"/"N" letter. Here the decay
# flattens out before the next review (k = 3.6, drops wider than deep), so the low corner is a right angle (a step,
# not a V), and a short plateau at 100 % after each reset keeps the peak from folding into a spike. Strokes of
# 80+ px at 1024 (2.3 px at 29): design-review flat fails 72 px diagonals at 29 px as faded.

U2 = ((270, 210), (330, 110))
U3 = ((180, 230), (220, 150), (250, 85))


def u2(plateau=50.0, start=0.0, tail=0.0, segs=U2):
    return fc2(segs=segs, plateau=plateau, start=start, tail=tail, k=3.6)


def v63():  # line alone, two cycles, plateau, stroke 82
    return stroke(u2(), 82)


def v64():  # line alone, three cycles, plateaus, stroke 76
    return stroke(fc2(segs=U3, plateau=36, k=3.6), 92)


def v65():  # as 63, no plateau (spike at the peak)
    return stroke(u2(plateau=0, segs=((290, 210), (360, 110))), 82)


def v66():  # 63 knocked out of a 3:2 card, edge to edge
    pts = u2(start=80, tail=80, segs=((230, 200), (290, 105)))
    xs = [p[0] for p in pts]
    return card(0, -190, xs[-1], -190 + xs[-1] / 1.5, 82).difference(stroke(pts, 80))


def v67():  # 63 with a card holding the second cycle; the reset stays outside with a gap
    pts = u2(segs=((240, 210), (300, 110)))
    return card(240 + 50 + 30, -130, pts[-1][0] + 90, 330, 60).symmetric_difference(stroke(pts, 82))


def v68():  # 63 over a landscape card: the lows dip into the card (inverted), the reset crosses its top edge
    pts = u2(segs=((250, 230), (320, 90)))  # the first low sits wholly inside the card, the second wholly above it
    return card(-110, 165, pts[-1][0] + 110, 500, 72).symmetric_difference(stroke(pts, 82))


def v69():  # 63 with the reset as its own stroke (gap at the low corner)
    lines = fc_split(0, 0, ((270, 210), (330, 110)), gap=60, k=3.6)
    return strokes(lines, 82)


def v70():  # 63 with a lead-in at 100 % (known before the first decay)
    return stroke(u2(start=90, segs=((230, 210), (290, 110))), 82)


def v71():  # three cycles knocked out of a 3:2 card, edge to edge
    pts = [(-70, 0)] + fc2(segs=((170, 220), (210, 145), (240, 85)), plateau=30, k=3.6)
    pts.append((pts[-1][0] + 70, pts[-1][1]))
    return card(-70, -170, pts[-1][0], -170 + (pts[-1][0] + 70) / 1.5, 82).difference(stroke(pts, 74))


def v72():  # 63 with flat caps and mitred corners (a drafted chart line)
    return LineString(u2()).buffer(41, cap_style="flat", join_style="mitre", mitre_limit=4)


VARIANTS += [v63, v64, v65, v66, v67, v68, v69, v70, v71, v72]


# ---- round 6 (critic on round 5: 66 > 70 > 63; every free line reads as a bolt "4"/"N" with no frame of reference):
# the card IS the chart frame. Grid: card 3:2, 696 px wide (0.68 of the tile), corner radius 0.09 x width; the curve
# is a knockout, stroke s = 76 (60 was the critic's number; design-review flat closes knockout lines under
# about 72 px at 29 px); the 100 % line and the lowest possible retention sit 1.5 s inside the top and bottom
# edges (a strip of 1 s); k = 2.4 for three decays (3.6 makes the narrow first decay a vertical "w"); lead-in 0.08 x width; a plateau of 1 s after each reset; decay widths 1 : 1.4 : 2; lows at
# 35 / 55 / 70 % retention; the last decay leaves through the right edge.

def chart(W=696.0, ratio=1.5, s=76.0, ratios=(1, 1.4, 2), lows=(0.35, 0.55, 0.70), lead=0.08, plateau=1.0,
          start_inside=False, k=3.6):
    """(card, centreline points) for a knockout chart card at the origin."""
    H = W / ratio
    top, bot = 1.5 * s, H - 1.5 * s
    x0 = 1.5 * s if start_inside else -s  # inside: a round start cap at the inner corner; else enter through the edge
    lead_px = lead * W
    span = W + s - (x0 + lead_px) - plateau * s * (len(ratios) - 1)  # the last decay runs past the right edge by s
    unit = span / sum(ratios)
    segs = [(r * unit, (1 - low) * (bot - top)) for r, low in zip(ratios, lows)]
    pts = fc2(x0, top, segs, plateau=plateau * s, start=lead_px - x0 if not start_inside else lead_px, k=k)
    return card(0, 0, W, H, 0.09 * W), pts


def v73():  # critic's grid exactly: line enters at the left edge at 100 %, three decays, leaves at the right edge
    c, pts = chart(k=2.4)
    return c.difference(stroke(pts, 76))


def v74():  # as 73, the line starts inside at the top-left inner corner (round cap)
    c, pts = chart(start_inside=True, k=2.4)
    return c.difference(stroke(pts, 76))


def v75():  # two decays (1 : 2), lows 40 / 70 %
    c, pts = chart(ratios=(1, 2), lows=(0.40, 0.70))
    return c.difference(stroke(pts, 78))


def v76():  # as 73, shallower lows (45 / 62 / 76 %): less V, more curve
    c, pts = chart(lows=(0.45, 0.62, 0.76), k=2.4)
    return c.difference(stroke(pts, 76))


def v77():  # no card: an L axis (y axis + baseline, same stroke) and the free curve
    c, pts = chart(start_inside=True)
    W, H = c.bounds[2], c.bounds[3]
    axis = [(0, 0), (0, H), (W, H)]
    pts = [(x + 60, y - 40) for x, y in pts[:-1]] + [(min(pts[-1][0], W) , pts[-1][1] - 40)]
    return stroke(axis, 60).union(stroke(pts, 76))


def v78():  # an outlined card (frame stroke = curve stroke) with the curve inside, touching nothing
    W, H, sw = 696.0, 464.0, 60.0
    frame = card(0, 0, W, H, 0.09 * W)
    frame = frame.difference(frame.buffer(-sw))
    _, pts = chart(W=W - 2 * sw - 60, s=56, start_inside=True)
    pts = [(x + sw + 30, y + sw * 0.6) for x, y in pts]
    pts = [p for p in pts if p[0] <= W - sw - 30 - 28]
    return frame.union(stroke(pts, 56))


def v79():  # as 73, 4:3 card (taller: more presence at 29 px), deeper first low
    c, pts = chart(W=680, ratio=4 / 3, lows=(0.30, 0.55, 0.72), k=2.4)
    return c.difference(stroke(pts, 76))


def v80():  # as 73, stroke 68 and lows 40 / 58 / 72 %: the weight of 66
    c, pts = chart(s=84, lows=(0.40, 0.58, 0.72), k=2.4)
    return c.difference(stroke(pts, 84))


def v81():  # as 74 with two decays: start cap inside, 1 : 2, the long second decay leaving at the right
    c, pts = chart(ratios=(1, 2), lows=(0.38, 0.68), start_inside=True)
    return c.difference(stroke(pts, 78))


def v82():  # 12.1 cut: the line enters from outside the card (lead-in in ink on the paper), inverted inside it
    c, pts = chart(start_inside=True, k=2.4)
    W = c.bounds[2]
    pts = [(-150, pts[0][1])] + [p for p in pts if p[0] <= W - 90]
    return c.symmetric_difference(stroke(pts, 76))


def v83():  # 81 with a softer first decay (k 2.6) and a 1.5 s plateau
    c, pts = chart(ratios=(1, 2), lows=(0.38, 0.68), start_inside=True, plateau=1.5, k=2.6)
    return c.difference(stroke(pts, 78))


def v84():  # 81 on a 4:3 card (taller: more presence at 29 px)
    c, pts = chart(W=680, ratio=4 / 3, ratios=(1, 2), lows=(0.36, 0.66), start_inside=True, plateau=1.5, k=3.0)
    return c.difference(stroke(pts, 78))


VARIANTS += [v73, v74, v75, v76, v77, v78, v79, v80, v81, v82, v83, v84]


# ---- round 7 (critic on round 6: 81 > 75 > 83; three cycles read as "W"/heartbeat, the empty lower card as a
# credit card/TV, a flat exit as a swoosh). Grid, in card units (W = 696 = 0.68 of the tile, H = W / 1.5, radius
# 0.09 W, stroke s = 72): start cap 1.5 s in from the left edge on the 100 % line at 0.28 H; a plateau of 1 s before
# each decay; decay widths 1 : 2 (visible); the first decay falls to 0.80 H (40 % retention on a scale where 0 % is
# 1.147 H), the second heads for 70 % but is cut by the right edge at 70 % of its run, still falling (>= 10 deg);
# resets vertical; every inner corner of the knocked-out line rounded to s / 2 (a closing of the line shape).

def chart7(W=696.0, s=72.0, top=0.28, low=0.80, keep2=0.70, cut=0.70, k1=3.6, k2=3.0, lead=1.0):
    """(card, centreline points, stroke) for the round-7 grid."""
    import math

    H = W / 1.5
    y100 = top * H
    scale = (low - top) * H / 0.60  # px per 100 % retention: the first low is 40 %
    x = 1.5 * s
    pts = [(x, y100)]
    x += lead * s
    unit = (W + s - x - s) / 3  # visible widths 1 : 2, a plateau of s between, the line leaves the card by s
    pts += decay(x, y100, unit, low * H - y100, k1)
    x += unit
    pts += [(x, y100), (x + s, y100)]
    x += s
    w2 = 2 * unit / cut  # the full second decay; only `cut` of it is inside the card
    d2 = (1 - keep2) * scale
    for i in range(1, 97):
        t = cut * i / 96
        pts.append((x + w2 * t, y100 + d2 * (1 - math.exp(-k2 * t)) / (1 - math.exp(-k2))))
    return card(0, 0, W, H, 0.09 * W), pts


def line7(pts, s, round_inner=True):
    g = stroke(pts, s)
    return g.buffer(s / 2, quad_segs=32).buffer(-s / 2, quad_segs=32) if round_inner else g


def v85():  # the critic's grid
    c, pts = chart7()
    return c.difference(line7(pts, 72))


def v86():  # softer exponentials (k 3.0 / 2.4)
    c, pts = chart7(k1=3.0, k2=2.4)
    return c.difference(line7(pts, 72))


def v87():  # the curve a little higher and deeper (100 % at 0.25 H, low at 0.78 H)
    c, pts = chart7(top=0.25, low=0.78)
    return c.difference(line7(pts, 72))


def v88():  # as 85 with sharp inner corners (stroke joins only), for comparison
    c, pts = chart7()
    return c.difference(line7(pts, 72, round_inner=False))


def v89():  # as 85, stroke 78
    c, pts = chart7(s=78)
    return c.difference(line7(pts, 78))


def v90():  # as 85, the exit steeper (second decay cut at 55 % of its run)
    c, pts = chart7(cut=0.55)
    return c.difference(line7(pts, 72))


def v91():  # 12.1 cut: the line runs on past the right edge in ink (card XOR line), round end cap outside
    c, pts = chart7(cut=0.55)
    W = c.bounds[2]
    pts = [p for p in pts if p[0] <= W + 70]
    return c.symmetric_difference(line7(pts, 72))


def v92():  # as 85, the first low shallower (0.74 H) and the second decay deeper (keep 60 %)
    c, pts = chart7(low=0.74, keep2=0.60)
    return c.difference(line7(pts, 72))


for _v in (v85, v86, v87, v88, v89, v90, v92):
    _v.fit = 696  # the card at 0.68 of the tile
v91.fit = 760
VARIANTS += [v85, v86, v87, v88, v89, v90, v91, v92]


# ---- round 7b (critic on round 7: 85 > 88 > 87): one margin rule. The dark card shows the same 1 s of ink left,
# above the 100 % line and below the lowest low: line centres at 1.5 s = 108 px from the card's top and bottom
# (0.233 H / 0.767 H), the start cap's edge 1 s from the left edge.

def v93():  # 85 with equal 1 s margins (the leader)
    c, pts = chart7(top=108 / 464, low=1 - 108 / 464)
    return c.difference(line7(pts, 72))


def v94():  # 93 with lighter inner corners (s / 3)
    c, pts = chart7(top=108 / 464, low=1 - 108 / 464)
    g = stroke(pts, 72).buffer(24, quad_segs=32).buffer(-24, quad_segs=32)
    return c.difference(g)


v93.fit = v94.fit = 696
VARIANTS += [v93, v94]


# ---- round 8 (user on the round-7 shortlist: "I preferred when the card was vertical and the line goes through it,
# with the colour inversion"): back to 35/36, a PORTRAIT card XOR the line (ink on paper, paper inside the card),
# with the round 5-7 lessons. Drawn at final size (no fit): the line about 740 px wide with caps, a start cap and a
# plateau on the 100 % line outside the card, decay 1 (k 3.6), a vertical reset, a plateau of 60, decay 2 (k 3.0,
# flatter and 1.7x longer) leaving with its slope still falling, an end cap outside the card. The reset never sits on
# a card edge (>= 1 stroke clear of it).

def line8(lead=60.0, w1=200.0, d1=230.0, plateau=60.0, w2=340.0, d2=120.0, cut=0.72, k1=3.6, k2=3.0):
    """Centreline from (0, 0); returns (points, x of the reset)."""
    import math

    pts = [(0.0, 0.0)]
    x = lead
    pts += decay(x, 0.0, w1, d1, k1)
    x += w1
    xr = x
    pts += [(x, 0.0), (x + plateau, 0.0)]
    x += plateau
    full = w2 / cut
    dd = d2 / ((1 - math.exp(-k2 * cut)) / (1 - math.exp(-k2)))  # d2 = the drop actually drawn
    for i in range(1, 97):
        t = cut * i / 96
        pts.append((x + full * t, dd * (1 - math.exp(-k2 * t)) / (1 - math.exp(-k2))))
    return pts, xr


def cut8(cx, w, h, pts, sw, cy=None, r=None):
    """Portrait card centred at x = cx (and y = cy, default the middle of the line's height) XOR the line."""
    ys = [p[1] for p in pts]
    cy = (min(ys) + max(ys)) / 2 if cy is None else cy
    c = card(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2, 0.15 * w if r is None else r)
    return c.symmetric_difference(stroke(pts, sw))


def v95():  # card around the reset: left edge crosses decay 1 at about 30 deg, right edge crosses decay 2, 2:3
    pts, xr = line8(w1=240)
    return cut8(xr + 40, 320, 480, pts, 80)


def v96():  # as 95, 5:7 card (330 x 462)
    pts, xr = line8(w1=240)
    return cut8(xr + 45, 330, 462, pts, 80)


def v97():  # card on the start: the line enters on the 100 % plateau (a clean horizontal crossing), decay 1 leaves
    pts, xr = line8(lead=200, w1=240)  # through the bottom, the reset 1.5 s outside on the right
    return cut8(xr - 120 - 150, 300, 450, pts, 80)


def v98():  # card after the reset: a long plateau crosses the left edge (horizontal), the reset 1 s clear of it
    pts, xr = line8(w1=220, plateau=170)
    return cut8(xr + 110 + 150, 300, 450, pts, 80)


def v99():  # card on the tail: decay 2 leaves through the right edge still falling and runs on 1.5 s outside
    pts, xr = line8(w1=220, plateau=170, w2=420)
    return cut8(xr + 110 + 150, 300, 450, pts, 80)


def v100():  # 95 with stroke 72
    pts, xr = line8(w1=240)
    return cut8(xr + 40, 320, 480, pts, 72)


def v101():  # 95 with the 100 % line at the card's upper third (more card below the curve)
    pts, xr = line8(w1=240)
    return cut8(xr + 40, 320, 480, pts, 80, cy=80)


def v102():  # 95 with a longer lead-in outside the card (the line clearly arrives from the left)
    pts, xr = line8(lead=140, w1=220, w2=300)
    return cut8(xr + 40, 300, 450, pts, 80)


def v103():  # 95 with stroke 88
    pts, xr = line8(w1=240)
    return cut8(xr + 40, 320, 480, pts, 88)


def v104():  # 95 with a shallower first drop (d1 190) and the second flatter still (d2 95)
    pts, xr = line8(w1=240, d1=190, d2=95)
    return cut8(xr + 40, 320, 480, pts, 80)


for _v in (v95, v96, v97, v98, v99, v100, v101, v102, v103, v104):
    _v.fit = None  # drawn at final size
VARIANTS += [v95, v96, v97, v98, v99, v100, v101, v102, v103, v104]


# ---- round 9 (critic on round 8: 99 > 98 > 97; a reset inside the card reads as an "S"/"$", so never put one there).
# From 99: the card sits on the plateau after the reset. Grid (s = stroke): the card's left edge 130 px (1.6 s) clear
# of the reset's outer edge; the 100 % plateau enters it flat at 0.30 H and runs 90 px inside before decay 2; decay 2
# (y = A (1 - e^(-x/L)), steepest at its start) leaves the right edge at 0.55-0.65 H and runs >= 220 px outside, its
# total drop smaller than decay 1's (drawn with s = 104, then fit to 800 px: s about 84, gap about 140; 78 faded at 29 px); on the left either no lead-in (a round cap on the peak) or >= 1.5 s of plateau.

def line9(lead=0.0, w1=240.0, d1=300.0, s=104.0, gap=172.0, inside=90.0, cw=300.0, a2=230.0, l2=300.0, out=220.0):
    """(points, card's left x, card's right x)."""
    import math

    pts = [(0.0, 0.0)]
    x = lead
    pts += decay(x, 0.0, w1, d1, 3.6)
    x += w1
    xl = x + s / 2 + gap  # the card's left edge
    pts.append((x, 0.0))
    x0 = xl + inside  # decay 2 starts
    pts.append((x0, 0.0))
    run = (xl + cw - x0) + out
    for i in range(1, 129):
        t = run * i / 128
        pts.append((x0 + t, a2 * (1 - math.exp(-t / l2))))
    return pts, xl, xl + cw


def cut9(pts, xl, xr_, s, ratio=1.5, entry=0.30):
    w = xr_ - xl
    h = w * ratio
    top = -entry * h
    c = card(xl, top, xr_, top + h, 0.15 * w)
    return c.symmetric_difference(stroke(pts, s))


def v105():  # the grid; no lead-in: a round cap on the first peak
    pts, a, b = line9()
    return cut9(pts, a, b, 104)


def v106():  # as 105 with a lead-in plateau of 130 (1.6 s)
    pts, a, b = line9(lead=130, w1=220)
    return cut9(pts, a, b, 104)


def v107():  # as 105, a lighter stroke (98 drawn) and a 1.5 s gap
    pts, a, b = line9(s=98, gap=147)
    return cut9(pts, a, b, 98)


def v108():  # as 105, a 5:7 card
    pts, a, b = line9()
    return cut9(pts, a, b, 104, ratio=1.4)


def v109():  # as 105, the plateau entering at 0.25 H (more card below)
    pts, a, b = line9()
    return cut9(pts, a, b, 104, entry=0.25)


def v110():  # as 105, a steeper decay 2 (exit near 0.62 H) and a deeper decay 1 to stay the larger drop
    pts, a, b = line9(d1=340, a2=260, l2=260)
    return cut9(pts, a, b, 104)


def v111():  # as 105 on a smaller card (280 x 420)
    pts, a, b = line9(cw=280, inside=80)
    return cut9(pts, a, b, 104)


def v112():  # as 105 with a narrower first decay (200) and a longer tail outside (260)
    pts, a, b = line9(w1=200, out=260)
    return cut9(pts, a, b, 104)


for _v in (v105, v106, v107, v108, v109, v110, v111, v112):
    _v.fit = 800  # drawn about 950 wide with s = 104: fit to 0.78 of the tile, s becomes about 84
VARIANTS += [v105, v106, v107, v108, v109, v110, v111, v112]


# ---- round 9b (critic on round 9: 99 > 110 > 105; the card is too small, and decay 1 + the vertical reset read as
# a "√"). Card 2:3 at 0.48 of the tile (327 x 490 drawn), s = 80 drawn (about 75 after fit), the plateau entering the
# card at 0.30 H, decay 2 leaving it at 0.60 H and running about 200 px outside, the mark fit to 880 px. The critic
# asked for a slanted (65-70 deg) rise with a rounded foot; the user's reference has a vertical jump, so both exist.

def line10(s=86.0, w1=170.0, d1=220.0, slant=0.0, start_low=False, gap=1.6, cw=327.0, inside=90.0, out=200.0,
           a2=260.0, l2=300.0, entry=0.30, exit_=0.60, ratio=1.5):
    """(points, card) — decay 2 is fitted so it crosses the card's right edge at exit_ H."""
    import math

    h = cw * ratio
    pts = []
    if start_low:  # no decay 1: the line starts low (forgotten) and rises into the plateau
        pts.append((0.0, d1))
        x = 0.0
    else:
        pts.append((0.0, 0.0))
        pts += decay(0.0, 0.0, w1, d1, 3.6)
        x = w1
    run_up = d1 / math.tan(math.radians(slant)) if slant else 0.0
    if slant:  # a slanted rise with a rounded foot (stroke join) instead of the vertical reset
        pts.append((x + run_up, 0.0))
    else:
        pts.append((x, 0.0))
    xl = x + run_up + s / 2 + gap * s
    x0 = xl + inside
    pts.append((x0, 0.0))
    # decay 2 = a (1 - e^(-t/l)); choose a so it is at (exit_ - entry) h at the card's right edge
    t_edge = xl + cw - x0
    a = (exit_ - entry) * h / (1 - math.exp(-t_edge / l2))
    run = t_edge + out
    for i in range(1, 129):
        t = run * i / 128
        pts.append((x0 + t, a * (1 - math.exp(-t / l2))))
    top = -entry * h
    return pts, card(xl, top, xl + cw, top + h, 0.15 * cw)


def v113():  # 99 rebuilt: compact decay 1 (0.45 H deep), vertical reset, a big 2:3 card
    pts, c = line10()
    return c.symmetric_difference(stroke(pts, 86))


def v114():  # no decay 1: the line starts low and rises vertically into the 100 % plateau (one review, one decay)
    pts, c = line10(start_low=True, d1=200)
    return c.symmetric_difference(stroke(pts, 86))


def v115():  # 113 with the critic's slanted rise (68 deg)
    pts, c = line10(slant=68)
    return c.symmetric_difference(stroke(pts, 86))


def v116():  # 114 with the slanted rise (68 deg)
    pts, c = line10(start_low=True, d1=200, slant=68)
    return c.symmetric_difference(stroke(pts, 86))


for _v in (v113, v114, v115, v116):
    _v.fit = 880
VARIANTS += [v113, v114, v115, v116]


# ---------------------------------------------------------------- output

def recentre(g, optical: bool = False):
    """Centre the mark's bounding box on the canvas. optical: then pull the ink centroid to within 2.5 % of the
    tile centre horizontally (a card on one side weighs that side down)."""
    x0, y0, x1, y1 = g.bounds
    g = affinity.translate(g, S / 2 - (x0 + x1) / 2, S / 2 - (y0 + y1) / 2)
    if optical:
        off = g.centroid.x - S / 2
        lim = 0.025 * S
        if abs(off) > lim:
            g = affinity.translate(g, -(off - lim if off > 0 else off + lim), 0)
    return g


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
    ap.add_argument("--weight", type=float, default=1.0, help="multiply every stroke width")
    ap.add_argument("--sheet", action="store_true", help="also render sheet.png, small.png, home-N.png")
    a = ap.parse_args()
    global MODE, WEIGHT
    MODE, WEIGHT = a.mode, a.weight
    a.out.mkdir(parents=True, exist_ok=True)
    bg, fg = PALETTES[a.palette]
    only = {int(x) for x in a.only.split(",") if x}
    files = []
    for i, fn in enumerate(VARIANTS, 1):
        if only and i not in only:
            continue
        f = a.out / f"curve-{i:02d}-{a.palette}.svg"
        g = fn()
        if i >= R5_FIRST and getattr(fn, "fit", FIT):  # round 5+ is drawn at natural size: fit the mark into FIT px (strokes scale with it)
            x0, y0, x1, y1 = g.bounds
            f_ = getattr(fn, "fit", FIT) / max(x1 - x0, y1 - y0)
            g = affinity.scale(g, f_, f_, origin=(0, 0))
        if a.soften:  # morphological opening: rounds convex corners (peaks), leaves concave ones sharp
            g = g.buffer(-a.soften, quad_segs=32).buffer(a.soften, quad_segs=32)
        f.write_text(svg(recentre(g, optical=i >= R5_FIRST and getattr(fn, "fit", FIT) is not None), bg, fg))
        files.append(f)
    if a.sheet:
        sheets(files, a.out)
    print(a.out)


if __name__ == "__main__":
    main()
