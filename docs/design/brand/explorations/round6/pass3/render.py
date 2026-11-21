"""Round 6, pass 3: 'stack', lost data points resolving into a card. python3 -I render.py
Construction (px at 1024), one ratio: ×1.4.
- Front card: solid rounded rect 480 × 316, radius 54 (index-card proportion ≈ 3:2). It's the structure.
- Two cards behind it, up-left, made only of grain (lost points): offsets 80 then 80·1.4 = 112. Grain r by depth:
  2.60 (card 2), 1.86 (card 3; ×1/1.4), and 3.64 within 40 px of the front card (the step into structure).
  Opacity 0.85 / 0.5. Density inside each card falls off softly over 70 px toward its edge (no straight outline).
  Poisson-disc: centres ≥ r1 + r2 + 2; every grain keeps ≥ r + 8 from the front card.
- Mark box centred on the tile.
Animation (1.2 s): grain converges from 1.35× (one uniform scale about the mark centre keeps every gap); the deepest
card fades in first; then the front card fades in while scaling 0.9 → 1 from its centre, so it never touches grain.
render.py checks every 1/30 s for overlap and canvas bounds. Reduce Motion: final frame, 0.3 s crossfade.
"""
import math, os, subprocess
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.join(HERE, '../../../../reference/vyst-app-icon-512.png')
THEMES = {'dark': ('#151514', '#F2F2F0'), 'light': ('#F9FAF5', '#1C1C1C'), 'forest': ('#0E1913', '#EEF2EC')}
W, H, R = 480, 316, 54
OFF = [0, 80, 80 + 112]

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

def sd_rrect(x, y, cx, cy, w=W, h=H, r=R):
    """Signed distance to a rounded rect (negative inside)."""
    qx, qy = abs(x - cx) - (w / 2 - r), abs(y - cy) - (h / 2 - r)
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r

# Front card centre so the whole mark box is centred.
bw, bh = W + OFF[2], H + OFF[2]
C1 = (512 + bw / 2 - W / 2, 512 + bh / 2 - H / 2)
CENTRE = (512, 512)

def build():
    rnd, grain = mulberry32(71), []
    for depth, n, r_base, op in ((2, 520, 1.86, 0.5), (1, 1000, 2.60, 0.85)):
        cx, cy = C1[0] - OFF[depth], C1[1] - OFF[depth]
        tries = 0; count = 0
        while count < n and tries < 300000:
            tries += 1
            x = cx + (rnd() - 0.5) * W; y = cy + (rnd() - 0.5) * H
            inside = -sd_rrect(x, y, cx, cy)
            if inside <= 0 or rnd() > smooth(inside / 70): continue       # soft edge, no straight outline
            dfront = sd_rrect(x, y, *C1)
            r = 3.64 if (depth == 1 and dfront < 40) else r_base
            if dfront < r + 8: continue
            if any((x - px) ** 2 + (y - py) ** 2 < (r + pr + 2) ** 2 for px, py, pr, _, _ in grain): continue
            grain.append((x, y, r, op, depth)); count += 1
    return grain

GRAIN = build()

def frame(t):
    """Returns (circles, card) at progress t; card = (cx, cy, scale, opacity) or None."""
    circles = []
    for x, y, r, op, depth in GRAIN:
        # One shared scale for all grain (uniform scaling keeps every gap); depth shows in the fade-in order only.
        s = 1 + 0.35 * (1 - smooth(t / 0.6))
        fade = smooth((t - (0 if depth == 2 else 0.12)) / 0.3)
        circles.append((CENTRE[0] + (x - CENTRE[0]) * s, CENTRE[1] + (y - CENTRE[1]) * s, r, op * fade))
    a = smooth((t - 0.6) / 0.4)
    return circles, ((C1[0], C1[1], 0.9 + 0.1 * a, a) if a > 0 else None)

def check():
    worst = 1e9
    for f in range(37):
        circles, card = frame(f / 36)
        for x, y, r, o in circles:
            assert r <= x <= 1024 - r and r <= y <= 1024 - r, f'off canvas f{f}'
        if card:
            cx, cy, s, _ = card
            for x, y, r, o in circles:
                d = sd_rrect(x, y, cx, cy, W * s, H * s, R * s) - r
                worst = min(worst, d); assert d > 0, f'card overlap f{f}'
        for i, a in enumerate(circles):
            for b in circles[i + 1:]:
                if abs(a[0] - b[0]) > 10 or abs(a[1] - b[1]) > 10: continue
                d = math.dist(a[:2], b[:2]) - a[2] - b[2]
                worst = min(worst, d); assert d > 0, f'grain overlap f{f}'
    return worst

def svg(t, ink, ox=0):
    circles, card = frame(t)
    out = [f'<circle cx="{x + ox:.1f}" cy="{y:.1f}" r="{r:.2f}" fill="{ink}" fill-opacity="{o:.2f}"/>' for x, y, r, o in circles]
    if card:
        cx, cy, s, a = card
        out.append(f'<rect x="{cx - W * s / 2 + ox:.1f}" y="{cy - H * s / 2:.1f}" width="{W * s:.1f}" height="{H * s:.1f}" '
                   f'rx="{R * s:.1f}" fill="{ink}" fill-opacity="{a:.2f}"/>')
    return ''.join(out)

def write(path, body, bg, w=1024):
    with open(path, 'w') as f:
        f.write(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} 1024" width="{w}" height="1024">'
                f'<rect width="{w}" height="1024" fill="{bg}"/>{body}</svg>')

def png(src, w, h, out):
    subprocess.run(['rsvg-convert', '-w', str(w), '-h', str(h), src, '-o', os.path.join(HERE, out)], check=True)

for theme, (bg, ink) in THEMES.items():
    p = os.path.join(HERE, f'stack-{theme}.svg'); write(p, svg(1, ink), bg)
    for size in (1024, 180, 58):
        png(p, size, size, f'stack-{theme}-{size}.png')
bg, ink = THEMES['dark']
body = ''.join(f'<rect x="{i * 1024}" width="1024" height="1024" fill="{bg}"/>' + svg(t, ink, i * 1024)
               for i, t in enumerate((0.15, 0.55, 1.0)))
st = os.path.join(HERE, 'stack-strip.svg'); write(st, body, bg, 3072); png(st, 960, 320, 'stack-strip.png')

def rounded(img, radius):
    mask = Image.new('L', img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.size[0] - 1, img.size[1] - 1), radius, fill=255)
    return img.convert('RGBA'), mask

sh = Image.new('RGB', (1400, 760), '#2A2C33'); d = ImageDraw.Draw(sh)
vy = Image.open(REF).convert('RGB')
cells = [('vyst', vy.resize((180, 180), Image.LANCZOS), vy.resize((58, 58), Image.LANCZOS))] + \
        [(t, Image.open(os.path.join(HERE, f'stack-{t}-180.png')), Image.open(os.path.join(HERE, f'stack-{t}-58.png'))) for t in THEMES]
for i, (name, a, b) in enumerate(cells):
    x = 20 + i * 260
    im, m = rounded(a.convert('RGB'), 40); sh.paste(im, (x, 20), m)
    im, m = rounded(b.convert('RGB'), 13); sh.paste(im, (x + 61, 215), m)
    d.text((x, 285), name, fill='#E6E6E6')
sh.paste(Image.open(os.path.join(HERE, 'stack-strip.png')).convert('RGB').resize((900, 300)), (20, 320))
for k, (wall, t) in enumerate((('#1E2230', 'dark'), ('#DADDE6', 'light'))):
    d.rectangle((940, 320 + k * 150, 1400, 460 + k * 150), fill=wall)
    for i, src in enumerate([vy, Image.open(os.path.join(HERE, f'stack-{t}-1024.png'))]):
        im, m = rounded(src.convert('RGB').resize((120, 120), Image.LANCZOS), 27); sh.paste(im, (960 + i * 140, 330 + k * 150), m)
        im, m = rounded(src.convert('RGB').resize((58, 58), Image.LANCZOS), 13); sh.paste(im, (1250 + i * 70, 360 + k * 150), m)
sh.save(os.path.join(HERE, 'sheet.png'))
solid = (W * H - (4 - math.pi) * R * R) / 1024 ** 2
gink = sum(math.pi * r * r for _, _, r, _, _ in GRAIN) / 1024 ** 2
print(f'✅ pass3: grains {len(GRAIN)}, solid ink {solid:.1%}, grain ink {gink:.1%} ({gink / (gink + solid):.0%} of ink), min gap {check():.2f}px')
