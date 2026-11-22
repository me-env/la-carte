#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = ["numpy==2.3.4", "pillow==12.0.0", "scipy==1.16.3"]
# ///
"""Round 13: round 12 b refined. Dots stream in and converge into a solid card (b: with a second card behind).

Critic's changes on round 12 b, and how:
1. No neck at the junction: the stream flares to the card's full height at its left edge (FLARE, tangent to the
   top and bottom edges) and the card's left corners are square (the dotted ramp covers them). Iteration 2: the
   stream is straight and symmetric (DROP 0), sites and starts stay within the card's height, and a loose dot
   that would cross the card's top or bottom edge is dropped, so nothing overhangs.
2. Card at W / 1024 = 57% of the tile (3:2).
3. Shorter tail (TAIL 190, was 360); its grain is as large as the settling dots (R1 = R0) so it doesn't go grey.
4. Closing within the last CLOSE_T of the animation: until then coverage above the settling stage is scaled to
   top out at CAP_A (separate marks, see squash()); then the cap eases to 1 and the card closes into solid.
5. Iteration 2, a flashcard cue: a second card behind (STACK px up and right, a flat STACK_INK tint, GAP_B of
   paper around the front card), fading in with the closing. STACK=0: one card.

Construction, in a straight parameter space (u along the stream, v across it; px of a 1024 tile):
- Body: the card W x H, radius RC, centred at (CX, 0), left corners square. Ribbon for u < XL (TAIL long),
  half-width hw(s), s = XL - u: H/2 at the card, tapering upstream to TAPER * H/2.
- Curve (DROP > 0 only): a shear y += DROP * (s / TAIL)^2 (zero slope at the joint).
- Sites: brandkit.hex_lattice (pitch P) inside body U ribbon. Starts: random offsets (disc of radius J), relaxed
  to >= 0.62 P apart, paired to the sites by optimal transport (brandkit.match). A random rank decides which
  dots exist at low density.
- Ramp along u (PCHIP coverage through the stage joints): sparse grain (t < T1); the full set settling (OT0..T2,
  ease-out POW); then growth into rounded hexagons and the paper web (brandkit.mark_shape / raster), solid from
  FILL of W.
- Minimum spacing: pairs of moving dots closer than the gap rule are pushed apart every frame.
Animation (frames/, t in 0..1): the ramp slides in, S = (1 - smoothstep(t / (1 - CLOSE_T))) SPAN, with coverage
squashed to CAP_A; over the last CLOSE_T the cap eases from CAP_A to 1. Reduce Motion: final frame, 0.25 s fade.
    uv run --script render.py                                  # -> round13/b/{card-<theme>-<size>.png, frames/, strip.png}
    STACK=0 CX=566 CY=510 OUT=b-single uv run --script render.py   # one card
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

P = env("P", "10.5")                                         # lattice pitch
R0 = 0.6 * P / 2.7                                           # radius when the set is full and settling
CELL = math.sqrt(3) / 2 * P * P
C0 = math.pi * R0 ** 2 / CELL
R1 = env("R1", "1.0") * R0                                   # sparse-grain radius
C1 = math.pi * R1 ** 2 / CELL
CMAX = 1.0
W, H, RC = env("W", "584"), env("H", "390"), env("RC", "56")
E = P / 2
DX = P * math.sqrt(3) / 2
W = 2 * E + round((W - 2 * E) / DX) * DX                     # snap: left and right edges are lattice columns
H = 2 * E + round((H - 2 * E) / P) * P
CX, CY = env("CX", "560"), env("CY", "530")                  # optical centring (printed below)
XL, XR = CX - W / 2, CX + W / 2
TAIL = env("TAIL", "190")
U0 = XL - TAIL
DROP = env("DROP", "0")
FILL = env("FILL", "0.36")                                   # solid from XL + FILL * W
FLARE = env("FLARE", "1")                                    # 1: the stream meets the card at its full height
FLARE_L = env("FLARE_L", "1.6") * RC                          # length of the flare
TAPER = env("TAPER", "0.55")                                 # tail end half-width, as a share of H/2
EDGE_ROOM = P / 2 + 0.5                                      # see inside_at()
CUT = env("CUT", "0.9")                                      # below this coverage marks stay whole (no clipping)
GAP = 0.2 * 1.10                                             # gap rule with a margin (anti-aliasing)
CLOSE_T = env("CLOSE_T", "0.2")                              # closing happens in the last CLOSE_T of the animation
CAP_A = env("CAP_A", "0.45")                                 # coverage cap until the closing


def body_sd(u, v):
    """Signed distance to the card with square left corners (the left side is the dotted ramp)."""
    sq = bk.card_sd(u, v, XL + W / 4, 0.0, W / 2, H, 0.0)    # left half, sharp corners
    return np.minimum(bk.card_sd(u, v, CX, 0.0, W, H, RC), sq)


def hw(s):
    """Ribbon half-width at s upstream of the card's left edge: H/2 at the card (flat, tangent to its edges),
    tapering to TAPER * H/2 at the tail's end."""
    t = np.clip(s / TAIL, 0, 1)
    narrow = H / 2 * (1 - (1 - TAPER) * bk.smoothstep(t))
    return narrow + (H / 2 - narrow) * FLARE * (1 - bk.smoothstep(s / FLARE_L))


def card(u, v, grow=0.0):
    return body_sd(u, v) <= grow


def ribbon(u, v, grow=0.0):
    s = XL - u
    return (s >= 0) & (s <= TAIL) & (np.abs(v) <= hw(s) + grow)


def drop(u):
    return DROP * np.clip((XL - u) / TAIL, 0, 1) ** 2


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
T1, T2 = env("T1", "0.15"), env("T2", "0.45")
H0 = env("H0", "0.06")
_h = PchipInterpolator([0, T1, T2, 1], [H0 * CMAX, C1, C0, CMAX])


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
    x, y = pu, CY + pv + drop(pu)
    r = np.maximum(R1, np.sqrt(np.minimum(c, C0) * CELL / math.pi))
    moving = (w < 1) & present
    if moving.any():
        x, y = spread(x, y, r, present)
    over = (w < 1) & (np.abs(y - CY - drop(x)) > H / 2 - r)   # no loose dot pokes past the card's edges: drop it
    present = present & ~over
    return x, y, c, r, present, S, cap


def inside_at(S, cap):
    """The pixel mask ink is limited to: the body, with a crisp edge where the marks are solid (coverage >= CUT)
    and half a pitch of room for whole edge cells where they are not, and the sheared ribbon with room for loose
    dots."""
    def inside(xs, ys):
        v = ys - CY - drop(xs)
        room = card(xs, ys - CY, EDGE_ROOM) & (squash(cov(xs - S), cap) < CUT)
        return (card(xs, ys - CY) | room | ribbon(xs, v, P + J)
                | ((xs < XL) & (xs >= XL - P - J) & (np.abs(ys - CY) <= H / 2 + P)))
    return inside


def render(path, t, bg, fg):
    x, y, c, r, on, S, cap = state(t)
    k, rho, L = bk.mark_shape(c, P)
    sd = body_sd(x, y - CY)
    dot = c <= C0 + 1e-9
    k, rho = np.where(dot, 0.0, k), np.where(dot, r, rho)
    rho = np.where(on, rho, 0.0)
    extent = np.where(L >= 0, P / 2, k + rho) - 0.5
    cut = (sd > EDGE_ROOM - extent) & (x >= XL) & (c < CUT)
    rho, k, L = np.where(cut, 0.0, rho), np.where(cut, 0.0, k), np.where(cut, -1.0, L)
    pos = np.column_stack([x, y])
    sites = np.column_stack([lat[:, 0], CY + lat[:, 1] + drop(lat[:, 0])])
    bk.raster(path, sites, pos, k, rho, L, P, inside_at(S, cap), bg, fg)
    if STACK > 0:
        back(path, (cap - CAP_A) / (1 - CAP_A), bg, fg)
    return int(on.sum())


STACK = env("STACK", "44")                                    # offset of a second card behind (0: none)
STACK_INK = env("STACK_INK", "0.35")                         # its ink, as a share of the foreground


def back(path, a, bg, fg, ss=4):
    """A second card behind, offset up and right by STACK, a flat STACK_INK tint, with a paper gap of GAP_B around
    the front card; it fades in with the closing (a = 0 -> 1)."""
    ys, xs = (np.mgrid[0:1024 * ss, 0:1024 * ss] + 0.5) / ss
    b = bk.card_sd(xs, ys, CX + STACK, CY - STACK, W, H, RC) <= 0
    b &= bk.card_sd(xs, ys, CX, CY, W, H, RC) > env("GAP_B", "12")
    m = b.reshape(1024, ss, 1024, ss).mean(axis=(1, 3))[..., None] * STACK_INK * a
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
    ink = np.clip(1 - np.asarray(Image.open(OUT / "card-light-1024.png").convert("L"), float) / 249, 0, 1)
    ys, xs = np.nonzero(ink > 0.02)
    opt = (((xs.min() + xs.max()) / 2 + (ink * np.arange(1024)[None]).sum() / ink.sum()) / 2,
           ((ys.min() + ys.max()) / 2 + (ink * np.arange(1024)[:, None]).sum() / ink.sum()) / 2)
    print(f"round13 seed {SEED}: {n} marks, ink {ink.mean():.1%}, card {W / 1024:.0%} of the tile, optical centre"
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
