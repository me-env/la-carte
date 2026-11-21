#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = ["numpy==2.3.4", "pillow==12.0.0", "scipy==1.16.3"]
# ///
"""Round 7: one flashcard, scattered dots (left) settling into solid (right). uv run render.py
Method = scripts/design-review.py `synthetic_ramp` (the reference that passes every measured check):
1. Hex lattice, pitch A = 12, over the ramp, and Bridson Poisson-disc points of the same density.
2. Matched one-to-one (linear_sum_assignment); each dot sits at lerp(random, lattice, w(x)), w easing out
   (1 − (1 − t)²) so order rises evenly.
3. One coverage c(x) = 0.04 + 0.96·smoothstep, zero slope into the solid. c < 0.5: a dot of radius
   A·√(c·√3/2π); above 0.35 each dot morphs into a rounded hexagon (apothem + corner radius, exact Minkowski
   area matched to c) whose extent grows to A/2 while its rounding shrinks to 0: the marks become the lattice's
   own cells and close into solid. No dot → hole flip, so no seam. Gaps under 1 px close outright (no hairline mesh); dots < r 1.6 are drawn at 1.6 with probability (r/1.6)²
   (no specks); marks crossing the card outline shrink to fit, only fully closed cells clip to it.
   The closing threshold varies gently along y (one sine), so the mesh ends on a soft wave, not a straight wall.
   Small sizes are box-downsampled (no Lanczos ringing). (render_flip.py = the old ±6 px flip, kept as
   the tool's must-FAIL test case.)
Silhouette: card 552 × 420 = 46p × 35p, all four corners r 36 = 3p (p = 12, the lattice pitch); the solid starts at
80% of the width, so the dissolve is the subject (not half halftone, half slab).
Card x 210–770 (centre 490, a third toward the ink centroid), y 302–722.
Animation t (0 → 1): every frame is the final construction shifted right by (1 − t)·W, so at t = 0 the whole card
is scattered noise, at t = 1 it is the mark, and every in-between frame is a valid crop of the same construction. Reduce Motion: the end frame, 0.3 s crossfade.
"""
import math, os, subprocess
import numpy as np
from PIL import Image, ImageDraw
from scipy.optimize import linear_sum_assignment
from scipy.spatial import cKDTree

HERE = os.path.dirname(os.path.abspath(__file__))
TILE, S = 1024, 4
THEMES = {'dark': ((0x15, 0x15, 0x14), (0xF2, 0xF2, 0xF0)), 'light': ((0xF9, 0xFA, 0xF5), (0x1C, 0x1C, 0x1C)),
          'forest': ((0x0E, 0x19, 0x13), (0xEE, 0xF2, 0xEC))}
W, H, R, CX, CY = 552, 420, 36, 490, 512            # 46p × 35p, corners 3p (p = 12)
XL, XR = CX - W / 2, CX + W / 2
SOLID = 0.80
A = 12.0
sstep = lambda t: (lambda u: u * u * (3 - 2 * u))(np.clip(t, 0, 1))

def lattice_and_matching(seed=7):
    rng = np.random.default_rng(seed)
    dx = A * math.sqrt(3) / 2
    lat = np.array([(x, y) for i, x in enumerate(np.arange(XR, XL - 2 * A, -dx))
                    for y in np.arange(CY - H / 2 - A + (A / 2) * (i % 2), CY + H / 2 + A, A)])
    box = (XL - A, XR + A, CY - H / 2 - A, CY + H / 2 + A)
    rmin = 0.8 * A; cell = rmin / math.sqrt(2)
    pts, active, grid = [], [], {}
    def add(p):
        pts.append(p); active.append(p); grid[(int(p[0] // cell), int(p[1] // cell))] = p
    add((rng.uniform(box[0], box[1]), rng.uniform(box[2], box[3])))
    while active:
        k = rng.integers(len(active)); base = active[k]
        for _ in range(30):
            a, d = rng.uniform(0, 2 * math.pi), rng.uniform(rmin, 2 * rmin)
            p = (base[0] + d * math.cos(a), base[1] + d * math.sin(a))
            if not (box[0] <= p[0] < box[1] and box[2] <= p[1] < box[3]): continue
            gx, gy = int(p[0] // cell), int(p[1] // cell)
            if all(math.dist(p, q) >= rmin for i in range(gx - 2, gx + 3) for j in range(gy - 2, gy + 3)
                   if (q := grid.get((i, j)))):
                add(p); break
        else:
            active.pop(k)
    rnd = np.array(pts)
    li, ri = linear_sum_assignment(np.linalg.norm(lat[:, None] - rnd[None], axis=2))
    start = lat.copy()                             # every lattice cell is kept; unmatched ones start in place
    start[li] = rnd[ri]
    return lat, start

LAT, RND = lattice_and_matching()


SPECK_RNG = np.random.default_rng(13).uniform(size=len(LAT))
CLOSE_AT = 1.0                                     # px: gaps under this close outright
HEX_AREA = math.sqrt(3) / 2 * A * A                # Voronoi cell of the lattice
C1 = 0.35                                          # below: round dots; above: dots become hexagons

def _mark_cov(kk, rho):
    return (2 * math.sqrt(3) * kk * kk + 4 * math.sqrt(3) * kk * rho + math.pi * rho * rho) / HEX_AREA

_E1 = A * math.sqrt(C1 * math.sqrt(3) / (2 * math.pi))
_ES = np.linspace(_E1, A / 2, 600)
_RHO = _E1 * (A / 2 - _ES) / (A / 2 - _E1)
_COV = _mark_cov(_ES - _RHO, _RHO)                 # rises C1 → 1

def morph(cov):
    cov = np.clip(cov, 0, 1)
    dot_r = A * np.sqrt(cov * math.sqrt(3) / (2 * math.pi))
    e = np.interp(cov, _COV, _ES)
    rho = np.interp(cov, _COV, _RHO)
    return np.where(cov < C1, 0.0, e - rho), np.where(cov < C1, dot_r, rho)

def sd_hex(q, apothem):
    """Signed distance to a flat-top regular hexagon (iq), apothem per point; q relative to its centre."""
    kx, ky, kz = -0.866025404, 0.5, 0.577350269
    px, py = np.abs(q[:, 0]), np.abs(q[:, 1])
    d = np.minimum(kx * px + ky * py, 0)
    px, py = px - 2 * d * kx, py - 2 * d * ky
    px = px - np.clip(px, -kz * apothem, kz * apothem); py = py - apothem
    return np.hypot(px, py) * np.sign(py)

def coverage_map(t):
    # Every frame is the final construction shifted right by (1 − t)·W: at t = 0 the whole card is in the noise
    # state, at t = 1 it is the mark. So each frame is a crop of a construction that passes design-review.
    shift = (1 - t) * W
    xs_solid = XL + SOLID * W + shift
    c = lambda x: 0.04 + 0.96 * sstep((x - shift - XL) / (SOLID * W))
    gx = np.linspace(XL, XL + SOLID * W, 2000)
    xh = gx[np.argmax(0.04 + 0.96 * sstep((gx - XL) / (SOLID * W)) >= 0.55)] + shift  # dots reach their site at c = 0.55
    w = lambda x: 1 - (1 - np.clip((x - shift - XL) / max(xh - shift - XL, 1), 0, 1)) ** 1.5
    pos = LAT + (RND - LAT) * (1 - w(LAT[:, 0]))[:, None]
    ys, xs = (np.mgrid[0:TILE * S, 0:TILE * S] + 0.5) / S
    qx, qy = np.abs(xs - CX) - (W / 2 - R), np.abs(ys - CY) - (H / 2 - R)
    sd = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - R
    ink = (sd <= 0) & (xs >= xs_solid)
    ramp = (sd <= 0) & (xs < xs_solid)
    p = np.column_stack([xs[ramp], ys[ramp]])
    # (b) No polarity flip: each mark is a rounded hexagon (a flat-top hexagon of apothem kk, Minkowski-summed
    # with a disc of radius rho). Below C1 it is a plain dot (kk = 0); above, its extent e = kk + rho grows to A/2
    # while rho shrinks to 0, so the marks become the lattice's own cells and close into solid with no seam.
    cov = c(LAT[:, 0])
    kk, rho = morph(cov)
    # Gaps under 1 px close outright, so the mesh goes from about 1 px to 0 in a column or two instead of fading
    # through ~100 px of grey hairlines. (Per-cell random thresholds left floating hexagon rings.)
    yy = LAT[:, 1]
    wave = 0.35 * np.sin(2 * math.pi * yy / 260 + 0.7)     # one gentle wave along y (≈ ±1 pitch of front)
    closed = ((A - 2 * (kk + rho)) < CLOSE_AT + wave) & (cov >= 0.65)  # closing zone only
    kk, rho = np.where(closed, A / 2, kk), np.where(closed, 0.0, rho)
    # Dots under r 1.6 would render as specks: draw them at 1.6 with probability (r / 1.6)² (same coverage).
    tiny = (kk == 0) & (rho < 1.6)
    keep_tiny = SPECK_RNG < (rho / 1.6) ** 2
    rho = np.where(tiny, np.where(keep_tiny, 1.6, 0.0), rho)
    # Marks crossing the card outline before the closing zone shrink to fit inside (no notches, no half-shapes).
    qx, qy = np.abs(pos[:, 0] - CX) - (W / 2 - R), np.abs(pos[:, 1] - CY) - (H / 2 - R)
    room = -(np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - R)
    ext = kk + rho
    fit = np.where(~closed & (ext > room), np.clip(room, 0, None) / np.maximum(ext, 1e-9), 1.0)
    kk, rho = kk * fit, rho * fit
    small = ~closed & (kk + rho < 1.6)
    kk, rho = np.where(small & (fit < 1), 0.0, kk), np.where(small & (fit < 1), 0.0, rho)
    cl = cKDTree(LAT).query(p)[1]
    pc = pos[cl]
    e = kk[cl] + rho[cl]
    qx, qy = np.abs(pc[:, 0] - CX) - (W / 2 - R), np.abs(pc[:, 1] - CY) - (H / 2 - R)
    # Round dots stay whole; hexagon-phase marks clip to the card outline (no notches along the top/bottom edge).
    whole = (np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - R <= -e + 0.01) | closed[cl]
    ink[ramp] = (sd_hex(p - pc, kk[cl]) - rho[cl] <= 0) & whole & (rho[cl] + kk[cl] > 0)
    return ink.reshape(TILE, S, TILE, S).mean(axis=(1, 3))[..., None]

def paint(cov, theme):
    bg, ink = (np.array(v, dtype=float) for v in THEMES[theme])
    return Image.fromarray((bg * (1 - cov) + ink * cov).astype(np.uint8))

final = coverage_map(1.0)
for theme in THEMES:
    img = paint(final, theme)
    img.save(os.path.join(HERE, f'card-{theme}-1024.png'))
    for size in (180, 58, 29):
        img.resize((size, size), Image.BOX).save(os.path.join(HERE, f'card-{theme}-{size}.png'))
paint(final, 'dark').resize((512, 512), Image.BOX).save(os.path.join(HERE, 'card-reduce-motion.png'))
strip = Image.new('RGB', (4 * 320, 320))
for i, t in enumerate((0.25, 0.5, 0.75, 1.0)):
    frame = paint(coverage_map(t) if t < 1 else final, 'light')
    if t < 1: frame.save(os.path.join(HERE, f'card-frame-{int(t * 100):03d}.png'))   # design-review the frames too
    strip.paste(paint(coverage_map(t) if t < 1 else final, 'dark').resize((320, 320), Image.BOX), (i * 320, 0))
strip.save(os.path.join(HERE, 'card-strip.png'))
print('✅ round7 rendered')
