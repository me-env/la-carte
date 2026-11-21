"""Round 6 (critic pass 2): 'point', noise resolving into structure, time left → right. python3 -I render.py
Construction (px at 1024), one ratio everywhere: ×1.4.
- Nodes on y = 512: r 5.1, 7.1, 10, 14, 19.6, 27.4, 38.4. Edge gaps also grow ×1.4 from the apex: 5.7, 8, 11.2,
  15.7, 22, 30.8, 43 (intervals expand, like spaced repetition).
- Grain continues the series below 5.1: r 1.86 (left third of the wedge), 2.60 (middle), 3.64 (last third).
  Poisson-disc: centres ≥ r1 + r2 + 2 apart. Inside a 45° wedge |y − 512| ≤ (apex − x); density rises linearly
  from 0 at the wedge's left end to the apex; no grain within 24 px of the left end. Opacity 0.45 → 1 left → apex.
- Ink centred: the horizontal position is the mean of box centre and area centroid; margins ≥ 140.
- 58 px = the 1024 master downscaled (the critic found it reads better than a dedicated build).
Animation (t 0 → 1, 1.2 s): grain starts at 1.2× its distance from the apex and drifts in; nodes scale out of the
apex together (uniform scaling keeps every gap), each fading in in time order. Uniform scaling about the apex means
no two elements ever overlap; render.py checks every 1/30 s and that nothing leaves the canvas.
Reduce Motion: the final frame with a 0.3 s crossfade.
"""
import math, os, subprocess
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.join(HERE, '../../../reference/vyst-app-icon-512.png')
THEMES = {'dark': ('#151514', '#F2F2F0'), 'light': ('#F9FAF5', '#1C1C1C'), 'forest': ('#0E1913', '#EEF2EC')}
Y, SEED = 512, 61
RADII = [5.1, 7.1, 10, 14, 19.6, 27.4, 38.4]
GAPS = [5.7 * 1.4 ** i for i in range(7)]          # gap before each node, from the apex
GRAIN_R = [1.86, 2.60, 3.64]
LENGTH = 346                                       # wedge length (= half-height at its left end, 45°)

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

def build():
    apex = 0.0
    nodes, x = [], apex
    for r, gap in zip(RADII, GAPS):
        x += gap + r; nodes.append((x, r)); x += r
    rnd, grain, tries = mulberry32(SEED), [], 0
    xl = apex - LENGTH
    while len(grain) < 700 and tries < 400000:
        tries += 1
        u = math.sqrt(rnd())                        # pdf ∝ u: density rises linearly toward the apex
        x = xl + u * LENGTH
        if x < xl + 24: continue
        r = GRAIN_R[min(int(u * 3), 2)]
        half = apex - x - r                          # stay inside the 45° wedge, edge included
        if half <= 0: continue
        y = Y + (rnd() * 2 - 1) * half
        if any((x - px) ** 2 + (y - py) ** 2 < (r + pr + 2) ** 2 for px, py, pr, _ in grain): continue
        if x + r > apex: continue
        grain.append((x, y, r, 0.45 + 0.55 * u))
    # Centre: mean of ink-box centre and area centroid.
    left = min(x - r for x, y, r, o in grain); right = nodes[-1][0] + nodes[-1][1]
    area = [(x, r * r) for x, y, r, o in grain] + [(x, r * r) for x, r in nodes]
    cx = sum(x * a for x, a in area) / sum(a for x, a in area)
    dx = 512 - ((left + right) / 2 + cx) / 2
    return apex + dx, [(x + dx, y, r, o) for x, y, r, o in grain], [(x + dx, r) for x, r in nodes], (left + dx, right + dx, cx + dx)

APEX, GRAIN, NODES, (LEFT, RIGHT, CX) = build()

def frame(t):
    """Circles (x, y, r, opacity) at progress t."""
    kg = 1 + 0.2 * (1 - smooth(t))                   # grain: 1.2× from the apex → 1×
    out = [(APEX + (x - APEX) * kg, Y + (y - Y) * kg, r, o * smooth(t / 0.3)) for x, y, r, o in GRAIN]
    kn = smooth((t - 0.25) / 0.75)                   # nodes scale out of the apex together
    for i, (x, r) in enumerate(NODES):
        a = smooth((kn - 0.6 * i / 6) / 0.4)         # node i fades in at kn = 0.6·i/6, fully on by kn = 1
        if kn > 0 and a > 0:
            out.append((APEX + (x - APEX) * kn, Y, r * kn, a))
    return out

def check():
    worst = None
    for f in range(37):
        pts = frame(f / 36)
        for x, y, r, o in pts:
            assert r <= x <= 1024 - r and r <= y <= 1024 - r, f'off canvas at frame {f}'
        nodes = [p for p in pts if p[1] == Y and p[2] > 4.5 and p[0] > APEX]
        for i, a in enumerate(pts):
            for b in pts[i + 1:]:
                d = math.dist(a[:2], b[:2]) - a[2] - b[2]
                if worst is None or d < worst: worst = d
                assert d > 0, f'overlap at frame {f}'
    return worst

def svg(circles, bg, w=1024, ox=0):
    return ''.join(f'<circle cx="{x + ox:.1f}" cy="{y:.1f}" r="{r:.2f}" fill="{{ink}}" fill-opacity="{o:.2f}"/>'
                   for x, y, r, o in circles)

def write(path, body, bg, w=1024):
    with open(path, 'w') as f:
        f.write(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} 1024" width="{w}" height="1024">'
                f'<rect width="{w}" height="1024" fill="{bg}"/>{body}</svg>')

def png(src, w, h, out):
    subprocess.run(['rsvg-convert', '-w', str(w), '-h', str(h), src, '-o', os.path.join(HERE, out)], check=True)

for theme, (bg, ink) in THEMES.items():
    p = os.path.join(HERE, f'point-{theme}.svg')
    write(p, svg(frame(1), bg).replace('{ink}', ink), bg)
    for size in (1024, 180, 58):
        png(p, size, size, f'point-{theme}-{size}.png')
bg, ink = THEMES['dark']
body = ''.join(f'<rect x="{i * 1024}" width="1024" height="1024" fill="{bg}"/>' + svg(frame(t), bg, ox=i * 1024)
               for i, t in enumerate((0.15, 0.55, 1.0))).replace('{ink}', ink)
st = os.path.join(HERE, 'point-strip.svg'); write(st, body, bg, 3072); png(st, 960, 320, 'point-strip.png')

def rounded(img, radius):
    mask = Image.new('L', img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.size[0] - 1, img.size[1] - 1), radius, fill=255)
    return img.convert('RGBA'), mask

sh = Image.new('RGB', (1400, 760), '#2A2C33'); d = ImageDraw.Draw(sh)
vy = Image.open(REF).convert('RGB')
for i, (name, im180, im58) in enumerate([('vyst', vy.resize((180, 180), Image.LANCZOS), vy.resize((58, 58), Image.LANCZOS))] +
                                       [(t, Image.open(os.path.join(HERE, f'point-{t}-180.png')), Image.open(os.path.join(HERE, f'point-{t}-58.png'))) for t in THEMES]):
    x = 20 + i * 260
    im, m = rounded(im180.convert('RGB'), 40); sh.paste(im, (x, 20), m)
    im, m = rounded(im58.convert('RGB'), 13); sh.paste(im, (x + 61, 215), m)
    d.text((x, 285), name, fill='#E6E6E6')
sh.paste(Image.open(os.path.join(HERE, 'point-strip.png')).convert('RGB').resize((900, 300)), (20, 320))
for k, (wall, t) in enumerate((('#1E2230', 'dark'), ('#DADDE6', 'light'))):
    yy = 640 + k * 60
    d.rectangle((940, 320 + k * 150, 1400, 460 + k * 150), fill=wall)
    for i, src in enumerate([vy, Image.open(os.path.join(HERE, f'point-{t}-1024.png'))]):
        im, m = rounded(src.convert('RGB').resize((120, 120), Image.LANCZOS), 27); sh.paste(im, (960 + i * 140, 330 + k * 150), m)
        im, m = rounded(src.convert('RGB').resize((58, 58), Image.LANCZOS), 13); sh.paste(im, (1250 + i * 70, 360 + k * 150), m)
sh.save(os.path.join(HERE, 'sheet.png'))
print(f'✅ round6 pass 2: margins {LEFT:.0f}..{RIGHT:.0f}, ink centroid x {CX:.0f}, min gap over animation {check():.2f}px')
