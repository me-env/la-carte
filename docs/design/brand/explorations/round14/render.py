#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = ["numpy==2.3.4", "pillow==12.0.0", "scipy==1.16.3"]
# ///
"""Round 14: round 13 b refined. Dots stream in and converge into a solid card, a halftone card behind.

Critic's changes on round 13 b, and how:
1. Back card in the brand's halftone: dots on the front card's own lattice at a fixed coverage BACK_C (0.28), kept
   inside the back card (STACK up and right, the same on both axes) with GAP_B (one pitch) of paper from the
   front card, following its corner; it fades in (opacity) after the front card is solid (BACK_T0). STACK=0: one card.
5. Iteration 2: a taller card (H 460, was 388), closer to an index card, so the mark reads less like a strip.
2. The tail keeps the card's full height (no taper): only its density fades upstream.
3. Wider closing: the ramp gets a knot (TC, CW) so coverage climbs from CW (the web's start) to solid over
   (1 - TC) of the ramp, ~150 px (was ~91 px).
4. No overhang: right of the card's left edge ink is limited to the card itself (no edge room); a mark still in its
   dot/hexagon stage that would cross the card's edge is dropped, web-stage cells are clipped crisply by the edge.
Kept from rounds 12/13: no neck (the stream is the card's height), card 57% of the tile, closing in the last
CLOSE_T (20%) of the animation, seed 23.

Construction, in a straight parameter space (u along the stream, v across it; px of a 1024 tile):
- Body: the card W x H, radius RC, centred at (CX, 0), left corners square. Ribbon for u < XL (TAIL long), the
  card's full height.
- Sites: brandkit.hex_lattice (pitch P) inside body U ribbon. Starts: random offsets (disc of radius J), relaxed
  to >= 0.62 P apart, paired to the sites by optimal transport (brandkit.match). A random rank decides which
  dots exist at low density.
- Ramp along u (PCHIP coverage through the stage joints): sparse grain (t < T1); the full set settling (OT0..T2,
  ease-out POW); growth into rounded hexagons (T2..TC); the paper web closing (TC..1), solid from FILL of W.
- Minimum spacing: pairs of moving dots closer than the gap rule are pushed apart every frame.
Animation (frames/, t in 0..1): the ramp slides in, S = (1 - smoothstep(t / (1 - CLOSE_T))) SPAN, with coverage
squashed to CAP_A; over the last CLOSE_T the cap eases from CAP_A to 1. Reduce Motion: final frame, 0.25 s fade.
    uv run --script render.py                                  # -> round14/b/{card-<theme>-<size>.png, frames/, ...}
    STACK=0 CX=566 CY=512 OUT=b-single uv run --script render.py   # one card
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
OUT = Path(os.environ.get("OUT", HERE / "b"))
SEED = int(os.environ.get("SEED", "23"))
THEMES = {"light": ("#F9FAF5", "#1C1C1C"), "dark": ("#1A1A1A", "#F2F2F0"), "forest": ("#0E1913", "#EEF2EC")}

P = env("P", "11.4")                                         # lattice pitch
R0 = 0.6 * P / 2.7                                           # radius when the set is full and settling
CELL = math.sqrt(3) / 2 * P * P
C0 = math.pi * R0 ** 2 / CELL
R1 = env("R1", "1.0") * R0                                   # sparse-grain radius
C1 = math.pi * R1 ** 2 / CELL
CMAX = 1.0
W, H, RC = env("W", "584"), env("H", "460"), env("RC", "60")
E = P / 2
DX = P * math.sqrt(3) / 2
W = 2 * E + round((W - 2 * E) / DX) * DX                     # snap: left and right edges are lattice columns
H = 2 * E + round((H - 2 * E) / P) * P
CX, CY = env("CX", "540"), env("CY", "530")                  # optical centring (printed below)
XL, XR = CX - W / 2, CX + W / 2
TAIL = env("TAIL", "190")
U0 = XL - TAIL
FILL = env("FILL", "0.48")                                   # solid from XL + FILL * W
GAP = 0.2 * 1.10                                             # gap rule with a margin (anti-aliasing)
CLOSE_T = env("CLOSE_T", "0.2")                              # closing happens in the last CLOSE_T of the animation
CAP_A = env("CAP_A", "0.45")                                 # coverage cap until the closing


def body_sd(u, v):
    """Signed distance to the card with square left corners (the left side is the dotted ramp)."""
    sq = bk.card_sd(u, v, XL + W / 4, 0.0, W / 2, H, 0.0)    # left half, sharp corners
    return np.minimum(bk.card_sd(u, v, CX, 0.0, W, H, RC), sq)


def card(u, v, grow=0.0):
    return body_sd(u, v) <= grow


def ribbon(u, v, grow=0.0):
    s = XL - u
    return (s >= 0) & (s <= TAIL) & (np.abs(v) <= H / 2 + grow)


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
UA, UB = U0, XL + FILL * W
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
    present = present & ~over
    return x, y, c, r, present, S, cap


def inside(xs, ys):
    """The pixel mask ink is limited to: the card, crisp, and left of it the ribbon with room for loose dots."""
    return card(xs, ys - CY) | ((xs < XL) & (xs >= U0 - P - J) & (np.abs(ys - CY) <= H / 2 + P + J))


def render(path, t, bg, fg):
    x, y, c, r, on, S, cap = state(t)
    k, rho, L = bk.mark_shape(c, P)
    sd = body_sd(np.maximum(x, XL + W / 4), y - CY)            # top, bottom and right edges (left: the stream)
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


STACK = env("STACK", "57")                                    # offset of a second card behind, up and right (0: none)
BACK_T0 = env("BACK_T0", "0.96")                              # it fades in after the front card is solid
BACK_C = env("BACK_C", "0.28")                                # its halftone coverage
GAP_B = env("GAP_B", "1") * P                                 # paper between the front card and the back card's dots
RB = math.sqrt(BACK_C * CELL / math.pi)
_bl = bk.hex_lattice(XL, XR - E + 2 * math.ceil(STACK / DX) * DX, -(H / 2 - E) - 2 * math.ceil(STACK / P) * P,
                     H / 2, P)                                # the front card's lattice, extended up and right
_bl = _bl + [0, CY]
BACK = _bl[(bk.card_sd(_bl[:, 0], _bl[:, 1], CX + STACK, CY - STACK, W, H, RC) <= -RB * env("BACK_IN", "0.5"))
           & (bk.card_sd(_bl[:, 0], _bl[:, 1], CX, CY, W, H, RC) >= GAP_B + RB)] if STACK > 0 else _bl[:0]


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
    print(f"round14 seed {SEED}: {n} marks, ink {ink.mean():.1%}, card {W / 1024:.0%} of the tile, optical centre"
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
