# /// script
# requires-python = ">=3.12"
# ///
"""Clean vector redraw of the round-4 "dot card" logo: equal dots spaced by arc length along a rounded-rectangle
card outline, one larger "settled" dot. Writes a flat SVG (no filters, no gradients).

    uv run docs/design/brand/explorations/ideation-gen/dotcard.py <out.svg> [--count 20] [--aspect 0.68] ...

`--edges 4,6` is the critic-approved #1 (R4-1.1): 24 dots, 5 top / 7 per side / 5 bottom, corner arcs exactly one
pitch long with no dot on them, so the spacing is perfectly even all round.

Geometry, all derived from the card height H (so a SwiftUI Shape can use the same numbers):
- card: width = aspect * H, corner radius = radius * H; dots sit ON this path.
- count dots, evenly spaced by arc length, the first one at the settled position (so the layout is mirror
  symmetric when the settled dot is the bottom-edge centre).
- dot diameter = dot * pitch (pitch = perimeter / count); settled dot = settled * dot diameter.
- settled: "bottom" (bottom-edge centre, replaces a dot), "corner" (bottom-right corner arc midpoint),
  "inside" (inside the card, centred, resting above the bottom row).
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path


def perimeter_point(w: float, h: float, r: float, s: float) -> tuple[float, float]:
    """Point at arc length s along the rounded rect centred on 0, starting at the bottom-edge centre, clockwise
    in screen coordinates (y down): bottom edge going left, then up the left side, and so on."""
    straight_w, straight_h, arc = w - 2 * r, h - 2 * r, math.pi * r / 2
    # Segments: half bottom (to the left), BL arc, left, TL arc, top, TR arc, right, BR arc, half bottom.
    segs = [
        ("line", (0, h / 2), (-straight_w / 2, h / 2), straight_w / 2),
        ("arc", (-straight_w / 2, straight_h / 2), 90, 180, arc),
        ("line", (-w / 2, straight_h / 2), (-w / 2, -straight_h / 2), straight_h),
        ("arc", (-straight_w / 2, -straight_h / 2), 180, 270, arc),
        ("line", (-straight_w / 2, -h / 2), (straight_w / 2, -h / 2), straight_w),
        ("arc", (straight_w / 2, -straight_h / 2), 270, 360, arc),
        ("line", (w / 2, -straight_h / 2), (w / 2, straight_h / 2), straight_h),
        ("arc", (straight_w / 2, straight_h / 2), 0, 90, arc),
        ("line", (straight_w / 2, h / 2), (0, h / 2), straight_w / 2),
    ]
    total = sum(seg[-1] for seg in segs)
    s %= total
    for seg in segs:
        length = seg[-1]
        if s <= length or seg is segs[-1]:
            t = s / length if length else 0
            if seg[0] == "line":
                (x0, y0), (x1, y1) = seg[1], seg[2]
                return x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
            (cx, cy), a0, a1 = seg[1], seg[2], seg[3]
            a = math.radians(a0 + (a1 - a0) * t)
            return cx + r * math.cos(a), cy + r * math.sin(a)
        s -= length
    raise AssertionError


def perimeter(w: float, h: float, r: float) -> float:
    return 2 * (w - 2 * r) + 2 * (h - 2 * r) + 2 * math.pi * r


def build(a: argparse.Namespace) -> str:
    size = a.size
    h = a.height * size
    if a.edges:  # pitch-exact card: straight edges a and b pitches long, each corner arc exactly 1 pitch
        ea, eb = (int(x) for x in a.edges.split(","))
        a.count = 2 * ea + 2 * eb + 4
        p = h / (eb + 4 / math.pi)
        r = 2 * p / math.pi
        w = ea * p + 2 * r
    else:
        w = a.aspect * h
        r = a.radius * h
    total = perimeter(w, h, r)
    pitch = total / a.count
    d = a.dot * pitch
    big = a.settled * d
    cx, cy = size / 2, size / 2 + a.drop * size
    start = 0.0
    if a.at == "corner":  # bottom-right arc midpoint, measured back from the start (bottom centre, going left)
        start = total - (w - 2 * r) / 2 - math.pi * r / 4
    dots = []
    for i in range(a.count):
        x, y = perimeter_point(w, h, r, start + i * pitch)
        dots.append((cx + x, cy + y, d / 2))
    if a.at in ("bottom", "corner"):
        x, y, _ = dots[0]
        dots[0] = (x, y, big / 2)
    else:  # inside: resting just above the bottom row, one gap clear of it
        dots.append((cx, cy + h / 2 - d / 2 - (pitch - d) - big / 2, big / 2))
    circles = "\n".join(f'  <circle cx="{x:.2f}" cy="{y:.2f}" r="{rr:.2f}"/>' for x, y, rr in dots)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 {size} {size}">\n'
        f'  <rect width="{size}" height="{size}" fill="{a.bg}"/>\n'
        f'  <g fill="{a.fg}">\n{circles}\n  </g>\n</svg>\n'
    )


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("out", type=Path)
    ap.add_argument("--size", type=int, default=1024)
    ap.add_argument("--height", type=float, default=0.62, help="card height as a fraction of the canvas")
    ap.add_argument("--aspect", type=float, default=0.70, help="card width / height (0.7 portrait, 1.5 landscape)")
    ap.add_argument("--radius", type=float, default=0.14, help="corner radius as a fraction of card height")
    ap.add_argument("--count", type=int, default=20)
    ap.add_argument("--edges", default="", help="'4,6': straight top/bottom and side lengths in pitches; corner "
                    "arcs are 1 pitch (r = 2p/pi), count = 2a + 2b + 4; overrides --aspect, --radius, --count")
    ap.add_argument("--dot", type=float, default=0.5, help="dot diameter / pitch")
    ap.add_argument("--settled", type=float, default=1.8, help="settled dot diameter / dot diameter")
    ap.add_argument("--at", choices=["bottom", "corner", "inside"], default="bottom")
    ap.add_argument("--drop", type=float, default=0.0, help="vertical offset of the card centre, fraction of canvas")
    ap.add_argument("--bg", default="#1F3A2E")
    ap.add_argument("--fg", default="#EFE9DC")
    a = ap.parse_args()
    a.out.write_text(build(a))
    print(a.out)


if __name__ == "__main__":
    main()
