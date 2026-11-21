#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = ["numpy==2.3.4", "pillow==12.0.0", "scipy==1.16.3"]
# ///
"""brandkit: shared math and output for logo render rounds (round 8 onward; older rounds stay as history).

Use from a round script (docs/design/brand/explorations/roundN/render.py), run with `uv run --script render.py`:

    #!/usr/bin/env -S uv run --script
    # /// script
    # requires-python = ">=3.13"
    # dependencies = ["numpy==2.3.4", "pillow==12.0.0", "scipy==1.16.3"]
    # ///
    import sys
    from pathlib import Path
    sys.path.insert(0, str(next(p for p in Path(__file__).resolve().parents if (p / "scripts/brandkit.py").exists()) / "scripts"))
    import brandkit as bk
    lat = bk.hex_lattice(x0, x1, y0, y1, pitch)                    # the ordered end state
    pos = bk.match(lat, bk.blue_noise(box, 0.75 * pitch, seed=8))  # its random start, one point per cell
    pts = bk.progressive_blue_noise(n, box, d_min, seed=8)          # stochastic screens: every prefix evenly spread
    pos = pos * (1 - w) + lat * w                                  # w = bk.ease_out(...) along the axis
    k, rho, L = bk.mark_shape(coverage, pitch)                    # dots -> rounded hexagons (walls >= WALL) -> web retreat
    bk.raster("card-1024.png", lat, pos, k, rho, L, pitch, inside, bg, fg)   # the full closing needs raster()
    # bk.marks()/bk.svg() still draw the rounded-hexagon stage as SVG paths (capped at closing_c2(pitch))

All lengths are px of a 1024 tile. Every function raises (not prints) on the bug classes seen in past rounds:
unsorted np.interp x-points, and lattice cells silently dropped by the random-to-lattice matching.
`uv run scripts/brandkit.py --selftest` checks them, and that a synthetic ramp built here PASSES
scripts/design-review.py.
"""
import math, subprocess, sys, tempfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy.optimize import linear_sum_assignment
from scipy.spatial.distance import cdist
from scipy.stats import qmc

SQ3 = math.sqrt(3)


# ---------------------------------------------------------------- randomness and point sets
def rng(seed):
    """The one PRNG: numpy's PCG64. Same seed -> same output on every machine."""
    return np.random.default_rng(seed)


def blue_noise(box, rmin, seed):
    """Poisson-disc points (Bridson, scipy.stats.qmc) with min distance rmin in box = (x0, x1, y0, y1)."""
    x0, x1, y0, y1 = box
    side = max(x1 - x0, y1 - y0)                   # sample a square in unit space so rmin stays isotropic
    pts = qmc.PoissonDisk(2, radius=rmin / side, rng=rng(seed)).fill_space() * side + (x0, y0)
    return pts[(pts[:, 0] < x1) & (pts[:, 1] < y1)]


def progressive_blue_noise(n, rect, d_min, seed):
    """Up to n points in rect = (x0, x1, y0, y1), at least d_min apart, ranked so that every prefix is evenly spread
    (progressive blue noise). A Bridson set at d_min / 1.06 (blue_noise), then pairs closer than d_min are pushed
    apart until none is (a few dozen vectorised passes): ~0.68 points per d_min^2, where plain Bridson holds ~0.60
    (measured; |psi6| stays ~0.42, blue noise, not a lattice). Then greedy farthest-point ranking: each next point is
    the one farthest from those already ranked. n is a cap; len(result) is the real count. Rank = row order: show
    point i where i / len(points) < density(x) / max density. ~0.6 s for 2,000 points."""
    from scipy.spatial import cKDTree
    x0, x1, y0, y1 = rect
    pts = blue_noise(rect, d_min / 1.06, seed)
    for _ in range(500):
        pr = np.array(sorted(cKDTree(pts).query_pairs(d_min - 1e-6)))
        if not len(pr):
            break
        v = pts[pr[:, 1]] - pts[pr[:, 0]]
        L = np.hypot(*v.T)[:, None]
        push = (d_min - L) / 2 * 1.05 * v / np.maximum(L, 1e-9)
        dp = np.zeros_like(pts)
        np.add.at(dp, pr[:, 0], -push); np.add.at(dp, pr[:, 1], push)
        pts = np.column_stack([np.clip(pts[:, 0] + dp[:, 0], x0, x1 - 1e-6), np.clip(pts[:, 1] + dp[:, 1], y0, y1 - 1e-6)])
    else:
        raise ValueError(f"progressive_blue_noise: pairs still closer than d_min = {d_min} after 500 passes")
    n = min(n, len(pts))
    order, md, j = np.empty(n, int), np.full(len(pts), np.inf), int(rng(seed).integers(len(pts)))
    for k in range(n):
        order[k] = j
        md = np.minimum(md, ((pts - pts[j]) ** 2).sum(axis=1))
        j = int(np.argmax(md))
    return pts[order]


def hex_lattice(x0, x1, y0, y1, pitch):
    """Hex lattice in vertical columns (nearest neighbours `pitch` apart), columns every pitch*sqrt(3)/2
    from x1 leftward (so a column sits on the solid edge), odd columns shifted by pitch/2. Covers the box
    plus one pitch of margin. Its Voronoi cells are flat-top hexagons of apothem pitch/2 (hexagon())."""
    dx = pitch * SQ3 / 2
    return np.array([(x, y) for i, x in enumerate(np.arange(x1, x0 - pitch, -dx))
                     for y in np.arange(y0 - pitch + (pitch / 2) * (i % 2), y1 + pitch, pitch)])


def match(lattice, points):
    """One-to-one: returns start[i] = the point matched to lattice cell i, minimising the total squared distance
    (optimal transport: lerp(start, lattice, w) never brings two dots closer than ab/sqrt(a^2 + b^2) for
    spacings a, b at the two ends; plain distance lets paths converge and dots touch). Raises if a cell would be left without a point (give blue_noise a bigger box or a smaller rmin)."""
    if len(points) < len(lattice):
        raise ValueError(f"match: {len(lattice)} lattice cells but only {len(points)} points; "
                         "enlarge the blue-noise box or lower rmin")
    li, pi = linear_sum_assignment(cdist(lattice, points, "sqeuclidean"))
    if len(li) != len(lattice) or len(set(pi)) != len(pi):
        raise AssertionError("match: lattice cells left unmatched")
    start = np.empty_like(lattice, dtype=float)
    start[li] = points[pi]
    return start


# ---------------------------------------------------------------- 1-D shaping
def interp(x, xp, fp):
    """np.interp that raises unless xp is strictly increasing (np.interp is silently wrong otherwise)."""
    xp = np.asarray(xp, dtype=float)
    if xp.ndim != 1 or len(xp) < 2 or not np.all(np.diff(xp) > 0):
        raise ValueError("interp: xp must be 1-D and strictly increasing")
    return np.interp(x, xp, fp)


def smoothstep(t):
    t = np.clip(t, 0, 1)
    return t * t * (3 - 2 * t)


def ease_out(t):
    """1 - (1 - t)^2: use for the order weight w(x) (|psi6| only climbs near the site, so it rises evenly)."""
    return 1 - (1 - np.clip(t, 0, 1)) ** 2


# ---------------------------------------------------------------- coverage -> marks
# One mark per lattice cell, of area cov * cell: a round dot below C1, then a rounded hexagon (flat-top hexagon of
# apothem k, Minkowski-summed with a disc of radius rho) whose extent k + rho grows to pitch/2 while rho shrinks
# to 0, so the marks become the lattice's own cells and close into solid. This replaced the AM-halftone
# inversion (dots -> paper holes at 50%): a flip in one column is a seam and fails design-review's polarity mix.
C1 = 0.35


def cell_area(pitch):
    return SQ3 / 2 * pitch * pitch               # Voronoi cell of hex_lattice


def dot_radius(cov, pitch):
    """Radius of a round dot covering `cov` of its hex cell."""
    return np.sqrt(np.clip(cov, 0, 1) * cell_area(pitch) / math.pi)


def mark_area(k, rho):
    return 2 * SQ3 * k * k + 4 * SQ3 * k * rho + math.pi * rho * rho


WALL = 2.2                                       # px: paper walls never get thinner than this (design-review hairlines)


def _closing(pitch):
    """Tables for one pitch: rounded-hexagon extent/rounding up to C2 (walls = WALL), then the paper web's
    retreat length L into the cell corners (coverage C2 -> 1). Same method as design-review's synthetic_ramp."""
    e1, e2 = float(dot_radius(C1, pitch)), (pitch - WALL) / 2
    es = np.linspace(e1, e2, 600)                             # extent k + rho
    rhos = e1 * (e2 - es) / (e2 - e1)
    covs = mark_area(es - rhos, rhos) / cell_area(pitch)       # rises C1 -> C2
    Rc = pitch / SQ3                                           # cell circumradius
    g = (np.mgrid[0:300, 0:300].reshape(2, -1).T + 0.5) / 300 * [Rc, pitch / 2]   # one quarter cell
    g = g[_hexnorm(g) <= pitch / 2]
    band = pitch / 2 - _hexnorm(g) < WALL / 2
    Ls = np.linspace(0, math.hypot(Rc / 2, WALL / 2) + 0.01, 300)
    covL = np.array([1 - (band & (_corner_d(g, pitch) < L)).mean() for L in Ls])   # falls 1 -> C2 as L grows
    keep = np.concatenate([[True], np.diff(covL) < 0])        # strictly decreasing for interp
    return es, rhos, covs, float(covs[-1]), Ls[keep], covL[keep]


def _hexnorm(q):
    """Flat-top hexagon 'radius' of points q (abs coords): the apothem of the hexagon through q."""
    return np.maximum(q[..., 1], 0.866025404 * q[..., 0] + 0.5 * q[..., 1])


def _corner_d(q, pitch):
    Rc = pitch / SQ3
    corners = np.array([[Rc, 0], [Rc / 2, pitch / 2]])
    return np.min(np.linalg.norm(q[..., None, :] - corners, axis=-1), axis=-1)


def mark_shape(cov, pitch):
    """(k, rho, L) per cell for coverage `cov`: below C1 a dot (k = 0); up to C2 a rounded hexagon (k, rho) whose
    walls stop at WALL; above C2 the cell is ink except a WALL-wide paper web within L of its corners (L -> 0 at
    cov 1). L = -1 means "no web" (cov < C2)."""
    es, rhos, covs, C2, Ls, covL = _closing(pitch)
    cov = np.clip(np.asarray(cov, dtype=float), 0, 1)
    e = np.where(cov < C1, dot_radius(cov, pitch), interp(np.minimum(cov, C2), covs, es))
    rho = np.where(cov < C1, dot_radius(cov, pitch), interp(np.minimum(cov, C2), covs, rhos))
    L = np.where(cov >= C2, interp(-cov, -covL, Ls), -1.0)        # covL falls with L
    return np.where(cov < C1, 0.0, e - rho), rho, L


def mark(cov, pitch):
    """(k, rho) of the rounded-hexagon mark for coverage `cov`, capped at C2 (walls of WALL px). Above C2 the
    closing is the paper web of mark_shape() / raster(), which SVG paths can't express."""
    k, rho, _ = mark_shape(cov, pitch)
    return k, rho


def closing_c2(pitch):
    """Coverage at which marks stop growing (walls = WALL) and the web retreat starts."""
    return _closing(pitch)[3]


def raster(path, lattice, pos, k, rho, L, pitch, inside, bg, fg, size=1024, ss=4):
    """Rasterise marks to a PNG (supersampled ss×). Mark i is a rounded hexagon (k[i], rho[i]) at pos[i] (pixels
    go to the nearest mark position, so a displaced dot is never cut), or, where L[i] >= 0, its lattice Voronoi
    cell in solid ink minus the paper web (WALL wide, within L of the corners). inside(x, y) -> bool mask: the silhouette (e.g. a card); ink is limited to it. Returns the path."""
    from scipy.spatial import cKDTree
    ys, xs = (np.mgrid[0:size * ss, 0:size * ss] + 0.5) / ss
    mask = inside(xs, ys)
    p = np.column_stack([xs[mask], ys[mask]])
    cl = cKDTree(lattice).query(p)[1]                          # web stage: the lattice's own Voronoi cell
    late = L[cl] >= 0
    # Dot stage: the nearest mark *position* (a dot far from its site must not be cut by its site's cell).
    early = np.nonzero(L < 0)[0]
    cm = early[cKDTree(pos[early]).query(p)[1]] if len(early) else cl
    q = np.abs(p - pos[cm])                                    # iq's flat-top hexagon SDF, apothem k
    kk = k[cm]
    d = np.minimum(-0.866025404 * q[:, 0] + 0.5 * q[:, 1], 0)
    hx, hy = q[:, 0] + 2 * d * 0.866025404, q[:, 1] - 2 * d * 0.5
    hx, hy = hx - np.clip(hx, -0.577350269 * kk, 0.577350269 * kk), hy - kk
    in_mark = (np.hypot(hx, hy) * np.sign(hy) - rho[cm] <= 0) & (k[cm] + rho[cm] > 0)
    ql = np.abs(p - lattice[cl])
    web = (pitch / 2 - _hexnorm(ql) < WALL / 2) & (_corner_d(ql, pitch) < L[cl])
    ink = np.zeros(xs.shape, dtype=bool)
    ink[mask] = np.where(late, ~web, in_mark)
    cov = ink.reshape(size, ss, size, ss).mean(axis=(1, 3))[..., None]
    hexrgb = lambda h: np.array([int(h[i:i + 2], 16) for i in (1, 3, 5)], dtype=float)
    Image.fromarray((hexrgb(bg) * (1 - cov) + hexrgb(fg) * cov).astype(np.uint8)).save(path)
    return Path(path)


def mark_path(cx, cy, k, rho):
    """SVG path of a mark at (cx, cy): a circle when k = 0, else the rounded flat-top hexagon."""
    if k <= 0:
        return f"M{cx - rho:.2f} {cy:.2f}a{rho:.2f} {rho:.2f} 0 1 0 {2 * rho:.2f} 0a{rho:.2f} {rho:.2f} 0 1 0 {-2 * rho:.2f} 0Z"
    d = []
    for i in range(6):                                         # vertex i at angle 60*i, edge normals at 60*i +- 30
        vx, vy = cx + 2 * k / SQ3 * math.cos(math.radians(60 * i)), cy + 2 * k / SQ3 * math.sin(math.radians(60 * i))
        a0, a1 = math.radians(60 * i - 30), math.radians(60 * i + 30)
        d.append(f"{'M' if i == 0 else 'L'}{vx + rho * math.cos(a0):.2f} {vy + rho * math.sin(a0):.2f}")
        if rho > 0:
            d.append(f"A{rho:.2f} {rho:.2f} 0 0 1 {vx + rho * math.cos(a1):.2f} {vy + rho * math.sin(a1):.2f}")
    return "".join(d) + "Z"


def hexagon(cx, cy, pitch):
    """SVG path of the flat-top hex Voronoi cell of hex_lattice at (cx, cy) (= mark at cov 1)."""
    return mark_path(cx, cy, pitch / 2, 0)


def rounded_rect(x, y, w, h, r):
    """SVG path of a rounded rectangle (for silhouettes and clip paths)."""
    return (f"M{x + r} {y}H{x + w - r}A{r} {r} 0 0 1 {x + w} {y + r}V{y + h - r}A{r} {r} 0 0 1 {x + w - r} {y + h}"
            f"H{x + r}A{r} {r} 0 0 1 {x} {y + h - r}V{y + r}A{r} {r} 0 0 1 {x + r} {y}Z")


# ---------------------------------------------------------------- output
def svg(path, size, bg, fg, circles=(), paths=(), clip=None):
    """Write an SVG. circles: (x, y, r) or (x, y, r, fill); paths: d strings or (d, fill); fill defaults to fg.
    clip: a path d string every mark is clipped to (e.g. rounded_rect(...)). Paths are drawn before circles."""
    w, h = (size, size) if np.isscalar(size) else size
    fill = lambda item, n: item[n] if len(item) > n else fg
    body = [f'<path d="{p}" fill="{fg}"/>' if isinstance(p, str) else f'<path d="{p[0]}" fill="{p[1]}"/>' for p in paths]
    body += [f'<circle cx="{c[0]:.2f}" cy="{c[1]:.2f}" r="{c[2]:.2f}" fill="{fill(c, 3)}"/>' for c in circles if c[2] > 0]
    defs = f'<defs><clipPath id="clip"><path d="{clip}"/></clipPath></defs>' if clip else ""
    group = f'<g clip-path="url(#clip)">' if clip else "<g>"
    Path(path).write_text(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}">'
                          f'{defs}<rect width="{w}" height="{h}" fill="{bg}"/>{group}{"".join(body)}</g></svg>')
    return Path(path)


def png(svg_path, sizes=(1024, 180, 58, 29)):
    """Render an SVG to <stem>-<size>.png next to it with rsvg-convert (brew install librsvg)."""
    svg_path = Path(svg_path)
    outs = []
    for s in sizes:
        out = svg_path.with_name(f"{svg_path.stem}-{s}.png")
        subprocess.run(["rsvg-convert", "-w", str(s), "-h", str(s), str(svg_path), "-o", str(out)], check=True)
        outs.append(out)
    return outs


def contact_sheet(pngs, out, cell=240, cols=4, bg="#2A2C33", labels=True):
    """Grid of images (each fitted into a cell x cell square), file stem under each when labels."""
    pngs = [Path(p) for p in pngs]
    rows = math.ceil(len(pngs) / cols)
    lab = 18 if labels else 0
    sheet = Image.new("RGB", (cols * (cell + 16) + 16, rows * (cell + lab + 16) + 16), bg)
    d = ImageDraw.Draw(sheet)
    for i, p in enumerate(pngs):
        im = Image.open(p).convert("RGB")
        im.thumbnail((cell, cell), Image.LANCZOS)
        x, y = 16 + (i % cols) * (cell + 16), 16 + (i // cols) * (cell + lab + 16)
        sheet.paste(im, (x + (cell - im.width) // 2, y + (cell - im.height) // 2))
        if labels:
            d.text((x, y + cell + 3), p.stem, fill="#E6E6E6")
    sheet.save(out)
    return Path(out)


# ---------------------------------------------------------------- reference ramp + selftest
def marks(lattice, pos, cov, pitch):
    """SVG paths of the marks: cell i's mark (coverage cov[i], capped at closing_c2) drawn at pos[i]."""
    k, rho = mark(cov, pitch)
    return [mark_path(x, y, kk, rr) for (x, y), kk, rr in zip(pos, k, rho) if kk + rr > 0]


def card_sd(x, y, cx, cy, w, h, r):
    """Signed distance to a rounded rectangle (negative inside)."""
    qx, qy = np.abs(x - cx) - (w / 2 - r), np.abs(y - cy) - (h / 2 - r)
    return np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - r


def synthetic_card(out_png, seed=7, pitch=12.0, bg="#F9FAF5", fg="#1C1C1C", on_site=0.55):
    """Reference card (design-review.py --make-synthetic method): blue noise matched to a hex lattice, dots
    easing onto their sites by coverage `on_site`, marks growing into rounded hexagons until the walls are WALL,
    then the paper web retreating into the corners (mark_shape + raster). Returns the PNG path."""
    W, H, R, CX, CY = 620, 400, 64, 490, 512
    XL, XS, top = CX - W / 2, CX - W / 2 + 0.72 * W, CY - H / 2
    cov = lambda x: np.where(x >= XS, 1.0, 0.04 + 0.96 * smoothstep((x - XL) / (XS - XL)))
    gx = np.linspace(XL, XS, 4000)
    xh = gx[np.argmax(cov(gx) >= on_site)]
    lat = hex_lattice(XL, CX + W / 2, top, top + H, pitch)
    zone = lat[:, 0] < xh + pitch                            # cells that move
    noise = blue_noise((XL - 2 * pitch, xh + 2 * pitch, top - 2 * pitch, top + H + 2 * pitch), 0.75 * pitch, seed)
    pos = lat.copy()
    w = ease_out((lat[zone, 0] - XL) / (xh - XL))[:, None]
    pos[zone] = match(lat[zone], noise) * (1 - w) + lat[zone] * w
    c = cov(lat[:, 0])
    k, rho, L = mark_shape(c, pitch)
    sd = card_sd(pos[:, 0], pos[:, 1], CX, CY, W, H, R)
    drop = (L < 0) & (sd > -(k + rho)) & (c < 0.65)          # dots stay whole inside the card
    k, rho = np.where(drop, 0, k), np.where(drop, 0, rho)
    inside = lambda x, y: card_sd(x, y, CX, CY, W, H, R) <= 0
    return raster(out_png, lat, pos, k, rho, L, pitch, inside, bg, fg)


def _selftest():
    import time
    from scipy.ndimage import gaussian_filter
    t0 = time.time()
    tmp = Path(tempfile.mkdtemp(prefix="brandkit-"))
    # (a) unsorted xp raises
    for bad in ([0, 2, 1], [0, 1, 1], [1]):
        try:
            interp(0.5, bad, np.zeros(len(bad)))
            raise AssertionError(f"interp accepted xp={bad}")
        except ValueError:
            pass
    assert interp(0.5, [0, 1], [0, 2]) == 1.0
    # (b) match covers every lattice cell, one-to-one; too few points raises
    lat = hex_lattice(0, 200, 0, 200, 12)
    pts = blue_noise((-30, 230, -30, 230), 0.8 * 12, seed=1)
    start = match(lat, pts)
    assert start.shape == lat.shape and not np.isnan(start).any()
    assert len({tuple(p) for p in start}) == len(lat), "two cells share a point"
    assert all(any(np.all(p == q) for q in pts) for p in start[:50]), "matched point not from the input"
    try:
        match(lat, pts[: len(lat) - 1]); raise AssertionError("match accepted too few points")
    except ValueError:
        pass
    # (c) same seed -> identical output (points and SVG bytes); different seed differs
    assert np.array_equal(blue_noise((0, 300, 0, 100), 9, 3), blue_noise((0, 300, 0, 100), 9, 3))
    assert not np.array_equal(blue_noise((0, 300, 0, 100), 9, 3), blue_noise((0, 300, 0, 100), 9, 4))
    a, b = synthetic_card(tmp / "a.png", seed=5), synthetic_card(tmp / "b.png", seed=5)
    assert a.read_bytes() == b.read_bytes()
    # (d) mark coverage: analytic round trip, then rendered, monotonic 0 -> 1, step <= 0.08 per 8 px column
    C2 = closing_c2(12)
    c = np.linspace(0, C2, 101)
    assert np.allclose(mark_area(*mark(c, 12)) / cell_area(12), c)
    lat = hex_lattice(64, 1000, 300, 724, 12)        # ramp 112 -> 912, solid to 1000
    ht = raster(tmp / "ht.png", lat, lat, *mark_shape(smoothstep((lat[:, 0] - 112) / 800), 12.0), 12.0,
                lambda x, y: (x >= 64) & (x <= 1000) & (y >= 300) & (y <= 724), "#FFFFFF", "#000000")
    ink = 1 - np.asarray(Image.open(ht).convert("L"), dtype=float) / 255
    prof = gaussian_filter(ink, 12)[400:624, 112:912].mean(axis=0)
    cols = prof[: len(prof) // 8 * 8].reshape(-1, 8).mean(axis=1)
    steps = np.diff(cols)
    assert cols[0] < 0.05 and cols[-1] > 0.95, f"ramp ends {cols[0]:.3f} -> {cols[-1]:.3f}"
    assert steps.min() > -0.005, f"coverage falls by {-steps.min():.3f}"
    assert steps.max() <= 0.08, f"coverage step {steps.max():.3f} > 0.08"
    # (f) progressive blue noise: fast, min distance held, every prefix evenly spread, same seed -> same points
    from scipy.spatial import cKDTree
    t1 = time.time()
    pb = progressive_blue_noise(2132, (170, 810, 267, 757), 10.0, seed=31)      # round 9's request (~2,100 fit)
    dt = time.time() - t1
    assert dt < 1.0, f"progressive_blue_noise took {dt:.2f} s for 2132 points"
    assert cKDTree(pb).query(pb, k=2)[0][:, 1].min() >= 10.0 - 1e-5, "points closer than d_min"
    for f in (0.05, 0.25, 1.0):
        q = pb[: int(f * len(pb))]
        nn = cKDTree(q).query(q, k=2)[0][:, 1]
        assert 1 - nn.std() / nn.mean() >= 0.75, f"prefix {f:.0%} not even: 1 - CV(NN) {1 - nn.std() / nn.mean():.2f}"
    assert np.array_equal(pb, progressive_blue_noise(2132, (170, 810, 267, 757), 10.0, seed=31))
    # (e) the synthetic card PASSES design-review.py
    card = synthetic_card(tmp / "card.png")
    res = subprocess.run(["uv", "run", "--script", str(Path(__file__).with_name("design-review.py")), str(card),
                          "--out", str(tmp / "card-review.png")], capture_output=True, text=True)
    assert res.returncode == 0, f"design-review FAILS the synthetic card:\n{res.stdout}{res.stderr}"
    print(f"brandkit selftest: PASS (a-f) in {time.time() - t0:.1f} s; max column step {steps.max():.3f}; files in {tmp}")


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        _selftest()
    else:
        sys.exit(__doc__ + "\nusage: uv run scripts/brandkit.py --selftest")
