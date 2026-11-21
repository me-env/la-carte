#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = ["numpy==2.3.4", "pillow==12.0.0", "scipy==1.16.3"]
# ///
"""Round 8b: one card, scattered dots (left) settling into solid (right). scripts/brandkit.py, raster closing.
Construction (px at 1024): columns every 1024·3/180 = 17.07 px (exactly 3 px at the 180 px home-screen size, so the
lattice can't beat against the pixels), nearest-neighbour pitch p = 17.07·2/√3 = 19.71:
- Card: W = 39 columns (665.6), H = 25p (492.8), corner radius 2p; bbox centred at x 484, y 512.
- Coverage c(x) = 0.04 + 0.96·smoothstep over the left 80% of the card; the right 20% is solid (c = 1).
- Positions: blue noise matched to the lattice (squared distance), easing onto the sites by c = 0.55
  (1 − (1 − t)^1.5).
- Marks (bk.mark_shape, WALL = 2.3, 8× supersampled): dot → rounded hexagon until the paper walls are 2.3 px → the web keeps 2.3 px and
  retreats into the cell corners (Y-shapes, then shrinking holes) until solid. Each cell's retreat length is
  jittered ±15%, so the web breaks cell by cell over several columns and the corner specks vary in size. No wall thinner than 2.3 px, no
  hairlines, no front: coverage, shape and order are all continuous.
- Dots crossing the card outline shrink to fit inside it; dots below r 1.6 are drawn at 1.6 with probability
  (r/1.6)² (no specks, same coverage).
Animation t ∈ [0, 1]: for t ≥ 0.25, frame t is the same construction at coverage c·g(t), g = ease_out, marks at their
final positions, so every frame obeys the same rules. Before 0.25 the t = 0.25 frame fades in (opacity t/0.25):
speck-sized dots would scramble the order measure. Frames: frames/frame-*.png. Reduce Motion: final frame, 0.3 s
crossfade.
"""
import math, sys
from pathlib import Path
sys.path.insert(0, str(next(p for p in Path(__file__).resolve().parents if (p / "scripts/brandkit.py").exists()) / "scripts"))
import brandkit as bk
import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
bk.WALL = 2.3                                        # ≤ 2.33 so the web starts at coverage ≥ 0.65 (touching rule); > 2.2 for hairline margin
DX = 3 * 1024 / 180                                 # column pitch = exactly 3 px at 180 (no moiré on the home screen)
P = DX * 2 / math.sqrt(3)                          # 19.71: nearest-neighbour pitch
W, H, R = 39 * DX, 25 * P, 2 * P                   # 665.6 × 492.8: ≈ 1.2× round 8, on whole lattice units
CX, CY = 484.0, 512.0                              # bbox centre: half the centroid correction
XL, XR, TOP, BOT = CX - W / 2, CX + W / 2, CY - H / 2, CY + H / 2
XS = XL + 0.80 * W
THEMES = {"dark": ("#151514", "#F2F2F0"), "light": ("#F9FAF5", "#1C1C1C"), "forest": ("#0E1913", "#EEF2EC")}

cov_at = lambda x: np.where(x >= XS, 1.0, 0.04 + 0.96 * bk.smoothstep((x - XL) / (XS - XL)))
lat = bk.hex_lattice(XL, XR, TOP, BOT, P)
c = cov_at(lat[:, 0])
gx = np.linspace(XL, XS, 4000)
xh = gx[np.argmax(cov_at(gx) >= 0.55)]
moving = lat[:, 0] < xh + P
noise = bk.blue_noise((XL - 3 * P, xh + 3 * P, TOP - 3 * P, BOT + 3 * P), 0.75 * P, seed=8)
pos = lat.copy()
w = (1 - (1 - np.clip((lat[moving, 0] - XL) / (xh - XL), 0, 1)) ** 1.5)[:, None]
pos[moving] = bk.match(lat[moving], noise) * (1 - w) + lat[moving] * w
ROOM = -bk.card_sd(pos[:, 0], pos[:, 1], CX, CY, W, H, R)
U_SPECK = bk.rng(22).uniform(size=len(lat))
inside = lambda x, y: bk.card_sd(x, y, CX, CY, W, H, R) <= 0

U_WEB = bk.rng(23).uniform(-1, 1, size=len(lat))   # per-cell web-retreat jitter (±15%): breaks spread over columns

def shape(cs):
    k, rho, L = bk.mark_shape(cs, P)
    L = np.where(L >= 0, L * (1 + 0.15 * U_WEB), L)
    dots = L < 0
    fit = np.where(dots & (k + rho > ROOM), np.clip(ROOM, 0, None) / np.maximum(k + rho, 1e-9), 1.0)
    k, rho = k * fit, rho * fit
    tiny = dots & (k == 0) & (rho < 1.6)
    rho = np.where(tiny, np.where((U_SPECK < (rho / 1.6) ** 2) & (ROOM >= 1.6), 1.6, 0.0), rho)   # only if it fits
    return k, rho, L

for theme, (bg, fg) in THEMES.items():
    img = bk.raster(HERE / f"card-{theme}-1024.png", lat, pos, *shape(c), P, inside, bg, fg, ss=8)
    for s in (180, 58, 29):
        Image.open(img).resize((s, s), Image.BOX).save(HERE / f"card-{theme}-{s}.png")
(HERE / "frames").mkdir(exist_ok=True)
strip = Image.new("RGB", (5 * 320, 320))
def mix(bg, fg, a):
    h = lambda s: np.array([int(s[i:i + 2], 16) for i in (1, 3, 5)], dtype=float)
    return "#" + "".join(f"{int(round(v)):02X}" for v in h(bg) + (h(fg) - h(bg)) * a)

T0 = 0.25                                            # before this, the t = T0 construction fades in (opacity t / T0)
for i, t in enumerate((0.1, 0.25, 0.5, 0.75, 1.0)):
    bg, fg = THEMES["light"]
    g = float(bk.ease_out(max(t, T0)))
    f = bk.raster(HERE / "frames" / f"frame-{int(t * 100):03d}.png", lat, pos, *shape(c * g), P,
                  inside, bg, mix(bg, fg, min(1.0, t / T0)), ss=8)
    strip.paste(Image.open(f).resize((320, 320), Image.BOX), (i * 320, 0))
strip.save(HERE / "card-strip.png")
print(f"✅ round8b: card x {XL:.1f}–{XR:.1f}, solid from x {XS:.1f}, C2 = {bk.closing_c2(P):.3f}")
