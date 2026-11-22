#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = ["numpy==2.3.4", "pillow==12.0.0", "scipy==1.16.3"]
# ///
"""Round 15: round 14 b refined, and b-single redrawn as a card with a dust trail.

`b` (two cards), the critic's round 14 steps:
1. Back card corner: its halftone dots sit on rows parallel to the front card's edge (offset curves at
   GAP_B + RB + k * P sqrt(3)/2, k = 0..ROWS-1), odd rows offset half a step,
   so the outer corner is a true arc (radius RC + STACK), not a lattice staircase.
   Iteration 2 (critic): every row has the same number of dots through the arc (equal angle, odd rows offset half a
   step), and the band's ends are cut square on one line for all rows (the back card shifted STACK up and right).
2. Paper gap GAP_B = 2 pitches between the front card and the back card's dots; 4 rows.
3. The 58 px drawdown (0.039 at t 0.65): re-centring (CX 532 CY 531) moved the 58 px sampling grid and it fell to
   0.027 (all frames); the ramp itself is unchanged.
`b-single` (SINGLE=1), to read as a card, not a fade bar: a whole rounded card (all four corners RC, about 3:2),
solid at rest, and a trail of grain dots left of it that stops GAP_T (2 pitches) before the card's left edge and never
grows past the dot stage (coverage <= TRAIL_MAX x C0, order eased in upstream). The ramp still slides through the
card during the animation; its closing ends in the paper gap (UB = XL - GAP_T), so the card is solid at rest.
Kept from rounds 12-14: no neck, closing in the last CLOSE_T (20%) of the animation, seed 23, pitch 11.4.

Construction, in a straight parameter space (u along the stream, v across it; px of a 1024 tile):
- Body: the card W x H, radius RC, centred at (CX, 0) (b: left corners square). Ribbon (the trail) left of it.
- Sites: brandkit.hex_lattice (pitch P) inside body U ribbon. Starts: random offsets (disc of radius J), relaxed
  to >= 0.62 P apart, paired to the sites by optimal transport (brandkit.match). A random rank decides which
  dots exist at low density.
- Ramp along u (PCHIP coverage through the stage joints): sparse grain (t < T1); the full set settling (OT0..T2,
  ease-out POW); growth into rounded hexagons (T2..TC); the paper web closing (TC..1), solid from UB.
- Minimum spacing: pairs of moving dots closer than the gap rule are pushed apart every frame.
Animation (frames/, t in 0..1): the ramp slides in, S = (1 - smoothstep(t / (1 - CLOSE_T))) SPAN, with coverage
squashed to CAP_A; over the last CLOSE_T the cap eases from CAP_A to 1. Reduce Motion: final frame, 0.25 s fade.
    uv run --script render.py                                   # -> round15/b/...
    SINGLE=1 OUT=b-single uv run --script render.py             # one card + trail (its CX/CY defaults differ)
"""
import math, os, sys
from pathlib import Path
sys.path.insert(0, str(next(p for p in Path(__file__).resolve().parents if (p / "scripts/brandkit.py").exists()) / "scripts"))
import brandkit as bk
import numpy as np
from PIL import Image, ImageDraw
from scipy.interpolate import PchipInterpolator
from scipy.spatial import cKDTree

env = lambda k, d: float(os.environ.get(k, d))
HERE = Path(__file__).resolve().parent
SINGLE = os.environ.get("SINGLE") == "1"
OUT = Path(os.environ.get("OUT", HERE / ("b-single" if SINGLE else "b")))
SEED = int(os.environ.get("SEED", "23"))
THEMES = {"light": ("#F9FAF5", "#1C1C1C"), "dark": ("#1A1A1A", "#F2F2F0"), "forest": ("#0E1913", "#EEF2EC")}

P = env("P", "11.4")                                         # lattice pitch
R0 = 0.6 * P / 2.7                                           # radius when the set is full and settling
CELL = math.sqrt(3) / 2 * P * P
C0 = math.pi * R0 ** 2 / CELL
R1 = env("R1", "1.0") * R0                                   # sparse-grain radius
C1 = math.pi * R1 ** 2 / CELL
CMAX = 1.0
W, H, RC = (env("W", "560"), env("H", "374"), env("RC", "80")) if SINGLE else (env("W", "584"), env("H", "460"), env("RC", "60"))
E = P / 2
DX = P * math.sqrt(3) / 2
W = 2 * E + round((W - 2 * E) / DX) * DX                     # snap: left and right edges are lattice columns
H = 2 * E + round((H - 2 * E) / P) * P
CX, CY = (env("CX", "576"), env("CY", "513")) if SINGLE else (env("CX", "532"), env("CY", "531"))                  # optical centring (printed below)
XL, XR = CX - W / 2, CX + W / 2
TAIL = env("TAIL", "230" if SINGLE else "190")
GAP_T = env("GAP_T", "2") * P                                # single: paper between the trail and the card
TRAIL_MAX = env("TRAIL_MAX", "0.8")                          # single: trail coverage cap, x C0 (dots only)
U0 = XL - TAIL
FILL = env("FILL", "0.48")                                   # solid from XL + FILL * W
GAP = 0.2 * 1.10                                             # gap rule with a margin (anti-aliasing)
CLOSE_T = env("CLOSE_T", "0.2")                              # closing happens in the last CLOSE_T of the animation
CAP_A = env("CAP_A", "0.45")                                 # coverage cap until the closing


def body_sd(u, v):
    """Signed distance to the card with square left corners (the left side is the dotted ramp)."""
    if SINGLE:
        return bk.card_sd(u, v, CX, 0.0, W, H, RC)
    sq = bk.card_sd(u, v, XL + W / 4, 0.0, W / 2, H, 0.0)    # left half, sharp corners
    return np.minimum(bk.card_sd(u, v, CX, 0.0, W, H, RC), sq)


def card(u, v, grow=0.0):
    return body_sd(u, v) <= grow


def ribbon(u, v, grow=0.0):
    s = XL - u
    return (s >= (GAP_T if SINGLE else 0)) & (s <= TAIL) & (np.abs(v) <= H / 2 + grow)


# ---------------------------------------------------------------- sites
lat = bk.hex_lattice(U0 - P, XR - E, -(H / 2 - E), H / 2 + P, P)
lat = lat[(card(lat[:, 0], lat[:, 1], 0.6 * P) & (lat[:, 0] >= XL - 1)) | ribbon(lat[:, 0], lat[:, 1], -E)]

J, D_START = env("J", "0.65") * P, 0.62 * P
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
start[:, 1] = np.clip(start[:, 1], -(H / 2 - E), H / 2 - E)  # starts stay within the card's height too
start = bk.match(lat, start)
rank = bk.rng(SEED + 1).permutation(len(start)) / len(start)

# ---------------------------------------------------------------- ramp
RAMP = env("RAMP", "470")                                    # single: ramp length (b: TAIL + FILL W)
UA, UB = (XL - GAP_T - RAMP, XL - GAP_T) if SINGLE else (U0, XL + FILL * W)
T1, T2 = env("T1", "0.15"), env("T2", "0.38")
H0 = env("H0", "0.06")
CW = env("CW", "0.65")                                       # coverage where the closing (web) starts: bk.CLOSE_START
TC = 1 - env("CLOSE_PX", "150") / (UB - UA)                  # ... and where on the ramp: CLOSE_PX before the solid
_h = PchipInterpolator([0, T1, T2, TC, 1], [H0 * CMAX, C1, C0, CW, CMAX])


def cov(u):
    t = (u - UA) / (UB - UA)
    return np.where(t >= 0, _h(np.clip(t, 0, 1)), H0 * CMAX * bk.smoothstep(1 + t / 0.06))


POW = env("POW", "1.6")                                      # ease-out power of the settling
OT0 = env("OT0", "0.05")                                     # settling starts here on the ramp, ends at T2


def order(u):
    return 1 - (1 - np.clip(((u - UA) / (UB - UA) - OT0) / (T2 - OT0), 0, 1)) ** POW


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
        need = (1 + GAP) * (r[i] + r[j]) + 0.5 * (np.maximum(r[i], r[j]) <= R0 + 1e-6)
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


SPAN = W + TAIL + 120
DRIFT = env("DRIFT", "25")


def phase(t):
    """(ramp shift S, coverage cap, slide progress g) at animation time t (1 = the still logo)."""
    a = 1 - CLOSE_T
    g = float(bk.smoothstep(min(t / a, 1.0)))
    cap = CAP_A + (1 - CAP_A) * float(bk.smoothstep(max((t - a) / CLOSE_T, 0.0)))
    return (1 - g) * SPAN, cap, g


def squash(c, cap):
    """Coverage above C0 scaled so the ramp tops out at cap (the ramp keeps its shape; cap 1 = unchanged)."""
    return np.where(c > C0, C0 + (c - C0) * (cap - C0) / (1 - C0), c)


def state(t=1.0):
    S, cap, g = phase(t)
    c, w = squash(cov(lat[:, 0] - S), cap), order(lat[:, 0] - S)
    if SINGLE:                                                 # the trail stays grain: dots only, eased order
        tr = lat[:, 0] < XL
        q = bk.smoothstep((lat[:, 0] - (XL - TAIL)) / (TAIL - GAP_T))
        c = np.where(tr, np.minimum(c, H0 + (TRAIL_MAX * C0 - H0) * q), c)
        w = np.where(tr, np.minimum(w, 0.3 + 0.45 * q), w)
    f = c / C1
    present = (f - rank) / (0.15 * np.minimum(f, 1) + 1e-9) >= 0.5
    pu = start[:, 0] * (1 - w) + lat[:, 0] * w - DRIFT * (1 - g) * (1 - w)
    pv = start[:, 1] * (1 - w) + lat[:, 1] * w
    x, y = pu, CY + pv
    r = np.maximum(R1, np.sqrt(np.minimum(c, C0) * CELL / math.pi))
    moving = (w < 1) & present
    if moving.any():
        x, y = spread(x, y, r, present)
    over = (w < 1) & (np.abs(y - CY) > H / 2 - r)   # no loose dot pokes past the card's edges: drop it
    if SINGLE:                                       # ... nor a trail dot into the paper gap
        over |= (lat[:, 0] < XL) & (x + r > XL - GAP_T / 2)
    present = present & ~over
    return x, y, c, r, present, S, cap


def inside(xs, ys):
    """The pixel mask ink is limited to: the card, crisp, and left of it the ribbon with room for loose dots."""
    return card(xs, ys - CY) | ((xs < XL - (GAP_T / 2 if SINGLE else 0)) & (xs >= U0 - P - J) & (np.abs(ys - CY) <= H / 2 + P + J))


def render(path, t, bg, fg):
    x, y, c, r, on, S, cap = state(t)
    k, rho, L = bk.mark_shape(c, P)
    sd = body_sd(x if SINGLE else np.maximum(x, XL + W / 4), y - CY)            # top, bottom and right edges (left: the stream)
    dot = c <= C0 + 1e-9
    k, rho = np.where(dot, 0.0, k), np.where(dot, r, rho)
    rho = np.where(on, rho, 0.0)
    cut = (sd > -(k + rho) + 0.5) & (x >= XL) & (L < 0)      # a separate mark crossing the edge: drop it
    rho, k = np.where(cut, 0.0, rho), np.where(cut, 0.0, k)
    pos = np.column_stack([x, y])
    sites = np.column_stack([lat[:, 0], CY + lat[:, 1]])
    bk.raster(path, sites, pos, k, rho, L, P, inside, bg, fg)
    if STACK > 0:
        back(path, float(bk.smoothstep((t - BACK_T0) / (1 - BACK_T0))), bg, fg)
    return int(on.sum())


BACK_T0 = env("BACK_T0", "0.96")                              # it fades in after the front card is solid
BACK_C = env("BACK_C", "0.28")                                # its halftone coverage
GAP_B = env("GAP_B", "2") * P                                 # paper between the front card and the back card's dots
ROWS = int(env("ROWS", "4"))
RB = math.sqrt(BACK_C * CELL / math.pi)
ROW = P * math.sqrt(3) / 2
D_ROWS = [GAP_B + RB + k * ROW for k in range(ROWS)]          # dot centres' distance to the front card's edge
STACK = 0.0 if SINGLE else env("STACK", str(D_ROWS[-1] + RB))  # the back card: shifted up and right by STACK


def back_sites():
    """Dots on offset curves of the front card's top edge, top-right arc and right edge. Every row has the same
    number of dots through the arc (equal angle, NA steps, odd rows offset half a step) and P apart on the straights;
    the band ends are cut square (top: x >= XL + STACK, right: y <= bottom - STACK), on one line for all rows."""
    ox, oy = XR - RC, CY - H / 2 + RC                         # the front card's top-right corner centre
    na = max(1, round((RC + D_ROWS[len(D_ROWS) // 2]) * math.pi / 2 / P))
    da = math.pi / 2 / na
    pts = []
    for k, d in enumerate(D_ROWS):
        rr, h = RC + d, 0.5 * (k % 2)
        pts += [(ox + rr * math.cos((j + h) * da), oy - rr * math.sin((j + h) * da)) for j in range(na + 1) if j + h <= na]
        first = (1 - h) * P if h == 0 else h * P             # the first straight dot after the arc's end
        n = int(max(W, H) / P) + 2
        pts += [(ox - first - m * P, CY - H / 2 - d) for m in range(n)]   # top edge, leftward
        pts += [(XR + d, oy + first + m * P) for m in range(n)]           # right edge, downward
    pts = np.array(pts)
    keep = (pts[:, 0] >= XL + STACK) & (pts[:, 1] <= CY + H / 2 - STACK)
    return pts[keep]


BACK = back_sites() if STACK > 0 else np.zeros((0, 2))


def back(path, a, bg, fg, ss=4):
    """The halftone card behind: dots of radius RB on BACK, at opacity a (0 -> 1 with the closing)."""
    ys, xs = (np.mgrid[0:1024 * ss, 0:1024 * ss] + 0.5) / ss
    d = cKDTree(BACK).query(np.column_stack([xs.ravel(), ys.ravel()]), distance_upper_bound=RB + 1)[0]
    m = (d <= RB).reshape(1024 * ss, 1024 * ss).reshape(1024, ss, 1024, ss).mean(axis=(1, 3))[..., None] * a
    h = lambda c: np.array([int(c[i:i + 2], 16) for i in (1, 3, 5)], float)
    im = np.asarray(Image.open(path).convert("RGB"), float)
    Image.fromarray((im * (1 - m) + h(fg) * m).astype(np.uint8)).save(path)


OUT.mkdir(parents=True, exist_ok=True)
FRAMES = (0.3, 0.5, 0.65, 0.8, 0.85, 0.9, 0.95, 1.0)
if not os.environ.get("FRAMES_ONLY"):
    for theme, (bg, fg) in THEMES.items():
        n = render(OUT / f"card-{theme}-1024.png", 1.0, bg, fg)
        img = Image.open(OUT / f"card-{theme}-1024.png")
        for s in (180, 58, 29):
            img.resize((s, s), Image.BOX).save(OUT / f"card-{theme}-{s}.png")
    for s in (1024, 58, 29):                                  # static app-icon candidate: the settled light frame
        Image.open(OUT / "card-light-1024.png").resize((s, s), Image.BOX).save(OUT / f"app-icon-{s}.png")
    ink = np.clip(1 - np.asarray(Image.open(OUT / "card-light-1024.png").convert("L"), float) / 249, 0, 1)
    ys, xs = np.nonzero(ink > 0.02)
    opt = (((xs.min() + xs.max()) / 2 + (ink * np.arange(1024)[None]).sum() / ink.sum()) / 2,
           ((ys.min() + ys.max()) / 2 + (ink * np.arange(1024)[:, None]).sum() / ink.sum()) / 2)
    print(f"round15 seed {SEED}: {n} marks, ink {ink.mean():.1%}, card {W / 1024:.0%} of the tile, optical centre"
          f" ({opt[0]:.0f}, {opt[1]:.0f}) -> CX {CX + 512 - opt[0]:.0f} CY {CY + 512 - opt[1]:.0f}")
if not os.environ.get("STILL_ONLY"):
    (OUT / "frames").mkdir(exist_ok=True)
    for old in (OUT / "frames").glob("frame-*.png"):
        old.unlink()
    strip = Image.new("RGB", (len(FRAMES) * 256, 256))
    for i, t in enumerate(FRAMES):
        p = OUT / "frames" / f"frame-{int(t * 100):03d}.png"
        render(p, t, *THEMES["light"])
        strip.paste(Image.open(p).resize((256, 256), Image.BOX), (i * 256, 0))
    strip.save(OUT / "strip.png")

if not os.environ.get("STILL_ONLY") and not os.environ.get("FRAMES_ONLY"):
    vyst = next(p for p in Path(__file__).resolve().parents if (p / "scripts/brandkit.py").exists()) / "docs/design/reference/vyst-app-icon-512.png"
    shots = [OUT / f"card-{t}-1024.png" for t in THEMES] + [OUT / "strip.png"]
    shots += [OUT / f"card-light-{s}.png" for s in (180, 58, 29)] + ([vyst] if vyst.exists() else [])
    bk.contact_sheet(shots, OUT.parent / f"contact-sheet-{OUT.name}.png")   # local only (embeds Vyst): gitignored
