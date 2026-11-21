#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = ["numpy==2.3.4", "pillow==12.0.0", "scipy==1.16.3"]
# ///
"""Round 8: one card, scattered dots (left) settling into solid (right). Built on scripts/brandkit.py.
Construction (px at 1024), p = 12 = lattice nearest-neighbour pitch, columns every p·√3/2:
- Card: W = 53 columns (550.7), H = 35p (420), corner radius 3p (36); centred at x 456 (optical centre on 512), y 512.
- Coverage c(x) = 0.04 + 0.96·smoothstep over the left 80% of the card; the right 20% is closed (c = 1).
- Positions: blue noise matched to the lattice (squared distance), easing onto the sites by c = 0.55.
- c < 0.65: one mark per cell from bk.mark (dot, then rounded hexagon); marks that would cross the card outline
  shrink to fit inside it (no half-shapes, no notches).
- c ≥ 0.65 (closing zone): each cell is either an open mark (coverage c0 sliding 0.65 → 0.5, so the gap around it
  widens instead of thinning) or a fully closed hexagon (its own Voronoi cell; 0.5 px oversize where c ≥ 0.9, so
  the solid has no antialiasing seams). The closed fraction (c − c0)/(1 − c0) keeps the average coverage on c. Walls never thin into
  hairlines, and there is no straight front: the card fills in like settling grain.
Animation t ∈ [0, 1]: frame t is the same construction with coverage c·g(t), g = ease_out, marks at their final
positions. Each frame obeys every rule (closing only where its own coverage ≥ 0.65), so it passes the same checks. Reduce Motion: final frame + 0.3 s
crossfade.
"""
import math, sys
from pathlib import Path
sys.path.insert(0, str(next(p for p in Path(__file__).resolve().parents if (p / "scripts/brandkit.py").exists()) / "scripts"))
import brandkit as bk
import numpy as np
SQ3 = math.sqrt(3)
from PIL import Image

HERE = Path(__file__).resolve().parent
P = 12.0
DX = P * math.sqrt(3) / 2
W, H, R = 53 * DX, 35 * P, 3 * P
CX, CY = 456.0, 512.0                                # optical centre: mean of ink box and centroid on 512
XL, XR, TOP, BOT = CX - W / 2, CX + W / 2, CY - H / 2, CY + H / 2
XS = XL + 0.80 * W                                   # coverage reaches 1 here
C_CLOSE = 0.65
THEMES = {"dark": ("#151514", "#F2F2F0"), "light": ("#F9FAF5", "#1C1C1C"), "forest": ("#0E1913", "#EEF2EC")}

cov_at = lambda x: np.where(x >= XS, 1.0, 0.04 + 0.96 * bk.smoothstep((x - XL) / (XS - XL)))
lat = bk.hex_lattice(XL, XR, TOP, BOT, P)
c = cov_at(lat[:, 0])
gx = np.linspace(XL, XS, 4000)
xh = gx[np.argmax(cov_at(gx) >= 0.55)]
moving = lat[:, 0] < xh + P
noise = bk.blue_noise((XL - 3 * P, xh + 3 * P, TOP - 3 * P, BOT + 3 * P), 0.75 * P, seed=8)
pos = lat.copy()
w = (1 - (1 - np.clip((lat[moving, 0] - XL) / (xh - XL), 0, 1)) ** 1.5)[:, None]   # gentler than ease_out: |psi6| step
pos[moving] = bk.match(lat[moving], noise) * (1 - w) + lat[moving] * w

def sd_card(x, y):
    qx, qy = np.abs(x - CX) - (W / 2 - R), np.abs(y - CY) - (H / 2 - R)
    return np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - R

U_CLOSE = bk.rng(21).uniform(size=len(lat))       # per-cell order in which closing-zone cells fill
U_SPECK = bk.rng(22).uniform(size=len(lat))        # per-cell keep/drop for dots below r 1.6
ROOM = -sd_card(pos[:, 0], pos[:, 1])

def paths(cs):
    """Marks for coverage cs per cell (the final mark: cs = c; animation frame t: cs = c · g(t))."""
    closing = cs >= C_CLOSE
    # Open cells in the closing zone shrink smoothly from 0.65 to 0.5 (thicker rings, never hairlines); the closed
    # fraction (cs − c0)/(1 − c0) keeps the average coverage exact.
    c0 = C_CLOSE - 0.15 * np.clip((cs - C_CLOSE) / (1 - C_CLOSE), 0, 1)
    closed = closing & (U_CLOSE < (cs - c0) / (1 - c0))
    k, rho = bk.mark(np.where(closing, c0, cs), P)
    fit = np.where(~closed & (k + rho > ROOM), np.clip(ROOM, 0, None) / np.maximum(k + rho, 1e-9), 1.0)
    k, rho = k * fit, rho * fit
    tiny = ~closed & (k == 0) & (rho < 1.6)        # specks: drawn at r 1.6 with probability (r / 1.6)²
    rho = np.where(tiny, np.where(U_SPECK < (rho / 1.6) ** 2, 1.6, 0.0), rho)
    out = []
    for i in range(len(lat)):
        x, y = pos[i]
        if closed[i]:
            # Closed cells clip to the card only where the card is fully solid; elsewhere one crossing the outline
            # shrinks to fit (no half-hexagons at the edge mid-animation).
            a = (P / 2 + (0.5 if cs[i] >= 0.9 else 0)) if cs[i] >= 0.999 or ROOM[i] >= P / SQ3 else max(ROOM[i] * SQ3 / 2, 0)  # +0.5 where solid: no AA seams
            if a > 0.8:
                out.append(bk.mark_path(x, y, a, 0))
        elif k[i] + rho[i] > 0:
            out.append(bk.mark_path(x, y, k[i], rho[i]))
    return out, int(closed.sum())

clip = bk.rounded_rect(XL, TOP, W, H, R)
for theme, (bg, fg) in THEMES.items():
    s = bk.svg(HERE / f"card-{theme}.svg", 1024, bg, fg, paths=paths(c)[0], clip=clip)
    bk.png(s)
frames = []
for t in (0.25, 0.5, 0.75):
    s = bk.svg(HERE / f"card-frame-{int(t * 100):03d}.svg", 1024, *THEMES["light"], paths=paths(c * float(bk.ease_out(t)))[0], clip=clip)
    frames += bk.png(s, sizes=(1024,))
strip = Image.new("RGB", (4 * 320, 320))
for i, t in enumerate((0.25, 0.5, 0.75, 1.0)):
    src = HERE / (f"card-frame-{int(t * 100):03d}-1024.png" if t < 1 else "card-light-1024.png")
    strip.paste(Image.open(src).convert("RGB").resize((320, 320), Image.BOX), (i * 320, 0))
strip.save(HERE / "card-strip.png")
print(f"✅ round8: {paths(c)[1]} closed cells, card x {XL:.1f}–{XR:.1f}, solid from x {XS:.1f}")
