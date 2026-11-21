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
   A·√(c·√3/2π) per lattice cell; past 50%: solid with a hole of radius A·√((1 − c)·√3/2π) (AM halftone).
   - The dot → hole flip is dithered per cell (±18 px around c = 0.5), so there is no straight front.
   - Hole-mode ink keeps the same clearance from a neighbouring dot as dots keep from each other (A − 2·rd).
   - Holes stop shrinking at r 1.5 and then close cell by cell (random order), so the last stretch rises
     smoothly without sub-pixel grey specks.
   (Tried: dots growing until they merge. No flip, but it fails design-review's no-touch rule.)
Silhouette (against a "toggle switch" reading): 4:3 index card 560 × 420, corner radius 36 (not a pill); pitch 12; the
solid starts at 55% of the width, so the small icon is mostly card, not a grey track with a white knob.
Card x 210–770 (centre 490, a third toward the ink centroid), y 302–722.
Animation t (0 → 1): the solid edge sweeps in from the right edge and the order weight grows with t, so at t = 0
the whole card is scattered noise and at t = 1 it is the mark. Reduce Motion: the end frame, 0.3 s crossfade.
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
W, H, R, CX, CY = 560, 420, 36, 490, 512
XL, XR = CX - W / 2, CX + W / 2
SOLID = 0.55
A = 12.0
FLIP_JITTER = 6.0                                 # ± px: each cell flips dot → hole at its own x
TAIL_R = 1.5                                       # holes never shrink below this; they close cell by cell
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
    return lat[li], rnd[ri]

LAT, RND = lattice_and_matching()
_jr = np.random.default_rng(11)
J_FLIP = _jr.uniform(-1, 1, len(LAT))              # per-cell flip offset (× FLIP_JITTER)
J_CLOSE = _jr.uniform(0, 1, len(LAT))              # per-cell hole-closing order

def coverage_map(t):
    xs_solid = XR - (XR - (XL + SOLID * W)) * t          # solid edge sweeps in from the right
    c = lambda x: 0.04 + 0.96 * sstep((x - XL) / max(xs_solid - XL, 1))
    xh = XL + (xs_solid - XL) / 2
    w = lambda x: (1 - (1 - np.clip((x - XL) / max(xh - XL, 1), 0, 1)) ** 2) * t
    pos = LAT + (RND - LAT) * (1 - w(LAT[:, 0]))[:, None]
    ys, xs = (np.mgrid[0:TILE * S, 0:TILE * S] + 0.5) / S
    qx, qy = np.abs(xs - CX) - (W / 2 - R), np.abs(ys - CY) - (H / 2 - R)
    sd = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - R
    ink = (sd <= 0) & (xs >= xs_solid)
    ramp = (sd <= 0) & (xs < xs_solid)
    p = np.column_stack([xs[ramp], ys[ramp]])
    k = 0.2757                                     # √3 / 2π: dot radius = A·√(c·k), hole radius = A·√((1 − c)·k)
    cov = c(LAT[:, 0])
    gx = np.linspace(XL, XR, 4000)
    xf = gx[np.argmax(c(gx) >= 0.5)] if (c(gx) >= 0.5).any() else 1e9  # x where c = 0.5 (c rises with x)
    hole_mode = LAT[:, 0] > xf + FLIP_JITTER * J_FLIP                    # dithered flip: no straight front
    rd = A * np.sqrt(cov * k)
    rh = A * np.sqrt((1 - cov) * k)
    # Tail: once a hole would be smaller than TAIL_R, it closes at a per-cell moment, so coverage keeps rising
    # smoothly (fraction of open holes falls) instead of sub-pixel holes rendering as grey dust.
    tail_cov = 1 - (TAIL_R / A) ** 2 / k
    frac_open = np.clip((1 - cov) / (1 - tail_cov), 0, 1)               # 1 at tail start → 0 at solid
    open_ = (cov < tail_cov) | (J_CLOSE < frac_open)
    rh = np.where(cov < tail_cov, rh, TAIL_R) * open_
    cl = cKDTree(LAT).query(p)[1]
    pc = pos[cl]
    qx, qy = np.abs(pc[:, 0] - CX) - (W / 2 - R), np.abs(pc[:, 1] - CY) - (H / 2 - R)
    whole = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - R <= -rd[cl]
    dot = (np.linalg.norm(p - pc, axis=1) < rd[cl]) & whole
    hole = np.linalg.norm(p - LAT[cl], axis=1) < rh[cl]
    # Hole-mode ink keeps the same clearance from a neighbouring dot as dots keep from each other (A − 2·rd).
    dots_i = np.nonzero(~hole_mode)[0]
    d, j = cKDTree(pos[dots_i]).query(p, k=3)
    clear = (d >= (A - rd[dots_i][j])).all(axis=1)
    ink[ramp] = np.where(hole_mode[cl], ~hole & clear, dot)
    return ink.reshape(TILE, S, TILE, S).mean(axis=(1, 3))[..., None]

def paint(cov, theme):
    bg, ink = (np.array(v, dtype=float) for v in THEMES[theme])
    return Image.fromarray((bg * (1 - cov) + ink * cov).astype(np.uint8))

final = coverage_map(1.0)
for theme in THEMES:
    img = paint(final, theme)
    img.save(os.path.join(HERE, f'flip-{theme}-1024.png'))
    for size in (180, 58, 29):
        img.resize((size, size), Image.LANCZOS).save(os.path.join(HERE, f'flip-{theme}-{size}.png'))
paint(final, 'dark').resize((512, 512), Image.LANCZOS).save(os.path.join(HERE, 'flip-reduce-motion.png'))
strip = Image.new('RGB', (3 * 320, 320))
for i, t in enumerate((0.0, 0.5, 1.0)):
    strip.paste(paint(coverage_map(t) if t < 1 else final, 'dark').resize((320, 320), Image.LANCZOS), (i * 320, 0))
strip.save(os.path.join(HERE, 'flip-strip.png'))
print('✅ round7 rendered')
