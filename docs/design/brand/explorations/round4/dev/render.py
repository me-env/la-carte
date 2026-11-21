"""Round 4 dev: the critic's shortlist (path, traced, spiral) developed in Vyst's bar language.
Run: python3 -I render.py. Deterministic (no randomness needed except seeded jitter). Each concept is a function
(ink, t) -> SVG elements in a 1024 frame; t = animation progress (1 = final mark). Outputs per concept:
<name>-{dark,light}-1024.png, -58.png (small file where one exists), <name>-strip.png (t = 0.3, 0.65, 1), sheet.png.
"""
import math, os, subprocess
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.join(HERE, '../../../../reference/vyst-app-icon-512.png')
DARK, LIGHT = ('#151514', '#F2F2F0'), ('#F9FAF5', '#1C1C1C')
BAR = 60  # bar weight at 1024, like Vyst's bars

def smooth(t):
    t = min(max(t, 0), 1); return t * t * (3 - 2 * t)

def stroke(pts, ink, w, op=1):
    if len(pts) < 2: return ''
    d = 'M' + ' L'.join(f'{x:.1f} {y:.1f}' for x, y in pts)
    return f'<path d="{d}" fill="none" stroke="{ink}" stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round" opacity="{op:.2f}"/>'

def dot(x, y, r, ink, op=1):
    return f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r:.1f}" fill="{ink}" opacity="{op:.2f}"/>'

def bez(p0, p1, p2, p3, n=200):
    return [((1-t)**3*p0[0] + 3*(1-t)**2*t*p1[0] + 3*(1-t)*t*t*p2[0] + t**3*p3[0],
             (1-t)**3*p0[1] + 3*(1-t)**2*t*p1[1] + 3*(1-t)*t*t*p2[1] + t**3*p3[1]) for t in (i / n for i in range(n + 1))]

def trim(pts, f):
    return pts[: max(0, int(len(pts) * min(max(f, 0), 1)))]

def appear(t, start, span=0.25):
    return smooth((t - start) / span)

# 1. PATH — a path worn in: growing dots → spaced dashes → a solid bar. Rise ≈ 15°, the last dash is level and in
# line with the bar (same ~22 px gap as the others). Small file (≤ 58 px): 3 big dots, one dash, a heavier bar.
def path(ink, t=1, small=False):
    y0, y1, x0, x1 = 575, 475, 150, 880
    curve = bez((x0, y0), (290, y0), (350, y1), (450, y1), 400)   # level from x ≈ 420
    gap = 22
    bar_w = BAR if not small else 72
    if small:
        dots = [(0.02, 27), (0.22, 29), (0.42, 31)]
        dashes = []
        last = (478, 56)                                  # (visual end x, stroke) of the level dash
    else:
        dots = [(0.02, 9), (0.10, 11.5), (0.18, 14), (0.26, 17)]
        dashes = [((0.40, 0.47), 30), ((0.60, 0.72), 40)]
        last = (478, 48)
    e, step = [], 0
    for pos, r in dots:
        a = appear(t, step * 0.07); step += 1
        if a > 0:
            x, y = curve[int(pos * 400)]
            e.append(dot(x, y, r * (0.6 + 0.4 * a), ink, a))
    for (p0, p1), w in dashes:
        a = appear(t, step * 0.07); step += 1
        if a > 0:
            e.append(stroke(trim(curve[int(p0 * 400): int(p1 * 400)], a), ink, w))
    # The last dash: straight and level on the bar's line, 70 long (visual), ending `gap` before the bar.
    end_x, w = last
    a = appear(t, step * 0.07)
    if a > 0:
        xa, xb = end_x - 70 + w / 2, end_x - w / 2
        e.append(stroke([(xa, y1), (xa + (xb - xa) * a, y1)], ink, w))
    g = appear(t, 0.5, 0.5)
    if g > 0:
        bx = end_x + gap + bar_w / 2
        e.append(stroke([(bx, y1), (bx + (x1 - bar_w / 2 - bx) * g, y1)], ink, bar_w))
    return e

# 2. TRACED — 6 thin passes fanning at the left (±40), merging into one bar-weight stroke on the right.
def traced(ink, t=1, small=False, dotted=False):
    e, xm, x0, x1, y = [], 540, 150, 880, 520
    offsets = (-40, -24, -8, 8, 24, 40) if not small else (-60, 0, 60)
    w = 8 if not small else 26
    for k, off in enumerate(offsets):
        op = (1 - 0.5 * abs(off) / max(abs(o) for o in offsets)) if not small else 0.9
        pts = bez((x0 + abs(off) * 0.8, y + off), (300, y + off * 0.9), (420, y + off * 0.15), (xm, y), 200)
        a = appear(t, 0.05 * k, 0.5)
        if dotted:
            # Each pass starts as dots (recall is patchy) and becomes a line as it nears the bar.
            for i in range(3 * k, 90, 18):  # staggered per strand, so the dots don't line up in columns
                if i / 200 < a:
                    e.append(dot(*pts[i], 6 + i / 30, ink, op))
            e.append(stroke(trim(pts[100:], (a - 0.45) / 0.55), ink, w, op))
        else:
            e.append(stroke(trim(pts, a), ink, w, op))
    g = appear(t, 0.45, 0.55)
    if g > 0:
        e.append(stroke([(xm - 20, y), (xm - 20 + (x1 - xm + 20) * g, y)], ink, BAR))
    return e

def traced_dots(ink, t=1, small=False):
    return traced(ink, t, small, dotted=True)

# 3. SPIRAL — expanding intervals: centre dot, 2.5 turns with gaps widening 1.6× per turn, then the line leaves the
# coil's top and eases down into a horizontal bar at the coil's mid-height. The whole mark is centred on its bbox.
def spiral_raw(t=1, small=False):
    cx, cy, r0, k, turns = 0.0, 0.0, 80, 1.6, 2.5
    th_end = -math.pi / 2                                    # top of the coil, heading right
    th0 = th_end - 2 * math.pi * turns
    n = 700
    coil = []
    for i in range(n + 1):
        th = th0 + (th_end - th0) * i / n
        r = r0 * k ** ((th - th0) / (2 * math.pi))
        coil.append((cx + r * math.cos(th), cy + r * math.sin(th)))
    R = r0 * k ** turns
    # Ease out of the coil: top point → mid-height, outside the coil, then straight right.
    bend = bez(coil[-1], (cx + R * 0.75, cy - R), (cx + R * 1.05, cy), (cx + R * 1.35, cy), 120)
    tail_end = cx + R * 1.35 + 230
    return coil, bend, (cx + R * 1.35, tail_end, cy)

def spiral(ink, t=1, small=False):
    coil, bend, (tx0, tx1, ty) = spiral_raw()
    xs = [p[0] for p in coil] + [tx1]; ys = [p[1] for p in coil]
    dx = 512 - (min(xs) + max(xs)) / 2 + 10   # optical: a hair right, the coil is heavier
    dy = 512 - (min(ys) + max(ys)) / 2
    mv = lambda pts: [(x + dx, y + dy) for x, y in pts]
    w = 34 if not small else 52
    e = [dot(dx, dy, (26 if not small else 34) * appear(t, 0, 0.15), ink)]
    e.append(stroke(trim(mv(coil), (t - 0.05) / 0.55), ink, w))
    g = appear(t, 0.6, 0.4)
    if g > 0:
        e.append(stroke(trim(mv(bend), g * 2.5), ink, w))
        if g > 0.4:
            f = (g - 0.4) / 0.6
            e.append(stroke([(tx0 + dx, ty + dy), (tx0 + dx + (tx1 - tx0) * f, ty + dy)], ink, BAR if not small else 64))
    return e

CONCEPTS = {'path': (path, True), 'spiral': (spiral, True)}  # traced + traced-dots cut by the critic

def svg(elements, bg, w=1024):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} 1024" width="{w}" height="1024">\n'
            f'<rect width="{w}" height="1024" fill="{bg}"/>\n' + '\n'.join(x for x in elements if x) + '\n</svg>\n')

def png(src, w, h, out):
    subprocess.run(['rsvg-convert', '-w', str(w), '-h', str(h), src, '-o', os.path.join(HERE, out)], check=True)

for name, (fn, has_small) in CONCEPTS.items():
    for variant, (bg, ink) in (('dark', DARK), ('light', LIGHT)):
        big = os.path.join(HERE, f'{name}-{variant}.svg')
        open(big, 'w').write(svg(fn(ink), bg))
        png(big, 1024, 1024, f'{name}-{variant}-1024.png')
        png(big, 180, 180, f'{name}-{variant}-180.png')
        src = big
        if has_small:
            src = os.path.join(HERE, f'{name}-{variant}-small.svg')
            open(src, 'w').write(svg(fn(ink, small=True), bg))
        png(src, 58, 58, f'{name}-{variant}-58.png')
    frames = []
    for i, t in enumerate((0.3, 0.65, 1.0)):
        frames.append(f'<g transform="translate({i * 1024} 0)"><rect width="1024" height="1024" fill="{DARK[0]}"/>'
                      + ''.join(x for x in fn(DARK[1], t) if x) + '</g>')
    strip = os.path.join(HERE, f'{name}-strip.svg')
    open(strip, 'w').write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 3072 1024" width="3072" height="1024">\n'
                           + '\n'.join(frames) + '\n</svg>\n')
    png(strip, 960, 320, f'{name}-strip.png')

def rounded(img, radius):
    mask = Image.new('L', img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.size[0] - 1, img.size[1] - 1), radius, fill=255)
    return img.convert('RGBA'), mask

sheet = Image.new('RGB', (1560, 40 + len(CONCEPTS) * 230 + 220), '#2A2C33')
d = ImageDraw.Draw(sheet)
for row, name in enumerate(CONCEPTS):
    y = 20 + row * 230
    im, m = rounded(Image.open(os.path.join(HERE, f'{name}-dark-180.png')), 40); sheet.paste(im, (20, y), m)
    im, m = rounded(Image.open(os.path.join(HERE, f'{name}-dark-58.png')), 13); sheet.paste(im, (215, y + 122), m)
    sheet.paste(Image.open(os.path.join(HERE, f'{name}-light-180.png')).convert('RGB'), (290, y))
    sheet.paste(Image.open(os.path.join(HERE, f'{name}-strip.png')).convert('RGB').resize((540, 180)), (490, y))
    im, m = rounded(Image.open(os.path.join(HERE, f'{name}-light-58.png')), 13); sheet.paste(im, (1050, y + 122), m)
    d.text((20, y + 190), name, fill='#E6E6E6')
y = 40 + len(CONCEPTS) * 230
for bg, label, yy in (('#2A2C33', 'dark, 58 px', y), ('#E9E9EE', 'light, 58 px', y + 100)):
    d.rectangle((0, yy - 10, 1560, yy + 90), fill=bg)
    d.text((20, yy), label, fill='#888888')
    vyst = Image.open(REF).convert('RGB').resize((58, 58), Image.LANCZOS)
    icons = [vyst] + [Image.open(os.path.join(HERE, f'{n}-{"dark" if bg == "#2A2C33" else "light"}-58.png')) for n in CONCEPTS]
    for i, ic in enumerate(icons):
        im, m = rounded(ic, 13); sheet.paste(im, (120 + i * 90, yy + 15), m)
sheet.save(os.path.join(HERE, 'sheet.png'))
print('✅ round4/dev rendered')

# Final comparison: path vs spiral, dark + light at 1024 (shown at 360) and 58, plus a home-screen row.
fs = Image.new('RGB', (1680, 1080), '#2A2C33')
d = ImageDraw.Draw(fs)
for col, name in enumerate(('path', 'spiral')):
    x = 30 + col * 830
    d.text((x, 12), name, fill='#E6E6E6')
    for j, variant in enumerate(('dark', 'light')):
        big = Image.open(os.path.join(HERE, f'{name}-{variant}-1024.png')).convert('RGB').resize((360, 360), Image.LANCZOS)
        im, m = rounded(big, 80); fs.paste(im, (x + j * 400, 34), m)
        small = Image.open(os.path.join(HERE, f'{name}-{variant}-58.png'))
        im, m = rounded(small, 13); fs.paste(im, (x + j * 400 + 151, 410), m)
for row, (wall, label) in enumerate((('#1E2230', 'home screen, dark'), ('#DADDE6', 'home screen, light'))):
    y = 520 + row * 270
    d.rectangle((0, y, 1680, y + 250), fill=wall)
    d.text((30, y + 10), label, fill='#888888')
    variant = 'dark' if row == 0 else 'light'
    icons = [('Vyst', Image.open(REF).convert('RGB').resize((120, 120), Image.LANCZOS)),
             ('path', Image.open(os.path.join(HERE, f'path-{variant}-180.png')).resize((120, 120), Image.LANCZOS)),
             ('spiral', Image.open(os.path.join(HERE, f'spiral-{variant}-180.png')).resize((120, 120), Image.LANCZOS))]
    for i, (n, ic) in enumerate(icons):
        im, m = rounded(ic.convert('RGB'), 27); fs.paste(im, (60 + i * 200, y + 50), m)
        d.text((60 + i * 200 + 40, y + 180), n, fill='#888888')
        s58 = (ic.resize((58, 58), Image.LANCZOS) if n == 'Vyst'
               else Image.open(os.path.join(HERE, f'{n}-{variant}-58.png')))
        im, m = rounded(s58.convert('RGB'), 13); fs.paste(im, (760 + i * 90, y + 80), m)
fs.save(os.path.join(HERE, 'final-sheet.png'))
print('✅ final-sheet.png')
