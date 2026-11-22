#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = ["numpy==2.3.4", "pillow==12.0.0", "scipy==1.16.3"]
# ///
"""Round 11: lost data points -> structure, showing time. One light card whose texture is a hex lattice of discrete
dots; on its left it continues as a ribbon of grain that streams in along one smooth curve (from the lower left)
and settles, dot by dot, onto the card's lattice. Dots only: they never touch (gap >= 20% of the summed radii), so
there is no closing, no holes, no seams.

Construction, in a straight parameter space (u along the stream, v across it; px of a 1024 tile):
- Card W x H, corner radius RC, at (XL..XR) x (CY +- H/2). Ribbon for u < XL (TAIL long), half-width hw(s),
  s = XL - u. a, b: the ribbon is the card's full height at the joint (no left corners); c: a full card, the
  ribbon joins the straight part of its left edge.
- Sites: brandkit.hex_lattice (pitch P) inside card U ribbon. Starts: each site pushed by a random offset (disc of
  radius J), relaxed to >= 0.62 P apart, then paired to the sites by optimal transport (brandkit.match). A random
  rank decides which dots exist at low density.
- Three stages along the ramp t (PCHIP coverage through the joints): sparse grain of radius R1 filling up (t < T1);
  the full set settling, w = cubic ease-out 0 -> 1, radius R1 -> R0 (T1..T2); settled dots growing R0 -> RMAX =
  P / 2.7 (gap >= 20% of the summed radii, measured). Dot i sits at lerp(start, site, w).
- Curve: a shear y += DROP * (s / TAIL)^2 (zero slope at the joint; the ribbon keeps its vertical thickness, so
  dots are never squeezed).
Animation (frames/): the same functions of (u - S(t)), S = (1 - g) SPAN, g = smoothstep(t): grain arrives along the
stream and order spreads back from the card's right edge; unsettled dots also drift downstream by
DRIFT (1 - g)(1 - w). In the app, dots appearing fade in (FADE=1 renders that). Reduce Motion: final frame, 0.25 s
fade.
Variants (VAR): a = ribbon narrowing upstream; b = ribbon widening upstream (Vyst's dispersing wisp); c = full
rounded card, a narrower stream entering its left edge.
    VAR=a uv run --script render.py      # -> round11/a/{card-<theme>-<size>.png, frames/, strip.png}
"""
import math, os, sys
from pathlib import Path
sys.path.insert(0, str(next(p for p in Path(__file__).resolve().parents if (p / "scripts/brandkit.py").exists()) / "scripts"))
import brandkit as bk
import numpy as np
from PIL import Image, ImageDraw

VAR = os.environ.get("VAR", "a")
HERE = Path(__file__).resolve().parent
OUT = Path(os.environ.get("OUT", HERE / VAR))
SEED = int(os.environ.get("SEED", {"a": 14, "b": 12, "c": 23}[VAR]))   # seeds that pass design-review (stills + frames)
THEMES = {"light": ("#F9FAF5", "#1C1C1C"), "dark": ("#1A1A1A", "#F2F2F0"), "forest": ("#0E1913", "#EEF2EC")}
ACCENT = {"light": "#B8325A", "dark": "#ED6E8C", "forest": "#ED6E8C"}   # c: one remembered (pink) dot

P = float(os.environ.get("P", "10.5"))                                  # lattice pitch
RMAX = P / float(os.environ.get("RDIV", "2.6" if VAR == "c" else "2.7"))
R0 = 0.6 * P / 2.7                   # final dot radius (gap rule), sparse-dot radius
CELL = math.sqrt(3) / 2 * P * P
CMAX = math.pi * RMAX ** 2 / CELL          # ~0.58
C0 = math.pi * R0 ** 2 / CELL              # coverage of a full set of R0 dots (the largest radius before w = 1)
R1 = float(os.environ.get("R1", "0.7")) * R0  # sparse-grain radius
C1 = math.pi * R1 ** 2 / CELL              # coverage where the set is full
W, H, RC = (460.0, 306.0, 46.0) if VAR == "c" else (360.0, 256.0, 50.0)   # c: 3:2 index card (critic round 1)
CENTRE = {"a": (636, 476), "b": (644, 465), "c": (600, 512)}[VAR]     # optical centring (printed below)
CX, CY = float(os.environ.get("CX", CENTRE[0])), float(os.environ.get("CY", CENTRE[1]))
XL, XR = CX - W / 2, CX + W / 2
TAIL = float(os.environ.get("TAIL", "320" if VAR == "c" else "380"))
U0 = XL - TAIL


def hw(s):
    """Ribbon half-width at distance s upstream of the card's left edge."""
    base = H / 2 if VAR != "c" else H / 2 - RC
    t = np.clip(s / TAIL, 0, 1)
    if VAR == "c":                          # tapers upstream; near the card it flares into the left corners (no neck)
        flare = (H / 2 - base) * 0.75 * (1 - bk.smoothstep(s / (2.2 * RC))) ** 2
        return base * (1 - 0.5 * bk.smoothstep(t)) + flare
    return base * (1 + 0.2 * bk.smoothstep(t)) if VAR == "b" else base * (1 - (float(os.environ.get("NARROW", "0.3")) if VAR == "a" else 0.3) * bk.smoothstep(t))


def in_shape(u, v):
    card = bk.card_sd(u, v, CX, 0.0, W, H, RC) <= 0
    if VAR != "c":                          # a, b: the card's left edge is the stream itself (no left corners)
        card |= (u >= XL) & (u <= CX) & (np.abs(v) <= H / 2)
    s = XL - u
    ribbon = (s >= 0) & (s <= TAIL) & (np.abs(v) <= hw(s))
    return card | ribbon


# Centre line: straight under the card; upstream (s = XL - u > 0) it falls by D(s), with D'(0) = 0 (no kink at
# the joint). A shear, not a bend: the ribbon keeps its vertical thickness, so dots are never squeezed together.
DROP = float(os.environ.get("DROP", "160" if VAR == "c" else "180"))


def warp(u, v):
    t = np.clip((XL - u) / TAIL, 0, 1)
    d = DROP * t * t
    return u, CY + v + d


# Three stages along u (t = 0..1 over the ramp), so dots never come closer than the gap rule and the order is
# measured on a full set: (1) sparse grain, radius R1, density fills up by noise rank (t < T1); (2) the full set
# settles onto the lattice (w: 0 -> 1) while the dots grow R1 -> R0 (T1..T2); (3) the settled dots grow R0 -> RMAX.
# One monotone coverage curve (PCHIP through the stage joints) drives it all.
from scipy.interpolate import PchipInterpolator
UA, UB = U0, XL + float(os.environ.get("GROW", "0.45")) * W
T1, T2 = float(os.environ.get("T1", "0.15")), float(os.environ.get("T2", "0.68"))
H0 = float(os.environ.get("H0", "0.03"))                       # coverage at the far end, / CMAX
_h = PchipInterpolator([0, T1, T2, 1], [H0, C1 / CMAX, C0 / CMAX, 1.0])
def cov(u):
    """Coverage at u; upstream of the ramp start (only reached in animation frames) the grain thins out to nothing."""
    t = (u - UA) / (UB - UA)
    return CMAX * np.where(t >= 0, _h(np.clip(t, 0, 1)), H0 * bk.smoothstep(1 + t / 0.06))
# w: cubic ease-out, so the last 0.2 pitch (where |psi6| actually climbs) is spread over a third of the stage.
order = lambda u: 1 - (1 - np.clip(((u - UA) / (UB - UA) - (T1 - 0.03)) / (T2 - T1 + 0.03), 0, 1)) ** 3

box = (U0 - P, XR + P, -H / 2 - P, H / 2 + P)
lat = bk.hex_lattice(*box, P)
lat = lat[in_shape(lat[:, 0], lat[:, 1])]
if os.environ.get("START") == "match":     # blue noise matched to the sites (rounds 8-10)
    pts = bk.progressive_blue_noise(200000, box, 0.72 * P, SEED)
    keep = np.nonzero(in_shape(pts[:, 0], pts[:, 1]) | (bk.card_sd(pts[:, 0], pts[:, 1], CX, 0, W + 2 * P, H + 2 * P, RC) <= 0))[0]
    start = bk.match(lat, pts[keep])
else:
    # Each site's start = the site pushed by a random offset (uniform in a disc of radius J), then relaxed so no
    # two starts are closer than D_START. lerp(start, site, w) only shrinks every offset, so order (|psi6|,
    # 1 - CV(NN)) rises monotonically with w, with no dip from rearranging an unrelated point set.
    J, D_START = float(os.environ.get("J", "0.9")) * P, 0.62 * P
    _g = bk.rng(SEED)
    _a, _m = _g.uniform(0, 2 * np.pi, len(lat)), J * np.sqrt(_g.uniform(0, 1, len(lat)))
    start = lat + np.column_stack([_m * np.cos(_a), _m * np.sin(_a)])
    from scipy.spatial import cKDTree
    for _ in range(500):
        pr = np.array(sorted(cKDTree(start).query_pairs(D_START - 1e-6)))
        if not len(pr):
            break
        v = start[pr[:, 1]] - start[pr[:, 0]]
        L = np.hypot(*v.T)[:, None]
        push = (D_START - L) / 2 * 1.05 * v / np.maximum(L, 1e-9)
        dp = np.zeros_like(start)
        np.add.at(dp, pr[:, 0], -push); np.add.at(dp, pr[:, 1], push)
        start = start + dp
    else:
        raise ValueError("start relaxation did not converge")
    start = bk.match(lat, start)            # optimal-transport pairing: paths never cross, dots never collide
# Which dots exist at low density: a uniformly random rank (not the progressive order: an evenly spread sparse
# subset is MORE ordered than the full start set, so order would dip as the set fills up). Random subsets of a
# well-spaced set keep its minimum distance, so the gap rule still holds.
if os.environ.get("RANK") == "progressive":
    idx = {tuple(p): i for i, p in zip(keep, pts[keep])}
    rank = np.argsort(np.argsort(np.array([idx[tuple(p)] for p in start], float))) / len(start)
else:
    rank = bk.rng(SEED + 1).permutation(len(start)) / len(start)


PINK_AT = (XR - 0.12 * W, CY - 0.4 * H)        # c: the settled top-right corner dot


def dots(g=1.0, span=W + TAIL + 120, drift=float(os.environ.get("DRIFT", "25"))):
    """Dot centres (x, y) and radii at animation progress g (1 = the still logo)."""
    S = (1 - g) * span
    c, w = cov(lat[:, 0] - S), order(lat[:, 0] - S)
    f = c / C1
    r = np.maximum(R1, np.sqrt(c * CELL / math.pi))
    a = np.clip((f - rank) / (0.15 * np.minimum(f, 1) + 1e-9), 0, 1)   # a dot fades in (opacity), not pops
    pu = start[:, 0] * (1 - w) + lat[:, 0] * w - drift * (1 - g) * (1 - w)
    pv = start[:, 1] * (1 - w) + lat[:, 1] * w
    x, y = warp(pu, pv)
    a = a if os.environ.get("FADE") else np.where(a >= 0.5, 1.0, 0.0)   # PNGs: whole dots (the app may fade them)
    on = a > 0
    return x[on], y[on], r[on], a[on]


def paint(x, y, r, a, bg, fg, ss=4, pink=None):
    im = Image.new("L", (1024 * ss, 1024 * ss), 0)
    d = ImageDraw.Draw(im)
    for px, py, rr, aa in zip(x * ss, y * ss, r * ss, a):
        d.ellipse((px - rr, py - rr, px + rr, py + rr), fill=int(round(255 * aa)))
    cov_ = np.asarray(im.reduce(ss), float)[..., None] / 255
    h = lambda s: np.array([int(s[i:i + 2], 16) for i in (1, 3, 5)], float)
    rgb = h(bg) * (1 - cov_) + h(fg) * cov_
    if pink is not None and VAR == "c":      # recolour the one dot nearest PINK_AT (it stays the same size and place)
        j = int(np.argmin(np.hypot(x - PINK_AT[0], y - PINK_AT[1])))
        yy, xx = np.mgrid[0:1024, 0:1024] + 0.5
        m = (np.hypot(xx - x[j], yy - y[j]) <= r[j] + 1.5)[..., None]
        rgb = np.where(m, h(bg) * (1 - cov_) + h(pink) * cov_, rgb)
    return Image.fromarray(rgb.astype(np.uint8)), cov_[..., 0]


OUT.mkdir(parents=True, exist_ok=True)
x, y, r, a = dots()
for theme, (bg, fg) in THEMES.items():
    img, cv = paint(x, y, r, a, bg, fg, pink=ACCENT[theme])
    img.save(OUT / f"card-{theme}-1024.png")
    for s in (180, 58, 29):
        img.resize((s, s), Image.BOX).save(OUT / f"card-{theme}-{s}.png")
    if theme == "light":
        ink = cv
(OUT / "frames").mkdir(exist_ok=True)
for old in (OUT / "frames").glob("frame-*.png"):
    old.unlink()
strip = Image.new("RGB", (6 * 256, 256))
for i, t in enumerate((0.4, 0.52, 0.64, 0.76, 0.88, 1.0)):
    img, _ = paint(*dots(float(bk.smoothstep(t))), *THEMES["light"])
    img.save(OUT / "frames" / f"frame-{int(t * 100):03d}.png")
    strip.paste(img.resize((256, 256), Image.BOX), (i * 256, 0))
strip.save(OUT / "strip.png")
ys, xs = np.nonzero(ink > 0.02)
opt = (((xs.min() + xs.max()) / 2 + (ink * np.arange(1024)[None]).sum() / ink.sum()) / 2,
       ((ys.min() + ys.max()) / 2 + (ink * np.arange(1024)[:, None]).sum() / ink.sum()) / 2)
print(f"round11 {VAR} seed {SEED}: {len(x)} dots, ink {ink.mean():.1%}, optical centre ({opt[0]:.0f}, {opt[1]:.0f})"
      f" -> CX {CX + 512 - opt[0]:.0f} CY {CY + 512 - opt[1]:.0f}")
