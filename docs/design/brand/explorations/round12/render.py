#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = ["numpy==2.3.4", "pillow==12.0.0", "scipy==1.16.3"]
# ///
"""Round 12: lost data points -> structure, showing time. Round 11 c (a 3:2 card fed by one stream of grain from
the lower left), with the critic's fix: the settled card gets a clear silhouette.

Construction, in a straight parameter space (u along the stream, v across it; px of a 1024 tile):
- Card W x H, corner radius RC, centred at (CX, 0). Ribbon for u < XL (TAIL long), half-width hw(s), s = XL - u:
  tapers upstream; FLARE > 0 flares it into the card's left corners (default 0: the card keeps all four corners).
- Curve: a shear y += DROP * (s / TAIL)^2 (zero slope at the joint; the ribbon keeps its thickness).
- Sites: brandkit.hex_lattice (pitch P) inside card U ribbon. Starts: each site pushed by a random offset (disc of
  radius J), relaxed to >= 0.62 P apart, paired to the sites by optimal transport (brandkit.match). A random rank
  decides which dots exist at low density.
- Ramp along u (one PCHIP coverage curve through the stage joints): sparse grain of radius R1 filling up (t < T1);
  the full set settling, w = cubic ease-out 0 -> 1 (T1..T2); then growth.
- Minimum spacing: after every frame's positions are computed, pairs closer than the gap rule (gap >= 20% of the
  summed radii, +4%) are pushed apart (round 11 had two touching dots on some seeds while dots were settling).
Variants (VAR):
- a: pure dots. The ramp ends at the card's left edge, so the whole card is settled at RMAX = P / 2.6, and the
  card's outline rows (left and right lattice columns, top and bottom rows) sit exactly on its rounded rectangle
  inset by RMAX (W and H snap to the lattice), so edges and corners are a continuous line of full-size dots.
- b: the dots converge into solid ink. Past the settled lattice the marks grow into rounded hexagons and close
  into the lattice's own cells (brandkit.mark_shape / raster: walls >= 2.2 px, the paper web retreats into the
  corners), solid from FILL of the card's width; the card edge is the crisp rounded rectangle. Marks below
  coverage CUT stay whole (see inside_at()).
Animation (frames/): the same functions of (u - S(t)), S = (1 - g) SPAN, g = smoothstep(t): grain arrives along the
stream and order spreads back from the card's right edge; unsettled dots drift downstream by DRIFT (1 - g)(1 - w).
Reduce Motion: final frame, 0.25 s fade.
    VAR=a uv run --script render.py      # -> round12/a/{card-<theme>-<size>.png, frames/, strip.png}
"""
import math, os, sys
from pathlib import Path
sys.path.insert(0, str(next(p for p in Path(__file__).resolve().parents if (p / "scripts/brandkit.py").exists()) / "scripts"))
import brandkit as bk
import numpy as np
from PIL import Image, ImageDraw
from scipy.interpolate import PchipInterpolator
from scipy.spatial import cKDTree

VAR = os.environ.get("VAR", "a")
HERE = Path(__file__).resolve().parent
OUT = Path(os.environ.get("OUT", HERE / VAR))
SEED = int(os.environ.get("SEED", {"a": 23, "b": 23}[VAR]))
THEMES = {"light": ("#F9FAF5", "#1C1C1C"), "dark": ("#1A1A1A", "#F2F2F0"), "forest": ("#0E1913", "#EEF2EC")}

P = float(os.environ.get("P", "10.5"))                       # lattice pitch
RMAX = P / float(os.environ.get("RDIV", "2.6"))             # a: settled dot radius (gap = 0.2 P >= 0.2 * 2 RMAX)
R0 = 0.6 * P / 2.7                                           # radius when the set is full and settling
CELL = math.sqrt(3) / 2 * P * P
CMAX = math.pi * RMAX ** 2 / CELL                            # a: settled coverage (~0.63)
C0 = math.pi * R0 ** 2 / CELL
R1 = float(os.environ.get("R1", "0.7")) * R0                 # sparse-grain radius
C1 = math.pi * R1 ** 2 / CELL
W, H, RC = float(os.environ.get("W", "440")), float(os.environ.get("H", "294")), float(os.environ.get("RC", "44"))
E = RMAX if VAR == "a" else P / 2                            # inset of the outline row (a: dots' outer edges on the card)
DX = P * math.sqrt(3) / 2
W = 2 * E + round((W - 2 * E) / DX) * DX                     # snap: left and right edges are lattice columns
H = 2 * E + round((H - 2 * E) / P) * P                       # snap: top and bottom are on the even columns
CENTRE = {"a": (626, 499), "b": (608, 500)}[VAR]                # optical centring (printed below)
CX, CY = float(os.environ.get("CX", CENTRE[0])), float(os.environ.get("CY", CENTRE[1]))
XL, XR = CX - W / 2, CX + W / 2
TAIL = float(os.environ.get("TAIL", "360"))
U0 = XL - TAIL
DROP = float(os.environ.get("DROP", "160"))
S0 = float(os.environ.get("S0", "0"))                        # a straight run before the card (0: none)
FILL = float(os.environ.get("FILL", "0.35"))                  # b: solid from XL + FILL * W
FLARE = float(os.environ.get("FLARE", "0"))                  # 0: the card keeps all four corners
EDGE_ROOM = P / 2 + 0.5                                      # b: see inside_at()
CUT = float(os.environ.get("CUT", "0.9"))                    # b: below this coverage marks stay whole (no clipping)
GAP = 0.2 * 1.10                                             # gap rule with a 4% margin (anti-aliasing)


def hw(s):
    """Ribbon half-width at s upstream of the card's left edge: tapers upstream (FLARE: into the left corners)."""
    base = H / 2 - RC
    t = np.clip(s / TAIL, 0, 1)
    flare = (H / 2 - base) * FLARE * (1 - bk.smoothstep(s / (2.2 * RC))) ** 2
    return base * (1 - 0.5 * bk.smoothstep(t)) + flare


def card(u, v, grow=0.0):
    return bk.card_sd(u, v, CX, 0.0, W, H, RC) <= grow


def ribbon(u, v, grow=0.0):
    s = XL - u
    return (s >= 0) & (s <= TAIL) & (np.abs(v) <= hw(s) + grow)


def drop(u):
    """The stream's fall below the card's centre line; zero (and flat) over the last S0 before the card."""
    return DROP * np.clip((XL - u - S0) / (TAIL - S0), 0, 1) ** 2


# ---------------------------------------------------------------- sites
box = (U0 - P, XR - E, -(H / 2 - E), H / 2 + P)          # a column on the right edge, even columns on top/bottom
lat = bk.hex_lattice(*box, P)
if VAR == "a":
    # The card's outline is a full row of full-size dots: the left and right columns and the top and bottom rows
    # sit exactly on the rounded rectangle inset by E (W, H snapped to the lattice), corners follow its arcs.
    lat = lat[card(lat[:, 0], lat[:, 1], -E + 0.5) | ribbon(lat[:, 0], lat[:, 1])]
else:
    # b: sites whose cell reaches into the card (the solid is the cells clipped to the card) + the ribbon
    lat = lat[card(lat[:, 0], lat[:, 1], 0.6 * P) | ribbon(lat[:, 0], lat[:, 1])]

J, D_START = float(os.environ.get("J", "0.65")) * P, 0.62 * P
_g = bk.rng(SEED)
_a, _m = _g.uniform(0, 2 * np.pi, len(lat)), J * np.sqrt(_g.uniform(0, 1, len(lat)))
start = lat + np.column_stack([_m * np.cos(_a), _m * np.sin(_a)])
for _ in range(500):
    pr = np.array(sorted(cKDTree(start).query_pairs(D_START - 1e-6)))
    if not len(pr):
        break
    vv = start[pr[:, 1]] - start[pr[:, 0]]
    L = np.hypot(*vv.T)[:, None]
    push = (D_START - L) / 2 * 1.05 * vv / np.maximum(L, 1e-9)
    dp = np.zeros_like(start)
    np.add.at(dp, pr[:, 0], -push); np.add.at(dp, pr[:, 1], push)
    start = start + dp
else:
    raise ValueError("start relaxation did not converge")
start = bk.match(lat, start)
rank = bk.rng(SEED + 1).permutation(len(start)) / len(start)

# ---------------------------------------------------------------- ramp
UA = U0
UB = XL + (FILL * W if VAR == "b" else float(os.environ.get("GROW", "0.0")) * W)
T1, T2 = float(os.environ.get("T1", "0.15")), float(os.environ.get("T2", "0.72" if VAR == "a" else "0.45"))
H0 = float(os.environ.get("H0", "0.03"))
CEND = CMAX if VAR == "a" else 1.0
_h = PchipInterpolator([0, T1, T2, 1], [H0 * CEND, C1, C0, CEND])


def cov(u):
    t = (u - UA) / (UB - UA)
    return np.where(t >= 0, _h(np.clip(t, 0, 1)), H0 * CEND * bk.smoothstep(1 + t / 0.06))


POW = float(os.environ.get("POW", "3"))                      # ease-out power of the settling


def order(u):
    return 1 - (1 - np.clip(((u - UA) / (UB - UA) - (T1 - 0.03)) / (T2 - T1 + 0.03), 0, 1)) ** POW


def spread(x, y, r, on):
    """Minimum spacing: push apart any pair of present dots whose gap is under GAP x their summed radii."""
    x, y = x.copy(), y.copy()
    idx = np.nonzero(on)[0]
    for _ in range(1000):
        pts = np.column_stack([x[idx], y[idx]])
        pr = np.array(sorted(cKDTree(pts).query_pairs(2 * (1 + GAP) * r[idx].max() + 0.5)))
        if not len(pr):
            break
        i, j = idx[pr[:, 0]], idx[pr[:, 1]]
        dx, dy = x[j] - x[i], y[j] - y[i]
        d = np.hypot(dx, dy)
        need = (1 + GAP) * (r[i] + r[j]) + 0.5 * (np.maximum(r[i], r[j]) <= R0 + 1e-6)   # tiny dots measure larger
        bad = d < need
        if not bad.any():
            break
        i, j, dx, dy, d, need = i[bad], j[bad], dx[bad], dy[bad], d[bad], need[bad]
        k = (need - d) / 2 / np.maximum(d, 1e-9)
        np.add.at(x, i, -k * dx); np.add.at(y, i, -k * dy)
        np.add.at(x, j, k * dx); np.add.at(y, j, k * dy)
    else:
        print("warning: spacing did not converge (design-review's touching check has the last word)", file=sys.stderr)
    return x, y


def state(g=1.0, span=W + TAIL + 120, drift=float(os.environ.get("DRIFT", "25"))):
    """Per site: pixel position, coverage, radius, present? at animation progress g (1 = the still logo)."""
    S = (1 - g) * span
    c, w = cov(lat[:, 0] - S), order(lat[:, 0] - S)
    f = c / C1
    present = (f - rank) / (0.15 * np.minimum(f, 1) + 1e-9) >= 0.5
    pu = start[:, 0] * (1 - w) + lat[:, 0] * w - drift * (1 - g) * (1 - w)
    pv = start[:, 1] * (1 - w) + lat[:, 1] * w
    x, y = pu, CY + pv + drop(pu)
    r = np.maximum(R1, np.sqrt(np.minimum(c, CMAX) * CELL / math.pi))
    moving = (w < 1) & present                               # settled dots sit on the lattice and already keep the gap
    if moving.any():
        x, y = spread(x, y, r, present)
    return x, y, c, r, present


def paint_dots(x, y, r, bg, fg, ss=4):
    im = Image.new("L", (1024 * ss, 1024 * ss), 0)
    d = ImageDraw.Draw(im)
    for px, py, rr in zip(x * ss, y * ss, r * ss):
        d.ellipse((px - rr, py - rr, px + rr, py + rr), fill=255)
    cv = np.asarray(im.reduce(ss), float)[..., None] / 255
    h = lambda s: np.array([int(s[i:i + 2], 16) for i in (1, 3, 5)], float)
    return Image.fromarray((h(bg) * (1 - cv) + h(fg) * cv).astype(np.uint8))


def inside_at(S):
    """b: the pixel mask ink is limited to at ramp shift S: the card, with a crisp edge where the marks are solid
    (coverage >= CUT) and room for whole edge cells (half a pitch) where they are not, and the sheared ribbon with
    room for loose dots. Without that room the edge cells of the zig-zag lattice rows are cut or dropped, and the
    web cells next to them close up as isolated blobs (touching)."""
    def inside(xs, ys):
        v = ys - CY - drop(xs)
        room = card(xs, ys - CY, EDGE_ROOM) & (cov(xs - S) < CUT)
        return (card(xs, ys - CY) | room | ribbon(xs, v, P + J)
                | ((xs < XL) & (xs >= XL - P - J) & (np.abs(ys - CY) <= H / 2 + P)))
    return inside


def render(path, g, bg, fg):
    x, y, c, r, on = state(g)
    if VAR == "a":
        paint_dots(x[on], y[on], r[on], bg, fg).save(path)
        return int(on.sum())
    k, rho, L = bk.mark_shape(c, P)
    sd = bk.card_sd(x, y - CY, CX, 0.0, W, H, RC)
    dot = c <= C0 + 1e-9                                      # sparse and settling stages: fixed radius r
    k, rho = np.where(dot, 0.0, k), np.where(dot, r, rho)
    rho = np.where(on, rho, 0.0)
    # a mark below the closing must lie whole inside the card or ribbon (never cut by the card's crisp edge)
    extent = np.where(L >= 0, P / 2, k + rho) - 0.5            # vertical half-height of a flat-top mark or cell
    cut = (sd > EDGE_ROOM - extent) & (x >= XL) & (c < CUT)   # synthetic_ramp's rule: whole marks, or solid
    rho, k, L = np.where(cut, 0.0, rho), np.where(cut, 0.0, k), np.where(cut, -1.0, L)
    pos = np.column_stack([x, y])
    sites = np.column_stack([lat[:, 0], CY + lat[:, 1] + drop(lat[:, 0])])
    bk.raster(path, sites, pos, k, rho, L, P, inside_at((1 - g) * (W + TAIL + 120)), bg, fg)
    return int(on.sum())


OUT.mkdir(parents=True, exist_ok=True)
for theme, (bg, fg) in THEMES.items():
    n = render(OUT / f"card-{theme}-1024.png", 1.0, bg, fg)
    img = Image.open(OUT / f"card-{theme}-1024.png")
    for s in (180, 58, 29):
        img.resize((s, s), Image.BOX).save(OUT / f"card-{theme}-{s}.png")
(OUT / "frames").mkdir(exist_ok=True)
for old in (OUT / "frames").glob("frame-*.png"):
    old.unlink()
strip = Image.new("RGB", (6 * 256, 256))
for i, t in enumerate((0.4, 0.52, 0.64, 0.76, 0.88, 1.0)):
    p = OUT / "frames" / f"frame-{int(t * 100):03d}.png"
    render(p, float(bk.smoothstep(t)), *THEMES["light"])
    strip.paste(Image.open(p).resize((256, 256), Image.BOX), (i * 256, 0))
strip.save(OUT / "strip.png")
ink = 1 - np.asarray(Image.open(OUT / "card-light-1024.png").convert("L"), float) / 249
ink = np.clip(ink, 0, 1)
ys, xs = np.nonzero(ink > 0.02)
opt = (((xs.min() + xs.max()) / 2 + (ink * np.arange(1024)[None]).sum() / ink.sum()) / 2,
       ((ys.min() + ys.max()) / 2 + (ink * np.arange(1024)[:, None]).sum() / ink.sum()) / 2)
print(f"round12 {VAR} seed {SEED}: {n} marks, ink {ink.mean():.1%}, optical centre ({opt[0]:.0f}, {opt[1]:.0f})"
      f" -> CX {CX + 512 - opt[0]:.0f} CY {CY + 512 - opt[1]:.0f}")
