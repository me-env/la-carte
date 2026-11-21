"""Round 6, pass 5 (fix-only, after critic pass 4): 'card'. python3 -I render.py
One flashcard: scattered dots on the left settle into solid on the right (what you study as noise becomes known).
Construction (px at 1024):
- Silhouette: rounded rect 620 × 400, radius 64; bbox x 180–800 (centre x 490, a third of the way from the
  geometric centre toward the ink centroid: the optical centre). y centred.
- Ramp = left 45% (279 px). u = 0 (left edge) → 1 (joint). Dot radius r = 1.5 + 3.5·u (3 → 10 px dots).
- Nothing touches: centre distance ≥ 1.25·(r1 + r2) everywhere; every dot ends ≥ 4 px before the solid edge and sits
  fully inside the silhouette.
- u 0.70 → 1 (x 375 → 450): hex columns every 7.5 px leftward from x 450 (4 px before the solid), vertical pitch 20 centred on
  y = 512, alternate columns offset by 10; diagonal neighbours 12.5 apart = 1.25·(2·5). Exactly 2 columns per 15 px.
- u 0 → 0.70: stratified 15 px bands, target coverage rising linearly from 0.06 to 0.34 (meets the hex zone).
- Trail: 3 dots drifting off the left edge (r 2.6 / 2.2 / 1.8, opacity .7 / .5 / .3): noise arriving.
Known limit: with gaps ≥ 0.25·(r1 + r2) and r ≤ 5, hex coverage tops out near 0.5, so the last band before the
solid cannot reach the 0.75 the critic asked for; the jump into solid stays about ×2.
Animation (1.2 s): grain converges from 1.2× about the tile centre (one uniform scale keeps every gap); the solid
wipes in from the joint rightward. render.py asserts no touching and nothing off-canvas every 1/30 s.
Reduce Motion: card-reduce-motion.png = the end state, shown with a 0.3 s crossfade.
"""
import math, os, subprocess
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.join(HERE, '../../../../reference/vyst-app-icon-512.png')
THEMES = {'dark': ('#151514', '#F2F2F0'), 'light': ('#F9FAF5', '#1C1C1C'), 'forest': ('#0E1913', '#EEF2EC')}
W, H, R = 620, 400, 64
CX, CY = 490, 512
XL, XJ = CX - W / 2, CX - W / 2 + 0.45 * W
HEX_U = 0.75
HEX_X0 = 375.0                                     # hex zone starts on a 15 px band boundary (u ≈ 0.70)
PY, DX = 20.0, 7.5                                 # hex zone: vertical pitch, column pitch (2 columns per 15 px band)

def mulberry32(seed):
    s = seed & 0xFFFFFFFF
    def rnd():
        nonlocal s
        s = (s + 0x6D2B79F5) & 0xFFFFFFFF
        t = s
        t = ((t ^ (t >> 15)) * (t | 1)) & 0xFFFFFFFF
        t ^= (t + (((t ^ (t >> 7)) * (t | 61)) & 0xFFFFFFFF)) & 0xFFFFFFFF
        return ((t ^ (t >> 14)) & 0xFFFFFFFF) / 4294967296
    return rnd

def smooth(t):
    t = min(max(t, 0), 1); return t * t * (3 - 2 * t)

def sd(x, y):
    qx, qy = abs(x - CX) - (W / 2 - R), abs(y - CY) - (H / 2 - R)
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - R

def radius(u):
    return 1.5 + 3.5 * u

def free(x, y, r, dots):
    if sd(x, y) > -r or x + r > XJ - 4: return False
    return all((x - px) ** 2 + (y - py) ** 2 >= (1.245 * (r + pr)) ** 2
               for px, py, pr, _ in dots if abs(x - px) < 30 and abs(y - py) < 30)

def build():
    dots, x, flip = [], XJ - 9, 0                        # = 450: band-aligned, 4 px before the solid
    while True:                                          # hex zone, from the joint leftward
        u = (x - XL) / (XJ - XL)
        if x < HEX_X0 - 0.01: break
        r = radius(u)
        y = CY + (PY / 2 if flip else 0)                 # rows centred on y = 512, one constant pitch
        while y - PY > CY - H / 2: y -= PY
        while y <= CY + H / 2:
            if free(x, y, r, dots): dots.append((x, y, r, u))
            y += PY
        x -= DX                                          # diagonal neighbours: √(7.5² + 10²) = 12.5 = 1.25·(2·5)
        flip ^= 1
    hex_left, rnd, xs = HEX_X0, mulberry32(91), XL
    while xs < hex_left:                                 # stratified random zone
        xe = min(xs + 15, hex_left)
        target = 0.06 + 0.28 * ((xs + xe) / 2 - XL) / (HEX_X0 - XL)
        area, tries = 0.0, 0
        while area / ((xe - xs) * H) < target and tries < 40000:
            tries += 1
            xx, yy = xs + rnd() * (xe - xs), CY + (rnd() - 0.5) * H
            uu = (xx - XL) / (XJ - XL); r = radius(uu)
            if free(xx, yy, r, dots):
                dots.append((xx, yy, r, uu)); area += math.pi * r * r
        xs = xe
    return dots

DOTS = build()
TRAIL = [(XL - 22, CY - 34, 2.6, 0.7), (XL - 48, CY + 21, 2.2, 0.5), (XL - 80, CY - 8, 1.8, 0.3)]

def frame(t):
    s = 1 + 0.2 * (1 - smooth(t / 0.6))
    fade = smooth(t / 0.25)
    pts = [(512 + (x - 512) * s, 512 + (y - 512) * s, r, fade) for x, y, r, u in DOTS]
    pts += [(512 + (x - 512) * s, 512 + (y - 512) * s, r, o * fade) for x, y, r, o in TRAIL]
    return pts, smooth((t - 0.6) / 0.4)

def check():
    worst = 1e9
    for f in range(37):
        pts, _ = frame(f / 36)
        for x, y, r, o in pts:
            assert r <= x <= 1024 - r and r <= y <= 1024 - r, f'off canvas f{f}'
        for i, a in enumerate(pts):
            for b in pts[i + 1:]:
                if abs(a[0] - b[0]) > 30 or abs(a[1] - b[1]) > 30: continue
                d = math.dist(a[:2], b[:2]) - a[2] - b[2]
                worst = min(worst, d); assert d > 0, f'touch f{f}'
    return worst

def svg(t, ink, ox=0, cid='c'):
    pts, wipe = frame(t)
    out = [f'<circle cx="{x + ox:.1f}" cy="{y:.1f}" r="{r:.2f}" fill="{ink}" fill-opacity="{o:.2f}"/>' for x, y, r, o in pts]
    if wipe > 0:
        w = (CX + W / 2 - XJ) * wipe
        out.append(f'<clipPath id="{cid}"><rect x="{XJ + ox:.1f}" y="0" width="{w:.1f}" height="1024"/></clipPath>'
                   f'<rect x="{XL + ox:.1f}" y="{CY - H / 2:.1f}" width="{W}" height="{H}" rx="{R}" fill="{ink}" clip-path="url(#{cid})"/>')
    return ''.join(out)

def write(path, body, bg, w=1024):
    with open(path, 'w') as f:
        f.write(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} 1024" width="{w}" height="1024">'
                f'<rect width="{w}" height="1024" fill="{bg}"/>{body}</svg>')

def png(src, w, h, out):
    subprocess.run(['rsvg-convert', '-w', str(w), '-h', str(h), src, '-o', os.path.join(HERE, out)], check=True)

for theme, (bg, ink) in THEMES.items():
    p = os.path.join(HERE, f'card-{theme}.svg'); write(p, svg(1, ink), bg)
    for size in (1024, 180, 58, 29):
        png(p, size, size, f'card-{theme}-{size}.png')
png(os.path.join(HERE, 'card-dark.svg'), 512, 512, 'card-reduce-motion.png')
bg, ink = THEMES['dark']
body = ''.join(f'<rect x="{i * 1024}" width="1024" height="1024" fill="{bg}"/>' + svg(t, ink, i * 1024, f'c{i}')
               for i, t in enumerate((0.15, 0.7, 1.0)))
st = os.path.join(HERE, 'card-strip.svg'); write(st, body, bg, 3072); png(st, 960, 320, 'card-strip.png')

def rounded(img, radius):
    mask = Image.new('L', img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.size[0] - 1, img.size[1] - 1), radius, fill=255)
    return img.convert('RGBA'), mask

sh = Image.new('RGB', (1400, 760), '#2A2C33'); d = ImageDraw.Draw(sh)
vy = Image.open(REF).convert('RGB')
cells = [('vyst', vy.resize((180, 180), Image.LANCZOS), vy.resize((58, 58), Image.LANCZOS), vy.resize((29, 29), Image.LANCZOS))] + \
        [(t, Image.open(os.path.join(HERE, f'card-{t}-180.png')), Image.open(os.path.join(HERE, f'card-{t}-58.png')),
          Image.open(os.path.join(HERE, f'card-{t}-29.png'))) for t in THEMES]
for i, (name, a, b, c) in enumerate(cells):
    x = 20 + i * 260
    im, m = rounded(a.convert('RGB'), 40); sh.paste(im, (x, 20), m)
    im, m = rounded(b.convert('RGB'), 13); sh.paste(im, (x + 40, 215), m)
    im, m = rounded(c.convert('RGB'), 7); sh.paste(im, (x + 120, 230), m)
    d.text((x, 285), name, fill='#E6E6E6')
sh.paste(Image.open(os.path.join(HERE, 'card-strip.png')).convert('RGB').resize((900, 300)), (20, 320))
for k, (wall, t) in enumerate((('#1E2230', 'dark'), ('#DADDE6', 'light'))):
    d.rectangle((940, 320 + k * 150, 1400, 460 + k * 150), fill=wall)
    for i, src in enumerate([vy, Image.open(os.path.join(HERE, f'card-{t}-1024.png'))]):
        im, m = rounded(src.convert('RGB').resize((120, 120), Image.LANCZOS), 27); sh.paste(im, (960 + i * 140, 330 + k * 150), m)
        im, m = rounded(src.convert('RGB').resize((58, 58), Image.LANCZOS), 13); sh.paste(im, (1250 + i * 70, 360 + k * 150), m)
sh.save(os.path.join(HERE, 'sheet.png'))

bands, x = [], XL
while x < XJ:
    width = min(15, XJ - x)
    bands.append(round(sum(math.pi * r * r for dx, dy, r, u in DOTS if x <= dx < x + 15) / (width * H), 2)); x += 15
print(f'✅ pass5: dots {len(DOTS)}, card x {XL:.0f}–{CX + W / 2:.0f}, closest dot to solid '
      f'{XJ - max(x + r for x, y, r, u in DOTS):.1f}px, min gap {check():.2f}px')
print('coverage per 15 px band:', bands)
