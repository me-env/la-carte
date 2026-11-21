"""Round 6, pass 4: 'card', one card that is remembered from left to right. python3 -I render.py
Construction (px at 1024):
- One silhouette: rounded rect 500 × 320, radius 52 (index card, ≈ 3:2). No back cards.
- Left 45% (225 px ≥ 160) is grain; the rest is solid. Along that ramp, u = 0 (left edge) → 1 (joint):
  coverage rises continuously (acceptance u^1.2), dot radius rises continuously r = 3.5 + 5.5·u (7 px dots at the
  outer third, the 58 px legibility floor), min centre distance (r1 + r2)·(1 + 0.7·(1 − u)), so dots space out
  to the left and touch only at the joint. No thresholds, no gutter: the last dots merge into the solid edge.
- Every dot sits fully inside the silhouette. Still image = time, left → right: scattered → dense → solid.
- The ink is shifted so its area-weighted centroid is at (512, 512) ± 12.
Animation (1.2 s): grain converges from 1.35× about the centroid (one uniform scale keeps every gap), then the
solid part fades in from the joint rightward (a 0.4 s wipe). render.py checks no dot overlaps another in any 1/30 s
frame and nothing leaves the canvas. Reduce Motion: final frame, 0.3 s crossfade.
"""
import math, os, subprocess
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.join(HERE, '../../../../reference/vyst-app-icon-512.png')
THEMES = {'dark': ('#151514', '#F2F2F0'), 'light': ('#F9FAF5', '#1C1C1C'), 'forest': ('#0E1913', '#EEF2EC')}
W, H, R = 500, 320, 52
RAMP = 0.45

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

def sd(x, y, cx, cy):
    qx, qy = abs(x - cx) - (W / 2 - R), abs(y - cy) - (H / 2 - R)
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - R

def build(cx, cy):
    rnd, dots, tries = mulberry32(81), [], 0
    xl, xj = cx - W / 2, cx - W / 2 + RAMP * W
    while tries < 250000:
        tries += 1
        u = rnd()
        if rnd() > u ** 1.2: continue
        x = xl + u * (xj - xl); y = cy + (rnd() - 0.5) * H
        r = 3.5 + 5.5 * u
        if sd(x, y, cx, cy) > -r: continue
        f = 1 + 0.7 * (1 - u)
        ok = True
        for px, py, pr, pu in dots:
            if (x - px) ** 2 + (y - py) ** 2 < ((r + pr) * max(f, 1 + 0.7 * (1 - pu))) ** 2:
                ok = False; break
        if ok: dots.append((x, y, r, u))
    return dots, xj

def solid_area_centroid(cx, cy, xj):
    # Numerical: sample the solid part on a 4 px grid.
    ax = n = 0
    for x in range(int(xj), int(cx + W / 2) + 1, 4):
        for y in range(int(cy - H / 2), int(cy + H / 2) + 1, 4):
            if sd(x, y, cx, cy) <= 0: ax += x; n += 1
    return ax, n * 16, n

cx, cy = 512, 512
for _ in range(3):                                   # shift until the ink centroid sits on 512
    DOTS, XJ = build(cx, cy)
    ax, area, n = solid_area_centroid(cx, cy, XJ)
    sx = ax * 16 + sum(math.pi * r * r * x for x, y, r, u in DOTS)
    total = area + sum(math.pi * r * r for x, y, r, u in DOTS)
    centroid = sx / total
    if abs(centroid - 512) <= 4: break
    cx += 512 - centroid
CX, CY = cx, cy

def frame(t):
    s = 1 + 0.35 * (1 - smooth(t / 0.6))
    dots = [(512 + (x - 512) * s, 512 + (y - 512) * s, r, smooth(t / 0.25)) for x, y, r, u in DOTS]
    wipe = smooth((t - 0.6) / 0.4)                  # solid part revealed from the joint rightward
    return dots, wipe

def check():
    worst = 1e9
    for f in range(37):
        dots, _ = frame(f / 36)
        for x, y, r, o in dots:
            assert r <= x <= 1024 - r and r <= y <= 1024 - r
        for i, a in enumerate(dots):
            for b in dots[i + 1:]:
                if abs(a[0] - b[0]) > 20 or abs(a[1] - b[1]) > 20: continue
                d = math.dist(a[:2], b[:2]) - a[2] - b[2]
                worst = min(worst, d); assert d > -0.01, f'overlap f{f}'
    return worst

def svg(t, ink, ox=0, cid='c'):
    dots, wipe = frame(t)
    out = [f'<circle cx="{x + ox:.1f}" cy="{y:.1f}" r="{r:.2f}" fill="{ink}" fill-opacity="{o:.2f}"/>' for x, y, r, o in dots]
    if wipe > 0:
        x0, x1 = XJ, XJ + (CX + W / 2 - XJ) * wipe
        out.append(f'<clipPath id="{cid}"><rect x="{x0 + ox:.1f}" y="0" width="{x1 - x0:.1f}" height="1024"/></clipPath>'
                   f'<rect x="{CX - W / 2 + ox:.1f}" y="{CY - H / 2:.1f}" width="{W}" height="{H}" rx="{R}" fill="{ink}" clip-path="url(#{cid})"/>')
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
print(f'✅ pass4: dots {len(DOTS)}, solid ink {area / 1024**2:.1%}, total ink {total / 1024**2:.1%}, '
      f'centroid x {centroid:.1f}, card x {CX - W/2:.0f}–{CX + W/2:.0f}, min gap {check():.2f}px')
