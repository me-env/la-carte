"""Round 4 thumbnails: 11 knowledge-consolidation concepts (see concepts.md). Run: python3 -I render.py
Deterministic (mulberry32 seeds). Writes <concept>/{dark,light}.svg, dark-180/-58 + light-180 PNGs, and sheet.png."""
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

def poly(pts, ink, w, closed=False, op=1, fill='none'):
    d = 'M' + ' L'.join(f'{x:.1f} {y:.1f}' for x, y in pts) + (' Z' if closed else '')
    return (f'<path d="{d}" fill="{fill if fill != "ink" else ink}" stroke="{ink if w else "none"}" stroke-width="{w}" '
            f'stroke-linecap="round" stroke-linejoin="round" opacity="{op}"/>')

def bezier(p0, p1, p2, p3, n=80):
    out = []
    for i in range(n + 1):
        t = i / n; a = 1 - t
        out.append((a**3*p0[0] + 3*a*a*t*p1[0] + 3*a*t*t*p2[0] + t**3*p3[0],
                    a**3*p0[1] + 3*a*a*t*p1[1] + 3*a*t*t*p2[1] + t**3*p3[1]))
    return out

def traced(ink):
    rnd, e = mulberry32(1), []
    for _ in range(9):
        j = lambda: (rnd() - 0.5) * 130
        e.append(poly(bezier((200 + j() / 3, 560 + j()), (380 + j(), 330 + j()), (640 + j(), 720 + j()), (824, 470 + j())),
                      ink, 6, op=0.5))
    e.append(poly(bezier((200, 560), (380, 330), (640, 720), (824, 470)), ink, 34))
    return e

def rings(ink):
    e = [f'<circle cx="500" cy="520" r="34" fill="{ink}"/>']
    for k, r in enumerate((92, 150, 196, 232, 262)):
        e.append(f'<circle cx="{500 + k*5}" cy="{520 - k*7}" r="{r}" fill="none" stroke="{ink}" stroke-width="{22 - k*2.5}"/>')
    return e

def path(ink):
    pts = bezier((190, 720), (360, 720), (600, 330), (834, 320), 400)
    e = []
    i = 0
    while i < len(pts):
        u = i / len(pts)
        if u < 0.3:
            e.append(f'<circle cx="{pts[i][0]:.1f}" cy="{pts[i][1]:.1f}" r="14" fill="{ink}"/>'); i += 30
        elif u < 0.62:
            seg = int(18 + 60 * (u - 0.3) / 0.32)
            e.append(poly(pts[i:i + seg], ink, 28)); i += seg + 22
        else:
            e.append(poly(pts[i:], ink, 40)); break
    return e

def spiral(ink):
    pts = [(512 + 14 * math.exp(0.19 * t) * math.cos(t), 512 + 14 * math.exp(0.19 * t) * math.sin(t))
           for t in [i * 0.05 for i in range(int(17.3 / 0.05))]]
    return [f'<circle cx="512" cy="512" r="22" fill="{ink}"/>', poly(pts, ink, 30)]

def curve(ink):
    pts, x, top = [], 170, 340
    for width, tau, floor in ((170, 45, 660), (230, 95, 600), (284, 260, 520)):
        for i in range(41):
            dx = width * i / 40
            pts.append((x + dx, top + (floor - top) * (1 - math.exp(-dx / tau))))
        x += width
        if width != 284:
            pts.append((x, top))
    return [poly(pts, ink, 30)]

def crystal(ink, bg):
    cx, cy = 512, 512
    outer = [(cx, cy - 300), (cx + 210, cy - 90), (cx + 150, cy + 250), (cx - 150, cy + 250), (cx - 210, cy - 90)]
    return [poly(outer, ink, 0, True, fill='ink'),
            poly([(cx - 210, cy - 90), (cx, cy - 20), (cx + 210, cy - 90)], bg, 16),
            poly([(cx, cy - 20), (cx, cy + 250)], bg, 16)]

def pebble(ink):
    rnd, e = mulberry32(7), []
    noise = [rnd() for _ in range(24)]
    for k, (r, rough, w) in enumerate(((300, 0.22, 10), (240, 0.12, 14), (180, 0.05, 18))):
        pts = []
        for i in range(24):
            a = 2 * math.pi * i / 24
            rr = r * (1 + rough * (noise[i] - 0.5) * 2) * (1 if i % 2 else 1 - rough * 0.4)
            pts.append((512 + rr * math.cos(a) * 1.1, 520 + rr * math.sin(a) * 0.85))
        e.append(poly(pts, ink, w, True, op=0.55 + 0.2 * k))
    e.append(f'<ellipse cx="512" cy="520" rx="130" ry="96" fill="{ink}"/>')
    return e

def echoes(ink):
    e = [f'<circle cx="300" cy="512" r="40" fill="{ink}"/>']
    for r, w in ((140, 16), (250, 30), (360, 46)):
        a = math.radians(48)
        x0, y0 = 300 + r * math.cos(-a), 512 + r * math.sin(-a)
        x1, y1 = 300 + r * math.cos(a), 512 + r * math.sin(a)
        e.append(f'<path d="M{x0:.1f} {y0:.1f} A{r} {r} 0 0 1 {x1:.1f} {y1:.1f}" fill="none" stroke="{ink}" '
                 f'stroke-width="{w}" stroke-linecap="round"/>')
    return e

def synapse(ink):
    rnd, e = mulberry32(9), []
    a, b = (230, 610), (794, 414)
    for _ in range(14):
        s = (rnd() - 0.5) * 320
        e.append(poly(bezier(a, (400, 520 + s), (620, 500 + s), b), ink, 7, op=0.8))
    e += [f'<circle cx="{a[0]}" cy="{a[1]}" r="54" fill="{ink}"/>', f'<circle cx="{b[0]}" cy="{b[1]}" r="54" fill="{ink}"/>']
    return e

def strata(ink):
    e, y = [], 760
    for h in (84, 62, 46, 34):
        e.append(f'<rect x="232" y="{y - h}" width="560" height="{h}" rx="{h/2}" fill="{ink}"/>'); y -= h + 22
    for i in range(14):
        e.append(f'<circle cx="{252 + i * 40}" cy="{y - 12}" r="9" fill="{ink}"/>')
    return e

def loops(ink):
    pts = []
    for i in range(1200):
        t = i / 1200 * 6 * math.pi
        b = 150 * (1 - 0.72 * t / (6 * math.pi))
        pts.append((190 + 33 * t - b * math.sin(t), 512 - b * math.cos(t) + 60))
    return [poly(pts, ink, 28)]

CONCEPTS = {'01-traced': traced, '02-rings': rings, '03-path': path, '04-spiral': spiral, '05-curve': curve,
            '06-crystal': crystal, '07-pebble': pebble, '08-echoes': echoes, '09-synapse': synapse,
            '10-strata': strata, '11-loops': loops}

def render(name, fn):
    os.makedirs(os.path.join(HERE, name), exist_ok=True)
    for variant, (bg, ink) in (('dark', DARK), ('light', LIGHT)):
        body = fn(ink, bg) if fn is crystal else fn(ink)
        p = os.path.join(HERE, name, f'{variant}.svg')
        with open(p, 'w') as f:
            f.write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">\n'
                    f'<rect width="1024" height="1024" fill="{bg}"/>\n' + '\n'.join(body) + '\n</svg>\n')
        sizes = (180, 58) if variant == 'dark' else (180,)
        for size in sizes:
            subprocess.run(['rsvg-convert', '-w', str(size), '-h', str(size), p, '-o',
                            os.path.join(HERE, name, f'{variant}-{size}.png')], check=True)

def rounded(img, radius):
    mask = Image.new('L', img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.size[0] - 1, img.size[1] - 1), radius, fill=255)
    out = Image.new('RGBA', img.size, (0, 0, 0, 0)); out.paste(img.convert('RGBA'), (0, 0), mask)
    return out

def sheet():
    cells = [('Vyst (ref)', Image.open(REF).convert('RGB').resize((180, 180), Image.LANCZOS), None)]
    for name in CONCEPTS:
        cells.append((name, Image.open(os.path.join(HERE, name, 'dark-180.png')),
                      Image.open(os.path.join(HERE, name, 'light-180.png'))))
    cw, ch, cols = 470, 270, 4
    rows = math.ceil(len(cells) / cols)
    sh = Image.new('RGB', (cols * cw + 40, rows * ch + 140), '#2A2C33')
    d = ImageDraw.Draw(sh)
    for i, (name, dark, light) in enumerate(cells):
        x, y = 20 + (i % cols) * cw, 20 + (i // cols) * ch
        sh.paste(rounded(dark, 40), (x, y), rounded(dark, 40))
        small = (Image.open(REF).convert('RGB').resize((58, 58), Image.LANCZOS) if light is None
                 else Image.open(os.path.join(HERE, name, 'dark-58.png')))
        sh.paste(rounded(small, 13), (x + 195, y + 122), rounded(small, 13))
        if light is not None:
            sh.paste(light.resize((180, 180)), (x + 270, y))
        d.text((x, y + 190), name, fill='#E6E6E6')
    # Home-screen strip: every 58 px icon in a row, Vyst first.
    y = rows * ch + 40
    d.text((20, y - 18), 'all at 58 px (29 pt @2x)', fill='#E6E6E6')
    icons = [Image.open(REF).convert('RGB').resize((58, 58), Image.LANCZOS)] + \
            [Image.open(os.path.join(HERE, n, 'dark-58.png')) for n in CONCEPTS]
    for i, ic in enumerate(icons):
        sh.paste(rounded(ic, 13), (20 + i * 78, y), rounded(ic, 13))
    sh.save(os.path.join(HERE, 'sheet.png'))

for name, fn in CONCEPTS.items():
    render(name, fn)
sheet()
print('✅ round4 rendered')
