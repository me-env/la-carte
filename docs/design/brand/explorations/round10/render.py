#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = ["numpy==2.3.4", "pillow==12.0.0", "scipy==1.16.3"]
# ///
"""Round 10: one light flashcard. Its outline and two text bars (a word, its answer) are the structure; their left
part is lost data points that stream in along curves from the left and settle into the solid strokes.
Construction (px at 1024):
- Card outline 560 × 400, corner radius 52, stroke 28 (≈ 1.6 px at 58 px). Bars inside, left-aligned at the card's
  inner margin: word 300 × 44, answer 190 × 44, radius 22 (capsules), 40 px apart.
- Structure mask S = outline ∪ bars. Coverage along x: c(x) = 0.03 + 0.97·smoothstep from x0 (tail start, 150 px
  left of the card) to x1 (40% into the card); solid beyond.
- Inside S: the round-9 stochastic construction (brandkit.progressive_blue_noise sets A for dots, B for holes;
  dots grow, then round holes shrink into solid; 2.2 px closing from coverage 0.5). Dots never cross S's edge
  below coverage 0.4 (dropped, not clipped).
- Tails: left of the card, each bar continues as a curved stream (centre y drifts by a sine of 40 px over the tail),
  a band of the same blue-noise dots whose density follows c(x). The top and bottom outline strokes get the same
  treatment as the bars (their tails curve away), so everything enters from the left.
- Ink ≈ 10% of the tile (Vyst's weight).
Animation: same construction at coverage c·g(t). Reduce Motion: final frame, 0.3 s crossfade.
Measure with design-review on the word bar's band: --region <printed at the end> --screen stochastic.
"""
import math, os, sys
from pathlib import Path
sys.path.insert(0, str(next(p for p in Path(__file__).resolve().parents if (p / "scripts/brandkit.py").exists()) / "scripts"))
import brandkit as bk
import numpy as np
from PIL import Image
from scipy import ndimage
from scipy.spatial import cKDTree

HERE = Path(__file__).resolve().parent
OUT = Path(os.environ.get("OUT", HERE))
W, H, RC, STROKE = 560.0, 400.0, 52.0, 28.0
CX, CY = float(os.environ.get("CX", "560")), 512.0
XL, XR, TOP, BOT = CX - W / 2, CX + W / 2, CY - H / 2, CY + H / 2
PAD = 64.0                                          # inner margin to the bars
BARS = [(XL + STROKE + PAD, 300.0, CY - 42.0), (XL + STROKE + PAD, 190.0, CY + 42.0)]   # (x0, length, y centre)
BH = 44.0
TAIL = 150.0
X0, X1 = XL - TAIL, XL + 0.40 * W
R0, WALL, SS = 2.6, 2.2, 4
D_MIN = 2.5 * R0
SEED = int(os.environ.get("SEED", "41"))
THEMES = {"dark": ("#151514", "#F2F2F0"), "light": ("#F9FAF5", "#1C1C1C"), "forest": ("#0E1913", "#EEF2EC")}
target = lambda x: np.where(x >= X1, 1.0, 0.03 + 0.97 * bk.smoothstep((x - X0) / (X1 - X0)))


def sd_rect(x, y, cx, cy, w, h, r):
    qx, qy = np.abs(x - cx) - (w / 2 - r), np.abs(y - cy) - (h / 2 - r)
    return np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - r


def drift(x, amp):
    """Vertical offset of a tail at x (0 inside the card, curving away to the left)."""
    t = np.clip((XL - x) / TAIL, 0, 1)
    return amp * t * t


def sd_structure(x, y):
    """Signed distance (approx.) to S: outline ring ∪ bars ∪ their curved tails (negative inside)."""
    outer = sd_rect(x, y, CX, CY, W, H, RC)
    inner = sd_rect(x, y, CX, CY, W - 2 * STROKE, H - 2 * STROKE, RC - STROKE)
    ring = np.maximum(outer, -inner)
    d = ring
    for (bx, L, by), amp in zip(BARS, (-34.0, 30.0)):
        yy = y - drift(x, amp)
        bar = sd_rect(x, yy, (bx - TAIL - 40 + bx + L) / 2, by, L + TAIL + 40 + (bx - XL), BH, BH / 2)
        bar = np.where(x > bx + L - BH / 2, sd_rect(x, yy, bx + L / 2, by, L, BH, BH / 2), bar)
        d = np.minimum(d, np.maximum(bar, x - (bx + L)))
    for yc, amp in ((TOP + STROKE / 2, -40.0), (BOT - STROKE / 2, 40.0)):   # outline top/bottom strokes' tails
        yy = y - drift(x, amp)
        tail = np.maximum(np.abs(yy - yc) - STROKE / 2, np.maximum(x - (XL + RC), X0 - 10 - x))
        d = np.minimum(d, np.where(x < XL + RC * 0.5, tail, 1e9))
    return d


RECT = (X0 - 10, XR + 10, TOP - 60, BOT + 60)
A = bk.progressive_blue_noise(100000, RECT, D_MIN, SEED)
B = bk.progressive_blue_noise(100000, RECT, D_MIN, SEED + 1000)
RANK = np.arange(len(A)) / len(A)
RHO_MAX = len(A) / ((RECT[1] - RECT[0]) * (RECT[3] - RECT[2]))
C_D = RHO_MAX * math.pi * R0 ** 2
JIT = bk.rng(SEED + 7).uniform(-1.5, 1.5, len(B)) * D_MIN
RH0 = 0.9 * D_MIN
SA = sd_structure(A[:, 0], A[:, 1])


def render(cov_fn, ss=SS):
    c = cov_fn(A[:, 0])
    r = np.where(c <= C_D, R0, R0 * np.sqrt(c / C_D))
    r = np.where(c < 0.36, np.minimum(r, D_MIN / 2.5), r)
    show = (RANK < np.minimum(c / C_D, 1.0)) & ((SA <= -r) | ((c >= 0.4) & (SA <= 0)))
    cb = cov_fn(B[:, 0] + JIT)
    rh = np.where(cb < 0.5, 1e9, RH0 * np.clip((1 - cb) / 0.5, 0, 1))
    ys, xs = (np.mgrid[0:1024 * ss, 0:1024 * ss] + 0.5) / ss
    inside = sd_structure(xs, ys) <= 0
    p = np.column_stack([xs[inside], ys[inside]])
    ink_in = np.zeros(len(p), bool)
    if show.any():
        d, j = cKDTree(A[show]).query(p, k=4, distance_upper_bound=3 * D_MIN)
        ink_in = (d < r[show][np.where(np.isinf(d), 0, j)]).any(axis=1)
    db, jb = cKDTree(B).query(p, k=1)
    ink_in |= db > rh[jb]
    ink = np.zeros(xs.shape, bool)
    ink[inside] = ink_in
    rp = int(round(WALL / 2 * ss))
    st = np.hypot(*np.mgrid[-rp:rp + 1, -rp:rp + 1]) <= rp
    return np.where(cov_fn(xs) >= 0.5, ndimage.binary_closing(ink, structure=st), ink) & inside


def paint(ink, bg, fg, ss=SS):
    h = lambda s: np.array([int(s[i:i + 2], 16) for i in (1, 3, 5)], float)
    cov = ink.reshape(1024, ss, 1024, ss).mean(axis=(1, 3))[..., None]
    return Image.fromarray((h(bg) * (1 - cov) + h(fg) * cov).astype(np.uint8))


ink = render(target)
cov = ink.reshape(1024, SS, 1024, SS).mean(axis=(1, 3))
ysx, xsx = np.nonzero(cov > 0.02)
optical = (((xsx.min() + xsx.max()) / 2 + (cov * np.arange(1024)[None]).sum() / cov.sum()) / 2,
           ((ysx.min() + ysx.max()) / 2 + (cov * np.arange(1024)[:, None]).sum() / cov.sum()) / 2)
for theme, (bg, fg) in THEMES.items():
    img = paint(ink, bg, fg)
    img.save(OUT / f"card-{theme}-1024.png")
    for s in (180, 58, 29):
        img.resize((s, s), Image.BOX).save(OUT / f"card-{theme}-{s}.png")
(OUT / "frames").mkdir(exist_ok=True)
strip = Image.new("RGB", (5 * 320, 320))
for i, t in enumerate((0.1, 0.25, 0.5, 0.75, 1.0)):
    g = float(bk.ease_out(t))
    img = paint(render(lambda x: target(x) * g), *THEMES["light"])
    img.save(OUT / "frames" / f"frame-{int(t * 100):03d}.png")
    strip.paste(img.resize((320, 320), Image.BOX), (i * 320, 0))
strip.save(OUT / "card-strip.png")
wb = BARS[0]
print(f"✅ round10 seed {SEED}: ink {cov.mean():.1%} of the tile; optical centre ({optical[0]:.0f}, {optical[1]:.0f}) "
      f"-> shift CX by {512 - optical[0]:+.0f}; word-bar region: --region {int(X0 - 10)},{int(wb[2] - BH / 2 - 14)},"
      f"{int(wb[0] + wb[1] + 4)},{int(wb[2] + BH / 2 + 14)}")
