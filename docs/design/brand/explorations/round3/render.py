"""Round 3: r1-recall refined after design-critic review. Run: python3 -I render.py (needs rsvg-convert).

The mark: two left-aligned text lines on a dark tile. The short top line is the prompt (a word, solid). The long line
below is its answer, assembling from grain that flows in from the left along a gentle S-curve ("coming back to
mind"). Grain density rises smoothly into the bar, and the bar's own opacity ramps 0 → 1 over 140 px, so there's
no hard cut. It's the inverse of Vyst's mark (theirs dissolves to the right, three equal bars).

Deterministic: mulberry32 PRNG, fixed seed. Large sizes draw ~6500 particles (r 0.8–2 px at 1024, white only).
Sizes ≤ 58 px use a separate SVG: no dots, just a soft gradient tail (60% of the bar), so the icon reads as two
lines, not "=".
Animation (for the app's LaCarteLogo, later): particles start further back along the flow, more scattered, and
travel to their resting spots while the answer bar's solid part grows left to right. See anim-strip.png
(t = 0.2, 0.55, 1; the bar only appears in the last 40%). Reduce Motion: crossfade to the final frame.
"""
import math, os, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
SEED = 7

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
    return math.sqrt(-2 * math.log(max(rnd(), 1e-9))) * math.cos(2 * math.pi * rnd())

def smooth(t):
    t = min(max(t, 0), 1)
    return t * t * (3 - 2 * t)

# Geometry at 1024 (the mark spans x ≈ 70 → 872, ~78% of the tile; bars start at x = 232).
H = 60                        # bar thickness
X0 = 232                      # left edge of both lines
PROMPT = (X0, X0 + 244, 450)  # prompt: ends at 476, short of the solid answer bar (no staircase)
ANSWER = (X0, X0 + 640, 574)  # answer line (nominal)
RAMP = (380, 520)             # answer bar opacity ramps 0 → 1 here
GRAIN = (70, 520)             # grain runs from here into the ramp
FLOW = 55                     # how far the S dips below the answer line
OFFSET = (24, -40)            # optical centring of the whole mark (grain weighs it down-left)

def centerline(u):
    """Flow centre's y offset from the answer line, u = 0 (far left) → 1 (joins the bar): an S-shaped approach."""
    # A real S: rises back up at the far left, dips around x ≈ 140, joins the line at u = 0.7 (x ≈ 385), before
    # the bar's ramp, so the ramp is always covered by grain.
    return FLOW * (1 - smooth(u / 0.7)) * smooth((u + 0.12) / 0.4)

def particles():
    rnd = mulberry32(SEED)
    out = []
    while len(out) < 6500:
        u = rnd()
        if rnd() > u ** 1.7:
            continue
        x = GRAIN[0] + u * (GRAIN[1] - GRAIN[0]) + gauss(rnd) * 4
        half = H / 2 * (1 + 1.3 * (1 - u) ** 2)
        y = ANSWER[2] + centerline(u) + (rnd() * 2 - 1) * half + gauss(rnd) * 7 * (1 - u)
        r = 0.8 + rnd() * 1.2
        o = 0.8 + 0.2 * rnd()          # ≥ 80%: no grey specks
        # Animation start: further back along the flow and more scattered.
        back = 120 + 260 * rnd()
        sx = x - back * (1 - 0.6 * u)
        sy = y + back * 0.35 + gauss(rnd) * 30
        out.append((x, y, r, o, sx, sy, rnd()))
    return out

PARTS = particles()

def mark(ink, t=1.0, small=False, gid='a'):
    """The mark as SVG elements in the 1024 frame. t = animation progress (1 = final)."""
    e = []
    px0, px1, py = PROMPT
    e.append(f'<rect x="{px0}" y="{py - H/2}" width="{px1 - px0}" height="{H}" rx="{H/2}" fill="{ink}"/>')
    ax0, ax1, ay = ANSWER
    if small:
        # Continuous tail for small sizes: opacity 0 → 1 from x = 140 to 520 (60% of the bar).
        tail0 = 140
        stop = (RAMP[1] - tail0) / (ax1 - tail0)
        e.append(f'<linearGradient id="{gid}" x1="{tail0}" x2="{ax1}" y1="0" y2="0" gradientUnits="userSpaceOnUse">'
                 f'<stop offset="0" stop-color="{ink}" stop-opacity="0"/>'
                 f'<stop offset="{stop * 0.55:.3f}" stop-color="{ink}" stop-opacity="0.45"/>'
                 f'<stop offset="{stop:.3f}" stop-color="{ink}" stop-opacity="1"/></linearGradient>')
        e.append(f'<rect x="{tail0}" y="{ay - H/2}" width="{ax1 - tail0}" height="{H}" rx="{H/2}" fill="url(#{gid})"/>')
        # Three grain dots at the far left, on the S, so the small icon echoes the big one (not a speed line).
        for x, op in ((92, 0.55), (128, 0.7), (170, 0.85)):
            u = (x - GRAIN[0]) / (GRAIN[1] - GRAIN[0])
            e.append(f'<circle cx="{x}" cy="{ay + centerline(u):.1f}" r="13" fill="{ink}" fill-opacity="{op}"/>')
        return e
    # The bar: solid part grows left → right with t; its left end ramps in.
    grow = smooth((t - 0.6) / 0.3)   # late and fast, so mid-animation frames have no half-grey bar
    right = RAMP[1] + (ax1 - RAMP[1]) * grow
    if right > RAMP[0] + 1 and grow > 0:
        stop = (RAMP[1] - RAMP[0]) / (right - RAMP[0])
        e.append(f'<linearGradient id="{gid}" x1="{RAMP[0]}" x2="{right}" y1="0" y2="0" gradientUnits="userSpaceOnUse">'
                 f'<stop offset="0" stop-color="{ink}" stop-opacity="0"/>'
                 f'<stop offset="{min(stop, 1):.3f}" stop-color="{ink}" stop-opacity="1"/></linearGradient>')
        e.append(f'<rect x="{RAMP[0]}" y="{ay - H/2}" width="{right - RAMP[0]}" height="{H}" rx="{H/2}" fill="url(#{gid})"/>')
    for x, y, r, o, sx, sy, delay in PARTS:
        k = smooth((t - 0.4 * delay) / 0.6)
        cx, cy = sx + (x - sx) * k, sy + (y - sy) * k
        e.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.2f}" fill="{ink}" fill-opacity="{o * (0.3 + 0.7 * k):.2f}"/>')
    return e

def write(name, bg, ink, small=False, t=1.0):
    body = ([f'<rect width="1024" height="1024" fill="{bg}"/>', f'<g transform="translate{OFFSET}">']
            + mark(ink, t, small, gid=name.replace('-', '')) + ['</g>'])
    path = os.path.join(HERE, f'{name}.svg')
    with open(path, 'w') as f:
        f.write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">\n'
                + '\n'.join(body) + '\n</svg>\n')
    return path

def png(svg, size, out):
    subprocess.run(['rsvg-convert', '-w', str(size), '-h', str(size), svg, '-o', os.path.join(HERE, out)], check=True)

VARIANTS = {  # name: tile, ink. Dark is primary (like Vyst). No accent on the icon (critic: none or one dot).
    'dark': ('#151514', '#F2F2F0'),
    'light': ('#F9FAF5', '#1C1C1C'),   # also the in-app logo on paper
    'tinted': ('#000000', '#FFFFFF'),
}
for v, (bg, ink) in VARIANTS.items():
    big = write(f'icon-{v}', bg, ink)
    small = write(f'icon-{v}-small', bg, ink, small=True)
    for size in (1024, 180):
        png(big, size, f'icon-{v}-{size}.png')
    for size in (58, 40, 29):
        png(small, size, f'icon-{v}-{size}.png')

# 3-frame strip of the assemble animation (dark), side by side.
frames = []
for i, t in enumerate((0.2, 0.55, 1.0)):
    frames.append(f'<g transform="translate({i * 1024} 0)"><rect width="1024" height="1024" fill="#151514"/>'
                  + f'<g transform="translate{OFFSET}">' + ''.join(mark('#F2F2F0', t, gid=f'f{i}')) + '</g></g>')
strip = os.path.join(HERE, 'anim-strip.svg')
with open(strip, 'w') as f:
    f.write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 3072 1024" width="3072" height="1024">\n'
            + '\n'.join(frames) + '\n</svg>\n')
subprocess.run(['rsvg-convert', '-w', '1536', '-h', '512', strip, '-o', os.path.join(HERE, 'anim-strip.png')], check=True)
# In-app logo on paper: no tile, cropped to the mark, on the light background.
inapp = os.path.join(HERE, 'inapp-light.svg')
with open(inapp, 'w') as f:
    f.write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="20 320 920 400" width="920" height="400">\n'
            '<rect x="20" y="320" width="920" height="400" fill="#F9FAF5"/>\n'
            f'<g transform="translate{OFFSET}">' + ''.join(mark('#1C1C1C', gid='inapp')) + '</g>\n</svg>\n')
subprocess.run(['rsvg-convert', '-w', '920', '-h', '400', inapp, '-o', os.path.join(HERE, 'inapp-light.png')], check=True)
print('✅ round3 rendered')
