"""Round-2 logo directions in Vyst's visual language (full-bleed dark tile, thick white text bars, grain),
with la-carte's own mechanic: an answer coming back. Deterministic: mulberry32 seeded PRNG (same algorithm is
trivial to port to Swift), so every render is identical. Run: python3 -I render.py  (then rsvg-convert, below).

  r1-recall    a solid prompt bar; below it the answer bar assembling from scattered grain (left) into solid (right)
  r2-settle    grain settling down into one bar (memory consolidating), dense near the bar
  r3-spacing   one bar along a spaced-repetition sawtooth: it fades, a review makes it solid again, each fade slower

Accent: at most 3 pink particles (the furthest drifted). `icon-dark-noaccent` shows the same mark without them.

How the in-app LaCarteLogo would animate it (once a direction is picked): a `Canvas` draws the same seeded particles
(same mulberry32 seed, so the app matches the icon). Each particle has a scattered start and an end inside its bar.
`progress` 0 → 1 moves each one start → end with a per-particle stagger, and the solid bar fades in as they arrive:
the answer assembling is the launch and reveal transition. Played backwards, it's "forgetting". Reduce Motion: no
particle travel, a 0.25 s crossfade to the static mark. Particle count is capped by size: ~150 below 44 pt, full
above 120 pt.
"""
import math, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))

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

def gauss(rnd):
    u = max(rnd(), 1e-9)
    return math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * rnd())

H = 64  # bar thickness at 1024

def bar(x0, x1, y):
    return ('bar', x0, x1, y)

def r1(rnd):
    shapes = [bar(232, 792, 420)]
    y, gx0, gx1, sx1 = 584, 200, 540, 792
    shapes.append(bar(540, sx1, y))
    parts = []
    while len(parts) < 2600:
        u = rnd()
        if rnd() > u ** 1.6:
            continue
        x = gx0 + u * (gx1 - gx0) + gauss(rnd) * 6
        spread = 1 + 2.2 * (1 - u) ** 2
        py = y + (rnd() * 2 - 1) * H / 2 * spread + gauss(rnd) * 10 * (1 - u)
        parts.append((x, py, 1 - u))
    return shapes, parts

def r2(rnd):
    y, x0, x1 = 664, 292, 732
    shapes = [bar(x0, x1, y)]
    parts = []
    while len(parts) < 2400:
        h = -math.log(max(rnd(), 1e-9)) * 110        # height above the bar, exponential: dense near it
        if h > 420:
            continue
        t = min(h / 420, 1)
        cx = (x0 + x1) / 2
        half = (x1 - x0) / 2 * (0.95 - 0.35 * t)      # the falling column narrows as it rises (a soft funnel)
        x = cx + (rnd() * 2 - 1) * half + gauss(rnd) * 18 * t
        py = y - H / 2 - h + gauss(rnd) * 3
        parts.append((x, py, t))
    return shapes, parts

def r3(rnd):
    y = 512
    shapes = [bar(172, 312, y), bar(402, 512, y), bar(612, 692, y)]
    zones = [(312, 402, 30), (512, 612, 55), (692, 852, 110)]  # start, end, decay length (slower each time)
    parts = []
    for z0, z1, tau in zones:
        n = 0
        while n < 800:
            x = z0 + rnd() * (z1 - z0)
            d = math.exp(-(x - z0) / tau)
            if rnd() > d * 0.95 + 0.05:
                continue
            py = y + (rnd() * 2 - 1) * H / 2 * (1 + 0.8 * (1 - d)) + gauss(rnd) * 9 * (1 - d)
            parts.append((x, py, 1 - d))
            n += 1
    return shapes, parts

DIRECTIONS = {'r1-recall': (r1, 11), 'r2-settle': (r2, 22), 'r3-spacing': (r3, 33)}

def svg(shapes, parts, rnd, bg, ink, accent, n_accent, tile):
    out = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">']
    if bg:
        out.append(f'<rect width="1024" height="1024" fill="{bg}"/>')
    for _, x0, x1, y in shapes:
        out.append(f'<rect x="{x0}" y="{y - H/2}" width="{x1 - x0}" height="{H}" rx="{H/2}" fill="{ink}"/>')
    # The furthest-drifted particles get the accent: at most n_accent of them ("very small amounts").
    far = sorted(range(len(parts)), key=lambda i: -parts[i][2])[: n_accent * 8]
    pink = set(far[:: 8][:n_accent]) if accent else set()
    for i, (x, y, drift) in enumerate(parts):
        r = 1.4 + rnd() * 2.2 * (1 - 0.5 * drift)
        o = 0.95 - 0.55 * drift * rnd()
        color = accent if i in pink else ink
        if i in pink:
            r, o = 4.2, 1
        out.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r:.2f}" fill="{color}" fill-opacity="{o:.2f}"/>')
    out.append('</svg>')
    return '\n'.join(out)

VARIANTS = {
    # name: background, ink, accent, tile? — dark icon is primary (like Vyst); "inapp-light" = the mark on paper.
    'icon-dark': ('#1A1A1A', '#F2F2F0', '#ED6E8C'),
    'icon-dark-noaccent': ('#1A1A1A', '#F2F2F0', None),
    'inapp-light': ('#F9FAF5', '#1C1C1C', '#B8325A'),
}

for name, (fn, seed) in DIRECTIONS.items():
    os.makedirs(os.path.join(HERE, name), exist_ok=True)
    shapes, parts = fn(mulberry32(seed))
    for variant, (bg, ink, accent) in VARIANTS.items():
        path = os.path.join(HERE, name, f'{variant}.svg')
        with open(path, 'w') as f:
            f.write(svg(shapes, parts, mulberry32(seed + 1000), bg, ink, accent, 3, True))
        for size in (1024, 58):
            subprocess.run(['rsvg-convert', '-w', str(size), '-h', str(size), path,
                            '-o', os.path.join(HERE, name, f'{variant}-{size}.png')], check=True)
print('✅ round2 rendered')
