#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = ["numpy==2.3.4", "pillow==12.0.0", "scipy==1.16.3"]
# ///
"""Round 9 (pass 2): a stack of two cards; the front one is lost data points (left) settling into solid (right),
on a stochastic (blue-noise) screen. render_r9a.py = pass-1 version.
Construction (px at 1024):
- Front card 620 × 440, corner radius 44; a second card behind it, offset (+44, −44), same size, solid, visible only
  as an L-shaped band, with a GAP = 16 px paper gap (≈ 1 px at 58 px) around the front card: the stack cue.
- Coverage c(x) = 0.03 + 0.97·smoothstep over the left 45% of the front card; ≈ 55% is solid.
- Two progressive blue-noise sets (brandkit.progressive_blue_noise, ≥ D_MIN = 2.5·R0 apart, R0 = 3.2 px):
  A for ink dots, B for paper holes. Ink = (within R(x) of an A point) OR (farther than r_h(x) from every B point).
  - Dot side: density of A follows c (radius R0), then the dots grow (R up to D_MIN/2.5 before merging).
  - Hole side: r_h starts large (no effect) and shrinks to 0, so the paper left between merged dots becomes round
    holes on B that shrink steadily into the solid: the dot side turned inside out, one construction, no switch.
  - Each B point's r_h uses its own x jittered by ±1.5·D_MIN, so the last holes end at a different x per row
    (no ruled front).
  - From coverage 0.5, a morphological closing of radius WALL/2 (2.2 px) fills any thinner gap or hole: no hairlines.
- Below coverage 0.4, dots crossing the card outline are dropped, never clipped.
- R and r_h are calibrated (6 passes) so the column coverage follows c(x). The tile position puts the optical centre
  (mean of ink bbox centre and ink centroid) on the tile centre.
Animation t: the same construction at coverage c·g(t), g = ease_out (sparse full-ink dots first); the back card
fades in over t 0.6 → 1. Reduce Motion: final frame, 0.3 s crossfade.
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
W, H, RC = 620.0, 440.0, 44.0
OFF, GAP = 44.0, 16.0
R0, WALL, SS = 3.2, 2.2, 4
D_MIN = 2.5 * R0
SEED = int(os.environ.get("SEED", "36"))           # seeds 32–37 swept; 36 passes stills + every frame
THEMES = {"dark": ("#151514", "#F2F2F0"), "light": ("#F9FAF5", "#1C1C1C"), "forest": ("#0E1913", "#EEF2EC")}
CX = float(os.environ.get("CX", "464")); CY = float(os.environ.get("CY", "533"))   # front-card centre (optical fit)
XL, XR, TOP, BOT = CX - W / 2, CX + W / 2, CY - H / 2, CY + H / 2
XS = XL + 0.45 * W
target = lambda x: np.where(x >= XS, 1.0, 0.03 + 0.97 * bk.smoothstep((x - XL) / (XS - XL)))

RECT = (XL - 20, XR + 20, TOP - 20, BOT + 20)        # whole card: mid-animation frames have holes everywhere
A = bk.progressive_blue_noise(100000, RECT, D_MIN, SEED)
B = bk.progressive_blue_noise(100000, RECT, D_MIN, SEED + 1000)
RANK = np.arange(len(A)) / len(A)
RHO_MAX = len(A) / ((RECT[1] - RECT[0]) * (RECT[3] - RECT[2]))
C_D = RHO_MAX * math.pi * R0 ** 2
JIT = bk.rng(SEED + 7).uniform(-1.5, 1.5, len(B)) * D_MIN
RH0 = 0.9 * D_MIN                                    # hole radius where holes start to matter


def sd_rect(x, y, cx, cy, w=W, h=H, r=RC):
    qx, qy = np.abs(x - cx) - (w / 2 - r), np.abs(y - cy) - (h / 2 - r)
    return np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - r


def render(cov_fn, sdot, shole, ss=SS, back=1.0):
    """Ink mask at 1024·ss. sdot / shole: calibration factors (functions of x) for R and r_h."""
    c = cov_fn(A[:, 0])
    show = RANK < np.minimum(c / C_D, 1.0)
    r = np.where(c <= C_D, R0, R0 * np.sqrt(c / C_D) * sdot(A[:, 0]))
    r = np.where(c < 0.36, np.minimum(r, D_MIN / 2.5), r)
    show &= (sd_rect(A[:, 0], A[:, 1], CX, CY) <= -r) | (c >= 0.4)
    cb = cov_fn(np.clip(B[:, 0] + JIT, XL, None))
    rh = np.where(cb < 0.5, 1e9, RH0 * np.clip((1 - cb) / 0.5, 0, 1) * shole(B[:, 0]))
    ys, xs = (np.mgrid[0:1024 * ss, 0:1024 * ss] + 0.5) / ss
    inside = sd_rect(xs, ys, CX, CY) <= 0
    p = np.column_stack([xs[inside], ys[inside]])
    ink_in = np.zeros(len(p), bool)
    if show.any():
        d, j = cKDTree(A[show]).query(p, k=4, distance_upper_bound=3 * D_MIN)
        rr = r[show]
        ink_in = (d < rr[np.where(np.isinf(d), 0, j)]).any(axis=1)
    db, jb = cKDTree(B).query(p, k=1)
    ink_in |= db > rh[jb]
    ink = np.zeros(xs.shape, bool)
    ink[inside] = ink_in
    rp = int(round(WALL / 2 * ss))
    st = np.hypot(*np.mgrid[-rp:rp + 1, -rp:rp + 1]) <= rp
    ink = np.where(cov_fn(xs) >= 0.5, ndimage.binary_closing(ink, structure=st), ink) & inside   # hole stage only
    # The card behind: solid, offset, visible outside the front card plus GAP.
    behind = (sd_rect(xs, ys, CX + OFF, CY - OFF) <= 0) & (sd_rect(xs, ys, CX, CY) > GAP)
    return ink, behind & (back > 0), back


def coverage_cols(ink, ss=SS):
    cov = ink.reshape(1024, ss, 1024, ss).mean(axis=(1, 3))
    return cov[int(TOP + 0.2 * H):int(BOT - 0.2 * H)].mean(axis=0)


xs_cal = np.linspace(XL, XR, 64)
sdot, shole = np.ones_like(xs_cal), np.ones_like(xs_cal)
for _ in range(6):
    fd, fh = (lambda a: (lambda x: np.interp(x, xs_cal, a)))(sdot), (lambda a: (lambda x: np.interp(x, xs_cal, a)))(shole)
    ink, _, _ = render(target, fd, fh, ss=2)
    cols = ndimage.uniform_filter1d(coverage_cols(ink, 2), 24)
    meas = np.interp(xs_cal, np.arange(1024) + 0.5, cols)
    want = target(xs_cal)
    ratio = np.clip(np.maximum(want, 1e-3) / np.maximum(meas, 1e-3), 0.85, 1.18)
    sdot = np.clip(sdot * np.where((want > C_D) & (want < 0.5), np.sqrt(ratio), 1.0), 0.8, 2.0)
    # more ink wanted -> smaller holes (paper fraction ∝ r_h²)
    paper_ratio = np.clip(np.maximum(1 - want, 1e-3) / np.maximum(1 - meas, 1e-3), 0.7, 1.3)
    shole = np.clip(shole * np.where(want >= 0.5, np.sqrt(paper_ratio), 1.0), 0.4, 2.5)
FD, FH = (lambda x: np.interp(x, xs_cal, sdot)), (lambda x: np.interp(x, xs_cal, shole))


def paint(ink, behind, back, bg, fg, ss=SS):
    h = lambda s: np.array([int(s[i:i + 2], 16) for i in (1, 3, 5)], float)
    cov = ink.reshape(1024, ss, 1024, ss).mean(axis=(1, 3))[..., None]
    covb = behind.reshape(1024, ss, 1024, ss).mean(axis=(1, 3))[..., None] * back
    total = np.clip(cov + covb, 0, 1)
    return Image.fromarray((h(bg) * (1 - total) + h(fg) * total).astype(np.uint8))


ink, behind, back = render(target, FD, FH)
cov = ink.reshape(1024, SS, 1024, SS).mean(axis=(1, 3)) + behind.reshape(1024, SS, 1024, SS).mean(axis=(1, 3))
ysx, xsx = np.nonzero(cov > 0.02)
bbox_c = ((xsx.min() + xsx.max()) / 2, (ysx.min() + ysx.max()) / 2)
cen = ((cov * np.arange(1024)[None]).sum() / cov.sum(), (cov * np.arange(1024)[:, None]).sum() / cov.sum())
optical = ((bbox_c[0] + cen[0]) / 2, (bbox_c[1] + cen[1]) / 2)
for theme, (bg, fg) in THEMES.items():
    img = paint(ink, behind, back, bg, fg)
    img.save(HERE / f"card-{theme}-1024.png")
    for s in (180, 58, 29):
        img.resize((s, s), Image.BOX).save(HERE / f"card-{theme}-{s}.png")
(HERE / "frames").mkdir(exist_ok=True)
strip = Image.new("RGB", (5 * 320, 320))
for i, t in enumerate((0.1, 0.25, 0.5, 0.75, 1.0)):
    g = float(bk.ease_out(t))
    fi, fb, _ = render(lambda x: target(x) * g, FD, FH)
    img = paint(fi, fb, float(bk.smoothstep((t - 0.6) / 0.4)), *THEMES["light"])
    img.save(HERE / "frames" / f"frame-{int(t * 100):03d}.png")
    strip.paste(img.resize((320, 320), Image.BOX), (i * 320, 0))
strip.save(HERE / "card-strip.png")
print(f"✅ round9 seed {SEED}: A {len(A)} / B {len(B)} pts; optical centre ({optical[0]:.0f}, {optical[1]:.0f}) "
      f"-> shift CX by {512 - optical[0]:+.0f}, CY by {512 - optical[1]:+.0f}")
