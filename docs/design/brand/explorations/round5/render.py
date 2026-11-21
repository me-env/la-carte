"""Round 5: lost data points (noise) resolving into structure, with time as the organising axis.
Run: python3 -I render.py (needs rsvg-convert + Pillow). Deterministic: mulberry32, one seed per variation.

Model shared by every variation: each point has a structured target (tx, ty), a size r, a resolution f (0 = still
lost in the noise, 1 = in place), a noise offset (nx, ny) and an `order` on the time axis (0 = first, 1 = last).
Final position = target + noise · (1 − f). Animation: pos(t) = target + noise · (1 − f · s), where s rises along
`order`, so structure forms in time order (noise → structure). That is also how LaCarteLogo would animate it (Canvas +
the same seeded points); Reduce Motion: crossfade to the final frame.

  v1-columns   vertical noise columns collapsing into one row of dots; column gaps widen like review intervals
  v2-calendar  noise resolving into a 7×5 dot grid (days × weeks), in reading order
  v3-curve     scattered points snapping onto a rising, flattening retention curve
  v4-clock     noise condensing into 12 clock dots, clockwise
  v5-point     fine grain → discrete dots → one solid point
  v6-ticks     noise resolving into vertical tick marks (stacks of dots) at widening intervals
  v7-hourglass grain falling from the top and settling into ordered rows at the bottom
"""
import math, os, subprocess
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.join(HERE, '../../../reference/vyst-app-icon-512.png')
DARK, LIGHT = ('#151514', '#F2F2F0'), ('#F9FAF5', '#1C1C1C')

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

def g(rnd):
    return math.sqrt(-2 * math.log(max(rnd(), 1e-9))) * math.cos(2 * math.pi * rnd())

def smooth(t):
    t = min(max(t, 0), 1); return t * t * (3 - 2 * t)

def P(tx, ty, r, f, nx, ny, order):
    return (tx, ty, r, f, nx, ny, order)

def widening(n, x0, x1, ratio=1.32):
    gaps = [ratio ** j for j in range(n - 1)]
    k = (x1 - x0) / sum(gaps)
    xs = [x0]
    for gp in gaps: xs.append(xs[-1] + gp * k)
    return xs

def grain(rnd, pts, tx, ty, order, n, sx, sy, small):
    """Texture only: grains stay where the noise put them (f = 0)."""
    for _ in range(n):
        r = (13 + rnd() * 3) if small else (1.8 + rnd() * 2.4)
        pts.append(P(tx, ty, r, 0, g(rnd) * sx, g(rnd) * sy, order))

def node(pts, x, y, r, order, rnd, amp=240):
    """Structure: always lands exactly on (x, y) (f = 1); starts scattered for the animation."""
    pts.append(P(x, y, r, 1, g(rnd) * amp, g(rnd) * amp, order))

def lerp(a, b, u):
    return a + (b - a) * u

def v1(rnd, small):
    # 7 columns; gaps grow ×1.32; node radius grows linearly 12 → 36 (small 22 → 44); grain per column falls
    # linearly 90 → 0 and its vertical spread ×0.75 per column. Baseline y = 512.
    pts, xs = [], widening(7, 170, 854)
    for j, x in enumerate(xs):
        o = j / 6
        grain(rnd, pts, x, 512, o, round(lerp(10 if small else 90, 0, o)), 14, 210 * 0.75 ** j, small)
        node(pts, x, 512, lerp(22, 44, o) if small else lerp(12, 36, o), o, rnd)
    return pts

def v2(rnd, small):
    # 7×5 grid, pitch 112 (small 5×4, pitch 150). Node radius grows linearly with reading order 8 → 30
    # (small 18 → 40); grain per cell falls linearly 30 → 0 with spread 44.
    pts = []
    cols, rows, step = (5, 4, 150) if small else (7, 5, 112)
    for r in range(rows):
        for c in range(cols):
            o = (r * cols + c) / (rows * cols - 1)
            x, y = 512 + (c - (cols - 1) / 2) * step, 512 + (r - (rows - 1) / 2) * step
            grain(rnd, pts, x, y, o, round(lerp(4 if small else 30, 0, o)), 44, 44, small)
            node(pts, x, y, lerp(18, 40, o) if small else lerp(8, 30, o), o, rnd)
    return pts

def curve_pts(n):
    # Retention curve y = 760 − 460·(1 − e^(−3.2u)), x = 160 + 704u; resampled at equal arc length.
    dense = [(160 + 704 * u, 760 - 460 * (1 - math.exp(-3.2 * u))) for u in (i / 2000 for i in range(2001))]
    acc = [0.0]
    for a, b in zip(dense, dense[1:]): acc.append(acc[-1] + math.dist(a, b))
    out, k = [], 0
    for i in range(n):
        target = acc[-1] * i / (n - 1)
        while acc[k] < target: k += 1
        out.append(dense[k])
    return out

def v3(rnd, small):
    # 15 nodes (small 8) at equal arc length on the curve; radius grows linearly 7 → 20 (small 20 → 34);
    # the arc pitch (~68, small ~145) is ≥ 1.6× the largest diameter, so nothing touches. Grain falls 40 → 0.
    pts = []
    n = 8 if small else 15
    for i, (x, y) in enumerate(curve_pts(n)):
        o = i / (n - 1)
        grain(rnd, pts, x, y, o, round(lerp(5 if small else 40, 0, o)), 40, 120 * (1 - o), small)
        node(pts, x, y, lerp(20, 34, o) if small else lerp(7, 20, o), o, rnd)
    return pts

def v4(rnd, small):
    # 12 nodes on a circle R = 300 (pitch 157), clockwise from 12 o'clock; radius grows linearly 10 → 30
    # (small 22 → 42); centre node r = 30 (small 44). Grain per node falls 60 → 0, spread 50.
    pts, R = [], 300
    for k in range(12):
        o = k / 11
        a = -math.pi / 2 + 2 * math.pi * k / 12
        x, y = 512 + R * math.cos(a), 512 + R * math.sin(a)
        grain(rnd, pts, x, y, o, round(lerp(6 if small else 60, 0, o)), 50, 50, small)
        node(pts, x, y, lerp(22, 42, o) if small else lerp(10, 30, o), o, rnd)
    node(pts, 512, 512, 44 if small else 30, 0, rnd, 0)
    return pts

def v5(rnd, small):
    # Grain cloud (left, its vertical spread narrowing linearly to 0 at x = 470), then dots on y = 512 whose
    # radius grows ×1.4 each step with a constant 22 px edge-to-edge gap, ending in one large point.
    pts = []
    for _ in range(16 if small else 1500):
        u = rnd()
        x = lerp(150, 470, u ** 0.7)
        spread = 230 * (1 - (x - 150) / 320)
        pts.append(P(x, 512, (13 + rnd() * 3) if small else (1.8 + rnd() * 2.4), 0, 0, g(rnd) * spread, (x - 150) / 720))
    radii = [26, 36.4, 51, 71.4] if small else [10, 14, 19.6, 27.4, 38.4, 53.8]
    gap = 34 if small else 22
    x = (530 if small else 490) + radii[0]
    for i, r in enumerate(radii):
        node(pts, x, 512, r, 0.5 + 0.5 * i / (len(radii) - 1), rnd)
        if i + 1 < len(radii): x += r + gap + radii[i + 1]
    return pts

def v6(rnd, small):
    # 8 ticks (small 5) at gaps growing ×1.32; each tick = 7 nodes at a vertical pitch of 44 (small 64);
    # node radius grows linearly 6 → 15 (small 15 → 24), always < pitch/2 − 7, so dots never touch.
    pts, n = [], (5 if small else 8)
    xs = widening(n, 180, 850)
    pitch = 64 if small else 44
    for j, x in enumerate(xs):
        o = j / (n - 1)
        for k in range(7):
            y = 512 + (k - 3) * pitch
            grain(rnd, pts, x, y, o, round(lerp(1 if small else 8, 0, o)), 22, 26, small)
            node(pts, x, y, lerp(15, 24, o) if small else lerp(6, 15, o), o, rnd)
    return pts

def v7(rnd, small):
    # 3 rows × 9 nodes (small 7), pitch 70 (small 93) both ways, r = 20 (small 28); rows fill bottom-up,
    # left → right. Grain falls in a column above the top row and stops 40 px above it.
    pts = []
    cols = 7 if small else 9
    pitch = 560 / (cols - 1)
    rows = [800, 800 - pitch, 800 - 2 * pitch] if not small else [790, 790 - pitch, 790 - 2 * pitch]
    for ri, y in enumerate(rows):
        for c in range(cols):
            node(pts, 232 + c * pitch, y, 28 if small else 20, (ri * cols + c) / (3 * cols - 1), rnd, 300)
    top = rows[-1] - 40 - (28 if small else 20)
    # Grain density falls off upward (half-normal, σ = 170) and its column is as wide as the rows, so it reads as
    # falling grain, not a box; nothing is clipped.
    for _ in range(14 if small else 1100):
        x = 232 + rnd() * 560
        y = top - abs(g(rnd)) * (120 if small else 170)
        pts.append(P(x, y, (13 + rnd() * 3) if small else (1.8 + rnd() * 2.6), 0, 0, 0, 1))
    return pts

VARIATIONS = {'v1-columns': (v1, 51), 'v2-calendar': (v2, 52), 'v3-curve': (v3, 53), 'v4-clock': (v4, 54),
              'v5-point': (v5, 55), 'v6-ticks': (v6, 56), 'v7-hourglass': (v7, 57)}

def positions(pts, t):
    out = []
    for tx, ty, r, f, nx, ny, o in pts:
        s = smooth((t - 0.55 * o) / 0.45)
        k = 1 - f * s
        # Before a point's turn, it's lost: extra drift so frame 1 is all noise.
        out.append((tx + nx * k * (1 + 0.6 * (1 - s)), ty + ny * k * (1 + 0.6 * (1 - s)), r))
    return out

def svg(pts, bg, ink, t=1, w=1024, ox=0):
    body = ''.join(f'<circle cx="{x + ox:.1f}" cy="{y:.1f}" r="{r:.2f}" fill="{ink}"/>' for x, y, r in positions(pts, t))
    return body

def write(path, inner, bg, w=1024):
    with open(path, 'w') as f:
        f.write(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} 1024" width="{w}" height="1024">'
                f'<rect width="{w}" height="1024" fill="{bg}"/>{inner}</svg>')

def png(src, w, h, out):
    subprocess.run(['rsvg-convert', '-w', str(w), '-h', str(h), src, '-o', os.path.join(HERE, out)], check=True)

for name, (fn, seed) in VARIATIONS.items():
    big, small = fn(mulberry32(seed), False), fn(mulberry32(seed), True)
    for variant, (bg, ink) in (('dark', DARK), ('light', LIGHT)):
        p = os.path.join(HERE, f'{name}-{variant}.svg'); write(p, svg(big, bg, ink), bg)
        png(p, 1024, 1024, f'{name}-{variant}-1024.png'); png(p, 180, 180, f'{name}-{variant}-180.png')
        ps = os.path.join(HERE, f'{name}-{variant}-small.svg'); write(ps, svg(small, bg, ink), bg)
        png(ps, 58, 58, f'{name}-{variant}-58.png')
    frames = ''.join(f'<rect x="{i * 1024}" width="1024" height="1024" fill="{DARK[0]}"/>' + svg(big, DARK[0], DARK[1], t, ox=i * 1024)
                     for i, t in enumerate((0.1, 0.55, 1.0)))
    st = os.path.join(HERE, f'{name}-strip.svg'); write(st, frames, DARK[0], 3072)
    png(st, 960, 320, f'{name}-strip.png')

def rounded(img, radius):
    mask = Image.new('L', img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.size[0] - 1, img.size[1] - 1), radius, fill=255)
    return img.convert('RGBA'), mask

names = list(VARIATIONS)
sh = Image.new('RGB', (1700, 30 + (len(names) + 1) * 220 + 300), '#2A2C33')
d = ImageDraw.Draw(sh)
rows = [('Vyst (ref)', None)] + [(n, n) for n in names]
for i, (label, n) in enumerate(rows):
    y = 20 + i * 220
    if n is None:
        im, m = rounded(Image.open(REF).convert('RGB').resize((180, 180), Image.LANCZOS), 40); sh.paste(im, (20, y), m)
        im, m = rounded(Image.open(REF).convert('RGB').resize((58, 58), Image.LANCZOS), 13); sh.paste(im, (215, y + 122), m)
    else:
        im, m = rounded(Image.open(os.path.join(HERE, f'{n}-dark-180.png')), 40); sh.paste(im, (20, y), m)
        im, m = rounded(Image.open(os.path.join(HERE, f'{n}-dark-58.png')), 13); sh.paste(im, (215, y + 122), m)
        sh.paste(Image.open(os.path.join(HERE, f'{n}-light-180.png')).convert('RGB'), (290, y))
        sh.paste(Image.open(os.path.join(HERE, f'{n}-strip.png')).convert('RGB').resize((540, 180)), (490, y))
    d.text((1050, y + 80), label, fill='#E6E6E6')
y = 30 + len(rows) * 220
for k, (wall, variant) in enumerate((('#1E2230', 'dark'), ('#DADDE6', 'light'))):
    yy = y + k * 140
    d.rectangle((0, yy, 1700, yy + 130), fill=wall)
    icons = [Image.open(REF).convert('RGB').resize((58, 58), Image.LANCZOS)] + \
            [Image.open(os.path.join(HERE, f'{n}-{variant}-58.png')) for n in names]
    big = [Image.open(REF).convert('RGB').resize((90, 90), Image.LANCZOS)] + \
          [Image.open(os.path.join(HERE, f'{n}-{variant}-180.png')).resize((90, 90), Image.LANCZOS) for n in names]
    for i, (b, s) in enumerate(zip(big, icons)):
        im, m = rounded(b.convert('RGB'), 20); sh.paste(im, (20 + i * 110, yy + 20), m)
        im, m = rounded(s.convert('RGB'), 13); sh.paste(im, (900 + i * 90, yy + 36), m)
sh.save(os.path.join(HERE, 'sheet.png'))
print('✅ round5 rendered')
