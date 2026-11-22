# /// script
# requires-python = ">=3.12"
# dependencies = ["shapely==2.1.2"]
# ///
"""The la-carte logo and app icon, from the mark the user chose (round 11, forgetcurve 131 + accent 1).

    uv run docs/design/brand/render.py      # needs rsvg-convert (brew install librsvg)

The mark: a portrait card crossed by the forgetting curve as one thick line. Inside the card the line is cut out
(even-odd); outside the card it is pink. The geometry is built once by `explorations/ideation-gen/accent131.py`
(`parts_131`) and frozen here as a card, a simplified centreline, a stroke width and the reset bar (two rounded
rects), in a 100 x 100 box. Everything below is drawn from those numbers, so the SVGs, the PNGs, the app icon and
the SwiftUI view (`LaCarteLogoGeometry.swift`, generated) are the same shape.

Writes, from docs/design/brand/:
  logo-{light,dark,mono,tinted}.svg, png/logo-{light,dark}-{64,256,1024}.png, png/logo-mono-1024.png
  app-icon/app-icon-{light,dark,tinted}.svg + .png (1024) + -58.png + -29.png, copied into AppIcon.appiconset
  ../../../ios/LaCarteKit/Sources/DesignSystem/LaCarteLogoGeometry.swift
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE / "explorations" / "ideation-gen"))
import accent131  # noqa: E402
from shapely import affinity  # noqa: E402
from shapely.geometry import LineString, MultiPolygon, Polygon, box  # noqa: E402

TILE = 1024
STROKE = accent131.STROKE  # 84 px at 1024
# Tokens (Theme.swift): ink and accent per scheme. The pink outside the card is `accent` (#B8325A on light,
# #ED6E8C on dark); the card is `ink`.
LOGO = {"light": ("#1C1C1C", "#B8325A"), "dark": ("#F2F2F0", "#ED6E8C"), "tinted": ("#FFFFFF", "#8E8E8E")}
# The app icon: the paper ground the user approved in round 11, mark colours as above (rounded to the tokens),
# tinted = the grayscale source iOS tints by luminance. The dark variant is the light artwork on purpose: the user
# wants the white-background icon in every appearance (2026-11-22). It is rendered, not omitted, because without a
# dark image iOS 18+ generates its own darkened icon in dark mode.
ICON_LIGHT = ("#F4F1EA", "#1C1C1C", "#B8325A")
ICON = {"light": ICON_LIGHT, "dark": ICON_LIGHT, "tinted": ("#000000", "#FFFFFF", "#8E8E8E")}


def frozen():
    """The chosen mark in tile pixels (as placed on the 1024 icon), rebuilt from simple parts."""
    p = accent131.parts_131()
    card = p["card"]
    x0, y0, x1, y1 = card.bounds
    radius = 0.15 * (x1 - x0)  # forgetcurve.card(…, 0.15 * cw)
    pts = list(p["pts"].coords)
    reset_top = next(i for i, (x, y) in enumerate(pts) if abs(x - x0) < 1e-6)  # the reset ends on the card's edge
    peak, low = pts[reset_top][1], pts[reset_top - 1][1]
    # side_split(rw=1.9, bar_r=60, d1=0.40) at scale k: the bar is 1.9 strokes wide, centred on the card's left edge,
    # from the peak's cap to the low point's cap; its outer foot is decay 1's end cap (radius = half a stroke).
    k = (x1 - x0) / 500.0
    half = 1.9 * STROKE / 2
    top, bottom = peak - STROKE / 2, low + STROKE / 2
    bar = (x0 - half, top, x0 + half, bottom, 60 * k)
    # The foot squares the bar's outer lower corner down to a half-stroke radius; its top is side_split's
    # (bot - sw/2) / 2 measured from the peak line.
    foot = (x0 - half, peak + (bottom - peak - STROKE / 2) / 2, x0 + half - 60 * k, bottom, STROKE / 2)
    # Simplify decay 1 and decay 2 separately so the reset's corners stay exact.
    a = LineString(pts[:reset_top]).simplify(0.2).coords
    b = LineString(pts[reset_top:]).simplify(0.2).coords
    curve = list(a) + list(b)
    return {"card": (x0, y0, x1, y1, radius), "curve": curve, "reset_top": len(a), "bar": bar, "foot": foot,
            "check": (card, p["line"])}


def rounded(x0, y0, x1, y1, r):
    return box(x0 + r, y0 + r, x1 - r, y1 - r).buffer(r, quad_segs=64)


def shapes(f, sw):
    card = rounded(*f["card"])
    line = LineString(f["curve"]).buffer(sw / 2, cap_style="round", join_style="round", quad_segs=32)
    line = line.union(rounded(*f["bar"])).union(rounded(*f["foot"]))
    return card, line


def to_box(f):
    """Tile px → the logo's 100 x 100 box: 100 = 800 px (the mark's height), centred on the mark's bounding box."""
    card, line = shapes(f, STROKE)
    x0, y0, x1, y1 = card.union(line).bounds
    ox, oy, s = (x0 + x1) / 2 - 400, (y0 + y1) / 2 - 400, 100 / 800

    def pt(x, y):
        return ((x - ox) * s, (y - oy) * s)

    def rect(r):
        (a, b), (c, d) = pt(r[0], r[1]), pt(r[2], r[3])
        return (a, b, c, d, r[4] * s)

    return {"card": rect(f["card"]), "curve": [pt(*q) for q in f["curve"]], "reset_top": f["reset_top"],
            "bar": rect(f["bar"]), "foot": rect(f["foot"]), "stroke": STROKE * s, "origin": (ox, oy, s)}


def path_d(g, nd=2) -> str:
    polys = list(g.geoms) if isinstance(g, MultiPolygon) else [g] if isinstance(g, Polygon) else []
    out = []
    for p in polys:
        for ring in [p.exterior, *p.interiors]:
            c = list(ring.coords)[:-1]
            out.append("M" + " L".join(f"{x:.{nd}f},{y:.{nd}f}" for x, y in c) + "Z")
    return " ".join(out)


def mark_paths(L, ink, pink):
    """The card minus the line in `ink`, the line outside the card in `pink` (even-odd, no overlaps)."""
    card, line = shapes(L, L["stroke"])
    body, out = card.difference(line), line.difference(card)
    return (f'  <path fill="{ink}" fill-rule="evenodd" d="{path_d(body)}"/>\n'
            f'  <path fill="{pink}" fill-rule="evenodd" d="{path_d(out)}"/>\n')


def logo_svg(L, ink, pink) -> str:
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">\n'
            f"{mark_paths(L, ink, pink)}</svg>\n")


def mono_svg(L) -> str:
    card, line = shapes(L, L["stroke"])
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">\n'
            f'  <path fill="currentColor" fill-rule="evenodd" d="{path_d(card.symmetric_difference(line))}"/>\n'
            "</svg>\n")


def icon_svg(L, bg, ink, pink) -> str:
    ox, oy, s = L["origin"]  # back to the approved tile placement (round 11)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {TILE} {TILE}" width="{TILE}" height="{TILE}">\n'
            f'  <rect width="{TILE}" height="{TILE}" fill="{bg}"/>\n'
            f'  <g transform="translate({ox:.3f} {oy:.3f}) scale({1 / s:g})">\n'
            f"{mark_paths(L, ink, pink)}  </g>\n</svg>\n")


def swift(L) -> str:
    def r(v):
        return f"CGRect(x: {v[0]:.3f}, y: {v[1]:.3f}, width: {v[2] - v[0]:.3f}, height: {v[3] - v[1]:.3f})"

    pts = ",\n".join(f"    CGPoint(x: {x:.3f}, y: {y:.3f})" for x, y in L["curve"])
    return f"""// Generated by docs/design/brand/render.py from the chosen mark (round 11: forgetcurve 131, accent 1).
// Don't edit: change the script and re-run `uv run docs/design/brand/render.py`.
import CoreGraphics

extension LogoGeometry {{
  /// The portrait card, in the 100 x 100 logo box.
  static let card = {r(L["card"])}
  static let cardRadius: CGFloat = {L["card"][4]:.3f}
  /// The forgetting curve's line width.
  static let strokeWidth: CGFloat = {L["stroke"]:.3f}
  /// The reset, a bar 1.9 strokes wide centred on the card's left edge, and its outer foot (decay 1's end cap).
  static let bar = {r(L["bar"])}
  static let barRadius: CGFloat = {L["bar"][4]:.3f}
  static let barFoot = {r(L["foot"])}
  static let barFootRadius: CGFloat = {L["foot"][4]:.3f}
  /// `curve[resetTop - 1]` → `curve[resetTop]` is the reset (decay 1's low point up to the peak on the card's edge).
  static let resetTop = {L["reset_top"]}
  /// The centreline: decay 1 (outside the card), the reset, a short plateau, decay 2 (inside the card, ending before its right edge).
  static let curve: [CGPoint] = [
{pts},
  ]
}}
"""


def rsvg(src: Path, size: int, dst: Path) -> None:
    subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), str(src), "-o", str(dst)], check=True)


def main() -> None:
    f = frozen()
    card0, line0 = f["check"]
    card1, line1 = shapes(f, STROKE)
    err = card0.symmetric_difference(card1).area + line0.symmetric_difference(line1).area
    assert err < 300, f"frozen geometry drifted from accent131: {err:.0f} px² differ"  # ≈ 0.03 % of the mark
    L = to_box(f)
    # The SwiftUI draw-in leaves out the reset's centreline segment (the bar covers it): check that it does.
    k, sw = L["reset_top"], L["stroke"]

    def stroked(p):
        return LineString(p).buffer(sw / 2, cap_style="round", join_style="round", quad_segs=32)

    without = stroked(L["curve"][:k]).union(stroked(L["curve"][k:])).union(rounded(*L["bar"])).union(rounded(*L["foot"]))
    assert shapes(L, sw)[1].symmetric_difference(without).area < 0.01, "the reset bar no longer covers the reset"

    (HERE / "png").mkdir(exist_ok=True)
    (HERE / "app-icon").mkdir(exist_ok=True)
    for name, (ink, pink) in LOGO.items():
        (HERE / f"logo-{name}.svg").write_text(logo_svg(L, ink, pink))
    (HERE / "logo-mono.svg").write_text(mono_svg(L))
    for name in ("light", "dark"):
        for size in (64, 256, 1024):
            rsvg(HERE / f"logo-{name}.svg", size, HERE / "png" / f"logo-{name}-{size}.png")
    mono_black = HERE / "png" / "_mono.svg"
    mono_black.write_text(mono_svg(L).replace("currentColor", "#000000"))
    rsvg(mono_black, 1024, HERE / "png" / "logo-mono-1024.png")
    mono_black.unlink()

    iconset = ROOT / "ios" / "LaCarte" / "Assets.xcassets" / "AppIcon.appiconset"
    for name, (bg, ink, pink) in ICON.items():
        svg = HERE / "app-icon" / f"app-icon-{name}.svg"
        svg.write_text(icon_svg(L, bg, ink, pink))
        rsvg(svg, 1024, HERE / "app-icon" / f"app-icon-{name}.png")
        for size in (58, 29):
            rsvg(svg, size, HERE / "app-icon" / f"app-icon-{name}-{size}.png")
        (iconset / f"app-icon-{name}.png").write_bytes((HERE / "app-icon" / f"app-icon-{name}.png").read_bytes())

    out = ROOT / "ios" / "LaCarteKit" / "Sources" / "DesignSystem" / "LaCarteLogoGeometry.swift"
    out.write_text(swift(L))
    print(f"brand assets rendered ({len(L['curve'])} curve points, drift {err:.0f} px²)")


if __name__ == "__main__":
    main()
