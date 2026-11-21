#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = [
#   "numpy==2.3.4",
#   "pillow==12.0.0",
#   "scipy==1.16.3",
#   "matplotlib==3.10.7",
# ]
# ///
"""Measured design review for logo / icon renders (design-critic runs it on every proposal).

    uv run scripts/design-review.py <render-1024.png|.svg>... [--home] [--axis x|y] [--region x0,y0,x1,y1] [--out sheet.png]
    uv run scripts/design-review.py card-light-1024.png card-dark-1024.png --watch   # re-run on every save
    uv run scripts/design-review.py --make-synthetic out.png     # a smooth reference ramp that must PASS

Prints PASS/FAIL per metric (value vs limit, and WHERE: `at x 385, y 535 (band 5)` in the render's own 1024 px
coordinates; band = 32 px band counted from where the ink starts rising) and writes an annotated sheet (render,
curves under it on the same x axis, failing spots in red and failing marks circled, 58/29 px previews).
Exit code 1 on any FAIL. Several renders: each is reviewed. `--watch`: re-runs when a render's file changes
(polls mtime) and prints one PASS/FAIL line per run with the failing metrics and their spots.
All lengths are in px of a 1024 tile; other sizes are resampled to 1024 first. SVGs go through rsvg-convert.

Marks are dots (small ink components: SVG circles or PNG connected components) AND holes (small paper
components sitting in ink: the inverted image). An AM halftone flips from ink dots to paper holes at 50%
coverage; both halves are marks, stitched into one point set along the axis. Local coverage = the grain-blurred
coverage profile at the mark's x. Where it is >= TOUCH_OK_COVERAGE (0.65) marks may touch and close into solid,
so marks there are not analysed (the coverage profile judges that zone; the header line counts them).

What it measures, along the transition axis (default x; the direction of rising ink is auto-detected):
1. Coverage profile at 1024: ink per 8 px column over the middle 60% of the mark's height (avoids rounded
   corners), after a Gaussian blur at the grain scale (sigma = median mark nearest-neighbour distance), so a
   regular lattice doesn't alias against the 8 px columns. Max |step|, max drawdown (fall below the running
   max = a reversal), max |second difference| (a slope change = a visible seam).
2. The same on the 58 px and 29 px icons (area downsample + 0.7 px blur: roughly what the eye integrates).
3. Order along the axis, per 32 px band of marks (dots and holes together): hexatic order |psi6| over
   Delaunay neighbours, and regularity 1 - CV(nearest-neighbour distance). Both must rise without an
   adjacent-band step or a drop: "random, then suddenly a lattice" fails here.
4. Seam (a straight line across the axis where the pattern changes, even if coverage is smooth):
   - polarity mix: if both dots and holes exist, the zone where they mix (95th-percentile dot x minus
     5th-percentile hole x) must span >= POLARITY_MIN_MIX pitches; a dots -> holes flip in one column is a
     seam, however well its coverage matches.
   - flip continuity: the last dots and the first holes (2 pitches either side of the flip, where the hole
     fraction in a one-pitch window reaches 1/2) must match: max of |d pitch|/pitch, |d r|/max r and
     |d |psi6|| <= FLIP_STEP_MAX. The negative must continue the positive.
5. Geometry: merged (elongated) marks and the smallest gap / (r1+r2), both polarities: mark to mark along
   Delaunay edges (sub-pixel on the centre line; r = each mark's own extent along it, so facing hexagons
   use their apothem), and mark to the rest of its colour (a dot touching the solid or the ink between
   holes, a hole opening into the paper; pixel distance). Optical centre (midpoint of the bbox centre and
   the ink centroid) vs tile centre; mark size spread inside each band (one size per position) and size
   steps between bands.

The ramp analysed runs from the first column with ink to the first column at the solid plateau (97% of the
max), so the joint into the solid is always inside the checked range.

Synthetic reference (`--make-synthetic`, function `synthetic_ramp`), the generation idea for design-lead:
blue-noise points (Bridson Poisson-disc) matched one-to-one to a hex lattice of the same density
(linear_sum_assignment), each dot at lerp(random, lattice, w(x)) with w easing out (|psi6| only climbs
once dots are within ~0.2 pitch of their site, so a linear or smoothstep w bunches the order rise at the
end) and reaching the site by c = 0.55 (later, near-random big marks break the gap rule); one coverage
function c(x) drives one ink mark per cell: a dot, then a rounded hexagon growing into the cell, closing into
solid. Coverage is continuous 0 -> 1 with no flip, no gap column and no jump into the solid. (The earlier
AM-halftone version, dots inverting to holes in one column at 50%, fails `seam: polarity mix`.)
"""
import argparse, json, math, os, re, subprocess, sys, tempfile, urllib.request
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage
from scipy.optimize import linear_sum_assignment
from scipy.spatial import Delaunay, cKDTree

# ---- Thresholds (calibrated 2026-11-21 on round6/pass5 and round7/render_flip.py's flip-*-1024.png, which must
# FAIL, and --make-synthetic (12 of 12 seeds) and round7 card-*-1024.png, which PASS; revisit after two rounds). Units: coverage fraction 0..1 per column of the given size.
TILE = 1024
COL_PX = 8                      # profile column width at 1024
ROW_BAND = 0.6                  # middle fraction of the mark's height used for profiles
PLATEAU = 0.97                  # the ramp ends where coverage first reaches this fraction of its max
PROFILE_LIMITS = {              # size: (max |step|, max drawdown, max |second difference|) per column
    1024: (0.08, 0.03, 0.03),   # per 8 px column, grain-scale blur
    58:   (0.20, 0.04, 0.12),   # per icon pixel (one pixel = 17.7 px of the 1024 render)
    29:   (0.25, 0.04, 0.12),   # per icon pixel (35 px of the 1024 render)
}
PERCEIVED_BLUR = 0.7            # Gaussian sigma in icon pixels after the area downsample (eye + display)
ORDER_BAND_PX = 32              # band width for order / size statistics
ORDER_MIN_DOTS = 10             # bands with fewer marks are skipped
ORDER_MAX_STEP = 0.25           # max change of |psi6| or 1-CV(NN) between adjacent bands (band noise ~0.05)
ORDER_DRAWDOWN = 0.08           # max fall of an order measure below its running max (order must rise)
MIN_GAP_RATIO = 0.20            # mark gap >= 20% of the pair's summed radii (round 6 built with 25%)
MERGED_ASPECT = 1.4             # a mark blob this elongated (second moments) is two touching marks
TOUCH_OK_COVERAGE = 0.65        # touching / merging is allowed only where local coverage >= this (marks closing
                                # into solid). Why 0.65: on a hex lattice of pitch A, equal marks that keep the gap
                                # rule (gap >= 0.2*(r1+r2)) top out at a pure hexagon of apothem A/2.4 ~ 0.413*A, which
                                # covers (0.413/0.5)^2 ~ 0.68 of its cell; a closing band above ~0.68 can never pass
                                # the gap rule, so the exemption must start just below it.
POLARITY_MIN_MIX = 4.0          # dots -> holes: the zone where both polarities mix must span >= 4 pitches, else
                                # the flip is a straight front (a seam), whatever the coverage does
FLIP_STEP_MAX = 0.15            # last dots vs first holes (2 pitches each side of the flip): max of |d pitch|/pitch,
                                # |d radius|/max radius and |d |psi6||; the negative must continue the positive
CENTROID_TOL = 0.03             # optical centre (midpoint of bbox centre and ink centroid) within 3% of the
                                # tile (31 px) of the tile centre, per axis
SIZE_CV_MAX = 0.20              # mark radius CV inside one band (one size per position)
SIZE_STEP_MAX = 0.20            # change of median mark radius between adjacent bands, as a fraction of the max

ICON_IDS = [1110145109, 1108187841, 1108185179, 1069512882, 1584215688, 915056765]   # Notes, Reminders,
# Calendar, Stocks, Clock, Maps: Apple's own apps via the public iTunes lookup API (no personal data).
ICON_CACHE = Path(__file__).resolve().parent.parent / "docs/design/reference/home-icons"   # gitignored


# ---------------------------------------------------------------- loading
def load(path, axis):
    path = Path(path)
    circles = None
    if path.suffix.lower() == ".svg":
        circles = svg_circles(path.read_text())
        png = Path(tempfile.mkdtemp()) / "render.png"
        subprocess.run(["rsvg-convert", "-w", str(TILE), "-h", str(TILE), str(path), "-o", str(png)], check=True)
        path = png
    img = Image.open(path).convert("RGB")
    if img.size != (TILE, TILE):
        img = img.resize((TILE, TILE), Image.LANCZOS)
    rgb = np.asarray(img, dtype=float) / 255
    if axis == "y":
        rgb = rgb.transpose(1, 0, 2)
        if circles is not None:
            circles = circles[:, [1, 0, 2]]
    return img, rgb, circles


def svg_circles(text):
    """Circles (cx, cy, r) in 1024 px, or None if the SVG uses transforms (then PNG blobs are used)."""
    if "transform" in text:
        return None
    vb = re.search(r'viewBox="([\d.\s-]+)"', text)
    scale = TILE / float(vb.group(1).split()[2]) if vb else 1.0
    out = []
    for tag in re.findall(r"<circle\b[^>]*>", text):
        a = dict(re.findall(r'(\w+)="([^"]*)"', tag))
        out.append([float(a.get("cx", 0)) * scale, float(a.get("cy", 0)) * scale, float(a.get("r", 0)) * scale])
    return np.array(out) if out else None


def ink_map(rgb):
    """0 = background colour (from the corners), 1 = ink colour (the colour furthest from it)."""
    c = 16
    bg = np.median(np.concatenate([rgb[:c, :c], rgb[:c, -c:], rgb[-c:, :c], rgb[-c:, -c:]]).reshape(-1, 3), axis=0)
    d = np.linalg.norm(rgb - bg, axis=2)
    ink = np.median(rgb[d >= np.percentile(d, 99.9)], axis=0)
    v = ink - bg
    return np.clip(((rgb - bg) @ v) / (v @ v), 0, 1), bg, ink


# ---------------------------------------------------------------- dots
def detect_marks(ink, circles):
    """Marks of both polarities. Returns (marks[n, 5] = x, y, r, polarity (+1 dot, -1 hole), elongated 0/1;
    labels {+1: ink labels, -1: paper labels}; mark label ids {+1: ids, -1: ids} in the same order as marks).
    Big shapes (the solid, the paper ground) are not marks."""
    out, labels, ids = [], {}, {}
    for pol, mask in ((1, ink > 0.5), (-1, ink <= 0.5)):
        lab, n = ndimage.label(mask)
        idx = np.arange(1, n + 1)
        areas = ndimage.sum(np.ones_like(ink), lab, idx)
        small = (areas >= 3) & (areas < 0.002 * TILE * TILE)
        if pol == -1:                                  # a hole sits in ink: the ring 2 px around it is mostly ink
            for i, sl in enumerate(ndimage.find_objects(lab)):
                if not small[i]:
                    continue
                sl = tuple(slice(max(a.start - 3, 0), a.stop + 3) for a in sl)
                own = lab[sl] == i + 1
                ring = ndimage.binary_dilation(own, iterations=2) & ~ndimage.binary_dilation(own, iterations=1)
                small[i] = ring.any() and ink[sl][ring].mean() > 0.5
        elong = np.zeros(n, bool)
        for i, sl in enumerate(ndimage.find_objects(lab)):
            if small[i] and areas[i] > 12:
                pts = np.argwhere(lab[sl] == i + 1).astype(float)
                ev = np.linalg.eigvalsh(np.cov(pts.T))
                elong[i] = math.sqrt(ev[1] / max(ev[0], 1e-9)) > MERGED_ASPECT
        keep = idx[small]
        labels[pol], ids[pol] = lab, keep
        if not len(keep):
            continue
        cy, cx = np.array(ndimage.center_of_mass(mask, lab, keep)).T.reshape(2, -1)
        out.append(np.column_stack([cx, cy, np.sqrt(areas[small] / math.pi), np.full(len(keep), pol), elong[small]]))
    marks = np.concatenate(out) if out else np.zeros((0, 5))
    if circles is not None:                            # exact dot geometry from the SVG (PNG elongation kept)
        dots = circles[circles[:, 2] < 0.05 * TILE]
        tree = cKDTree(dots[:, :2])
        d = marks[:, 3] > 0
        if d.any():
            j = tree.query(marks[d, :2])[1]
            marks[d, :3] = dots[j]
    return marks, labels, ids


def mark_gaps(ink, marks, labels, ids, cov):
    """Smallest gap / (r1 + r2) per mark (np.inf if none measured), exempt where local coverage cov(x) >=
    TOUCH_OK_COVERAGE. Mark to mark: along Delaunay edges between marks of the same polarity, sub-pixel on the
    centre line, r1 and r2 = each mark's extent along that line. Mark to the rest of its colour (the solid, the ink web between holes, the paper ground):
    pixel distance transform, against a partner of the same radius."""
    ratio = np.full(len(marks), np.inf)
    for pol in (1, -1):
        sel = np.nonzero(marks[:, 3] == pol)[0]
        if not len(sel):
            continue
        m = marks[sel]
        e = np.zeros((0, 2), int)
        if len(m) >= 4:
            tri = delaunay(m[:, :2])
            e = np.unique(np.sort(np.concatenate([tri.simplices[:, [0, 1]], tri.simplices[:, [1, 2]],
                                                  tri.simplices[:, [0, 2]]]), axis=1), axis=0)
            a, b = m[e[:, 0], :2], m[e[:, 1], :2]
            rs = m[e[:, 0], 2] + m[e[:, 1], 2]
            L = np.hypot(*(b - a).T)
            e, a, b, rs, L = e[L < 3 * rs], a[L < 3 * rs], b[L < 3 * rs], rs[L < 3 * rs], L[L < 3 * rs]
        if len(e):
            t = np.linspace(0, 1, 257)                             # ~0.05 px steps
            px = a[:, None, :] + (b - a)[:, None, :] * t[None, :, None]
            v = ndimage.map_coordinates(ink, [px[..., 1].ravel(), px[..., 0].ravel()], order=1).reshape(len(e), -1)
            other = (v <= 0.5) if pol == 1 else (v > 0.5)          # the ground between the two marks
            gap = other.mean(axis=1) * L
            # each mark's own extent along the centre line (r for a dot, the apothem for facing hexagons)
            ra = np.argmax(other, axis=1) / (len(t) - 1) * L
            rb = np.argmax(other[:, ::-1], axis=1) / (len(t) - 1) * L
            ext = np.where(other.any(axis=1), ra + rb, rs)
            ok = cov(((a + b) / 2)[:, 0]) >= TOUCH_OK_COVERAGE
            g = np.where(ok, np.inf, gap / ext)
            np.minimum.at(ratio, sel[e[:, 0]], g); np.minimum.at(ratio, sel[e[:, 1]], g)
        lab = labels[pol]
        rest = (lab > 0) & ~np.isin(lab, ids[pol])
        dist = ndimage.distance_transform_edt(~rest)
        d = np.asarray(ndimage.minimum(dist, lab, ids[pol]))
        g = np.maximum(d - 1, 0) / (2 * m[:, 2])
        ok = cov(m[:, 0]) >= TOUCH_OK_COVERAGE
        ratio[sel] = np.minimum(ratio[sel], np.where(ok, np.inf, g))
    return ratio


def delaunay(xy):
    """Default Qhull; joggled (QJ) only when the points are degenerate (e.g. one column of marks)."""
    try:
        return Delaunay(xy)
    except Exception:
        return Delaunay(xy, qhull_options="QJ")


def psi6(xy):
    """Per-point |psi6| over Delaunay neighbours (NaN on the hull or with long edges) and NN distance."""
    nn = cKDTree(xy).query(xy, k=2)[0][:, 1]
    tri = delaunay(xy)
    nbrs = [set() for _ in xy]
    for s in tri.simplices:
        for a in s:
            nbrs[a].update(s)
    hull = set(tri.convex_hull.ravel())
    psi = np.full(len(xy), np.nan)
    med = np.median(nn)
    for i, nb in enumerate(nbrs):
        nb.discard(i)
        nb = np.array(sorted(nb))
        d = xy[nb] - xy[i]
        if i in hull or len(nb) < 4 or np.hypot(*d.T).max() > 3 * med:
            continue
        psi[i] = abs(np.exp(6j * np.arctan2(d[:, 1], d[:, 0])).mean())
    return psi, nn


def order_bands(marks, psi, nn, x0, x1):
    """Per 32 px band of marks (dots and holes together): centre x, mean |psi6|, 1 - CV(NN), median r, CV(r),
    mark count, hole fraction."""
    if len(marks) < 8:
        return np.zeros((0, 7))
    xy = marks[:, :2]
    lo, hi = np.percentile(xy[:, 0], [1, 99])
    lo, hi = max(lo, x0), min(hi, x1)
    rows = []
    for b0 in np.arange(lo, hi, ORDER_BAND_PX):
        sel = (xy[:, 0] >= b0) & (xy[:, 0] < b0 + ORDER_BAND_PX)
        if sel.sum() < ORDER_MIN_DOTS:
            continue
        p = psi[sel][~np.isnan(psi[sel])]
        r = marks[sel, 2]
        rows.append([b0 + ORDER_BAND_PX / 2, p.mean() if len(p) else np.nan,
                     1 - nn[sel].std() / nn[sel].mean(), np.median(r), r.std() / r.mean(), sel.sum(),
                     (marks[sel, 3] < 0).mean()])
    return np.array(rows) if rows else np.zeros((0, 7))


def flip_metrics(marks, psi, nn, pitch):
    """Dots -> holes flip. Returns None (no flip) or (flip x, mix width in pitches, continuity step, note)."""
    dots, holes = marks[:, 3] > 0, marks[:, 3] < 0
    if dots.sum() < ORDER_MIN_DOTS or holes.sum() < ORDER_MIN_DOTS:
        return None
    hi_dot, lo_hole = np.percentile(marks[dots, 0], 95), np.percentile(marks[holes, 0], 5)
    mix = max(hi_dot - lo_hole, 0) / pitch
    # the flip: where the hole fraction, in windows of one pitch, first reaches 1/2
    xs = np.arange(marks[:, 0].min(), marks[:, 0].max(), 1.0)
    frac = np.array([(marks[(marks[:, 0] >= x) & (marks[:, 0] < x + pitch), 3] < 0).mean()
                     if ((marks[:, 0] >= x) & (marks[:, 0] < x + pitch)).any() else 0 for x in xs])
    xf = float(xs[np.argmax(frac >= 0.5)] + pitch / 2)
    side = lambda m: m & (np.abs(marks[:, 0] - xf) <= 2 * pitch)
    d, h = side(dots), side(holes)
    if d.sum() < 3 or h.sum() < 3:
        return xf, mix, 1.0, "fewer than 3 marks on one side of the flip"
    p_d, p_h = np.median(nn[d]), np.median(nn[h])
    r_d, r_h = np.median(marks[d, 2]), np.median(marks[h, 2])
    s_d, s_h = np.nanmean(psi[d]) if (~np.isnan(psi[d])).any() else 0, np.nanmean(psi[h]) if (~np.isnan(psi[h])).any() else 0
    steps = {"pitch": abs(p_d - p_h) / max(p_d, p_h), "radius": abs(r_d - r_h) / max(r_d, r_h), "|psi6|": abs(s_d - s_h)}
    worst = max(steps, key=steps.get)
    note = f"dots->holes: pitch {p_d:.1f}->{p_h:.1f}, r {r_d:.1f}->{r_h:.1f}, |psi6| {s_d:.2f}->{s_h:.2f}; worst {worst}"
    return xf, mix, steps[worst], note


# ---------------------------------------------------------------- profiles
def profile(ink, y0, y1, sigma):
    band = ink[y0:y1]
    if sigma:
        band = ndimage.gaussian_filter(band, sigma)
    return band.mean(axis=0)


def ramp_metrics(p):
    """p: coverage per column. Returns (i0, i1, steps, drawdown, d2) over the ramp i0..i1 inclusive."""
    i0 = int(np.argmax(p > 0.01))
    i1 = int(np.argmax(p >= PLATEAU * p.max()))
    r = p[i0:i1 + 1]
    steps = np.abs(np.diff(r))
    draw = np.maximum.accumulate(r) - r
    d2 = np.abs(np.diff(r, 2)) if len(r) > 2 else np.zeros(1)
    return i0, i1, steps, draw, d2


# ---------------------------------------------------------------- review
def review(path, axis="x", region=None, out=None, home=False, quiet=False):
    """Prints the report (or, quiet, nothing) and writes the sheet. Returns (fail count, results)."""
    img, rgb, circles = load(path, axis)
    ink, bg, inkc = ink_map(rgb)
    if region:
        x0, y0, x1, y1 = region if axis == "x" else (region[1], region[0], region[3], region[2])
    else:
        ys, xs = np.nonzero(ink > 0.5)
        x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    h = y1 - y0
    ry0, ry1 = int(y0 + h * (1 - ROW_BAND) / 2), int(y1 - h * (1 - ROW_BAND) / 2)

    # direction: make "rising" left to right
    raw = profile(ink, ry0, ry1, 0)[x0:x1]
    flip = raw[: len(raw) // 3].mean() > raw[-len(raw) // 3:].mean()
    if flip:
        ink = ink[:, ::-1]
        x0, x1 = TILE - x1, TILE - x0
        if circles is not None:
            circles = circles.copy(); circles[:, 0] = TILE - circles[:, 0]
    marks, labels, ids = detect_marks(ink, circles)
    in_rows = (marks[:, 1] >= y0) & (marks[:, 1] < y1) if len(marks) else np.zeros(0, bool)
    pitch = float(np.median(cKDTree(marks[in_rows, :2]).query(marks[in_rows, :2], k=2)[0][:, 1])) if in_rows.sum() > 8 else 4.0
    sigma = max(4.0, pitch)
    # local coverage = the grain-blurred coverage profile along the axis (middle rows, so the paper around the
    # card's edges doesn't dilute it)
    covp = profile(ink, ry0, ry1, sigma)
    cov = lambda x: covp[np.clip(np.asarray(x).astype(int), 0, TILE - 1)]
    gaps = mark_gaps(ink, marks, labels, ids, cov)
    mcov = cov(marks[:, 0])
    merged_xy = marks[(marks[:, 4] > 0) & (mcov < TOUCH_OK_COVERAGE), :2]
    merged = len(merged_xy)
    closing = int((in_rows & (mcov >= TOUCH_OK_COVERAGE)).sum())   # marks may touch there: coverage judges it
    keep = in_rows & (mcov < TOUCH_OK_COVERAGE)
    marks, gaps = marks[keep], gaps[keep]

    results, curves = [], {}
    # 1. coverage profile at 1024, sampled every 8 px
    full = covp
    cols = np.arange(x0, x1 - COL_PX + 1, COL_PX)
    p = np.array([full[c:c + COL_PX].mean() for c in cols])
    rawc = np.array([profile(ink, ry0, ry1, 0)[c:c + COL_PX].mean() for c in cols])
    curves[1024] = (cols + COL_PX / 2, p, rawc, ramp_metrics(p))
    # 2. perceived at 58 / 29 px
    work = Image.fromarray((np.clip(ink, 0, 1) * 255).astype(np.uint8)).convert("RGB")  # 0 = bg, 255 = ink
    previews = {}
    for size in (58, 29):
        previews[size] = img.resize((size, size), Image.BOX)
        small = np.asarray(work.resize((size, size), Image.BOX), dtype=float)[:, :, 0] / 255
        small = ndimage.gaussian_filter(small, PERCEIVED_BLUR)
        k = TILE / size
        sp = profile(small, int(ry0 / k), max(int(ry0 / k) + 1, int(round(ry1 / k))), 0)
        lo, hi = int(x0 / k), int(math.ceil(x1 / k))
        curves[size] = ((np.arange(lo, hi) + 0.5) * k, sp[lo:hi], None, ramp_metrics(sp[lo:hi]))
    bad_x = []
    for size, (xs_, prof, _, (i0, i1, steps, draw, d2)) in curves.items():
        lim = PROFILE_LIMITS[size]
        unit = "8 px" if size == 1024 else "px"
        for name, arr, limit, off in (("max |step|", steps, lim[0], 0.5), ("max drawdown", draw, lim[1], 0),
                                      ("max |2nd diff|", d2, lim[2], 1)):
            j = int(np.argmax(arr))
            xs_at = float(np.interp(i0 + j + off, np.arange(len(xs_)), xs_))
            ok = arr[j] <= limit
            results.append((f"coverage {size:>4} {name} / {unit}", arr[j], limit, ok, xs_at))
            for jj in np.nonzero(arr > limit)[0]:
                bad_x.append(float(np.interp(i0 + jj + off, np.arange(len(xs_)), xs_)))
    i0, i1 = curves[1024][3][:2]
    ramp = (curves[1024][0][i0] - COL_PX / 2, curves[1024][0][i1] + COL_PX / 2)

    def at(x, y=None):
        """A spot in the analysis frame -> 'at x 385, y 535 (band 5)' in the render's own 1024 px coordinates;
        band = 32 px band counted from the start of the ramp (where ink starts rising)."""
        band = f" (band {int((x - ramp[0]) // ORDER_BAND_PX)})" if ramp[0] <= x < ramp[1] + ORDER_BAND_PX else ""
        xi = x_report(x, flip)
        if y is None:
            return f"at {axis} {xi:.0f}{band}"
        px, py = (xi, y) if axis == "x" else (y, xi)
        return f"at x {px:.0f}, y {py:.0f}{band}"
    bad_pts = []                                       # (x, y) failing marks, circled on the sheet

    results = [(m, v, lim, ok, at(note)) for m, v, lim, ok, note in results]   # coverage spots, now with bands

    # 3. order along the axis
    psi, nn = psi6(marks[:, :2]) if len(marks) >= 8 else (np.zeros(0), np.zeros(0))
    bands = order_bands(marks, psi, nn, ramp[0], ramp[1])
    for col, name in ((1, "order |psi6|"), (2, "order 1-CV(NN)")):
        v = bands[:, col] if len(bands) else np.zeros(0)
        v = v[~np.isnan(v)]
        if len(v) < 2:
            results.append((f"{name} band step", 0, ORDER_MAX_STEP, True, "fewer than 2 mark bands"))
            continue
        bx_ = bands[~np.isnan(bands[:, col]), 0]
        st = np.abs(np.diff(v)); dd = np.maximum.accumulate(v) - v
        j, k = int(np.argmax(st)), int(np.argmax(dd))
        results.append((f"{name} band step", st[j], ORDER_MAX_STEP, st[j] <= ORDER_MAX_STEP,
                        f"{v.min():.2f} -> {v.max():.2f}, {len(v)} bands of {ORDER_BAND_PX} px; worst "
                        + at(bx_[j] + ORDER_BAND_PX / 2)))
        results.append((f"{name} drawdown", dd.max(), ORDER_DRAWDOWN, dd.max() <= ORDER_DRAWDOWN,
                        "must rise; worst " + at(bx_[k])))
        bad_x += [float(bx_[i] + ORDER_BAND_PX / 2) for i in np.nonzero(st > ORDER_MAX_STEP)[0]]
        bad_x += [float(bx_[i]) for i in np.nonzero(dd > ORDER_DRAWDOWN)[0]]

    # 4. seam: dots -> holes flip
    flip_x = None
    fm = flip_metrics(marks, psi, nn, pitch) if len(marks) >= 8 else None
    if fm is None:
        results.append(("seam: polarity mix / pitch", POLARITY_MIN_MIX, POLARITY_MIN_MIX, True, "no dots -> holes flip"))
        results.append(("seam: flip continuity step", 0, FLIP_STEP_MAX, True, "no dots -> holes flip"))
    else:
        flip_x, mix, step, note = fm
        results.append(("seam: polarity mix / pitch", mix, POLARITY_MIN_MIX, mix >= POLARITY_MIN_MIX,
                        f"flip {at(flip_x)}, pitch {pitch:.1f} px"))
        results.append(("seam: flip continuity step", step, FLIP_STEP_MAX, step <= FLIP_STEP_MAX, f"{at(flip_x)}: {note}"))
        if mix < POLARITY_MIN_MIX or step > FLIP_STEP_MAX:
            bad_x.append(flip_x)

    # 5. geometry
    results.append(("touching: merged blobs", merged, 0, merged == 0,
                    f"count where coverage < {TOUCH_OK_COVERAGE}" + (f"; first {at(*merged_xy[0])}" if merged else "")))
    bad_pts += [tuple(p_) for p_ in merged_xy]
    if np.isfinite(gaps).any():
        j = int(np.argmin(gaps))
        nbad = int((gaps < MIN_GAP_RATIO).sum())
        results.append(("touching: min gap / (r1+r2)", gaps[j], MIN_GAP_RATIO, gaps[j] >= MIN_GAP_RATIO,
                        f"min {at(*marks[j, :2])} ({'hole' if marks[j, 3] < 0 else 'dot'})"
                        + (f"; {nbad} marks below" if nbad else "")))
        bad_pts += [tuple(p_) for p_ in marks[gaps < MIN_GAP_RATIO, :2]]
    w = ink.sum()
    yy, xx = np.mgrid[:TILE, :TILE]
    cx, cy = (ink * xx).sum() / w, (ink * yy).sum() / w
    if flip:
        cx = TILE - cx
    if axis == "y":
        cx, cy = cy, cx
    bx, by = (x0 + x1) / 2, (y0 + y1) / 2
    if flip:
        bx = TILE - bx
    if axis == "y":
        bx, by = by, bx
    ox, oy = (cx + bx) / 2, (cy + by) / 2
    off = max(abs(ox - TILE / 2), abs(oy - TILE / 2)) / TILE
    results.append(("optical centre offset / tile", off, CENTROID_TOL, off <= CENTROID_TOL,
                    f"centroid ({cx:.0f}, {cy:.0f}), bbox centre ({bx:.0f}, {by:.0f})"))
    if len(bands):
        j = int(np.nanargmax(bands[:, 4]))
        cv = bands[j, 4]
        results.append(("dot size CV within band", cv, SIZE_CV_MAX, cv <= SIZE_CV_MAX,
                        f"r {bands[:, 3].min():.1f} -> {bands[:, 3].max():.1f} px; worst {at(bands[j, 0])}"))
        bad_x += [float(x) for x in bands[bands[:, 4] > SIZE_CV_MAX, 0]]
        rel = np.abs(np.diff(bands[:, 3])) / bands[:, 3].max() if len(bands) > 1 else np.zeros(1)
        j = int(np.argmax(rel))
        results.append(("dot size step between bands", rel.max(), SIZE_STEP_MAX, rel.max() <= SIZE_STEP_MAX,
                        "fraction of max radius" + (f"; worst {at(bands[j, 0] + ORDER_BAND_PX / 2)}" if len(bands) > 1 else "")))
        if len(bands) > 1:
            bad_x += [float(bands[i, 0] + ORDER_BAND_PX / 2) for i in np.nonzero(rel > SIZE_STEP_MAX)[0]]

    # report
    name = Path(path).name
    fails = sum(not r[3] for r in results)
    out = Path(out) if out else Path(tempfile.gettempdir()) / "design-review" / f"{Path(path).stem}-review.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    home_img = home_mock(img, out.with_name(f"{Path(path).stem}-home.png")) if home else None
    sheet(img, curves, bands, ramp, (ry0, ry1), bad_x, bad_pts, flip, axis, previews, results, out, home_img)
    if quiet:
        return fails, results
    print(f"design-review {name}: axis {axis}, ink rises {'<-' if flip else '->'}, ramp {axis} "
          f"{x_report(ramp[0], flip):.0f}-{x_report(ramp[1], flip):.0f}, {len(marks)} marks ({int((marks[:, 3] > 0).sum())} dots, "
          f"{int((marks[:, 3] < 0).sum())} holes; {closing} more in the closing zone, coverage >= {TOUCH_OK_COVERAGE}), "
          f"grain blur sigma {sigma:.1f} px")
    print(f"{'METRIC':<40}{'VALUE':>8}{'LIMIT':>8}  RESULT")
    for m, v, lim, ok, note in results:
        cmp = ">=" if ("min gap" in m or "polarity mix" in m) else "<="
        print(f"{m:<40}{v:>8.3f}{cmp:>4}{lim:<5.3g} {'PASS' if ok else 'FAIL'}  {note}")
    print(f"RESULT: {'FAIL' if fails else 'PASS'} ({fails} of {len(results)} metrics failed)")
    print(f"sheet: {out}" + (f"\nhome:  {out.with_name(Path(path).stem + '-home.png')}" if home else ""))
    return fails, results


def watch(paths, run):
    """Re-run whenever a render's mtime changes (poll every 0.5 s); one summary line per run. Ctrl-C stops."""
    import time
    seen = {}
    print(f"watching {', '.join(map(str, paths))} (Ctrl-C to stop)")
    try:
        while True:
            for p in paths:
                m = Path(p).stat().st_mtime if Path(p).exists() else None
                if m is None or seen.get(p) == m:
                    continue
                seen[p] = m
                time.sleep(0.3)                        # let the writer finish
                try:
                    fails, results = run(p)
                    loc = lambda note: (m_.group(0) if (m_ := re.search(r"at (x|y) [^;:]*", note)) else "")
                    bad = "; ".join(f"{n.strip()} {v:.3f} {loc(note)}".rstrip() for n, v, _, ok, note in results if not ok)
                    print(f"{time.strftime('%H:%M:%S')} {Path(p).name}: {'FAIL' if fails else 'PASS'} "
                          f"({fails} of {len(results)})" + (f": {bad}" if bad else ""), flush=True)
                except Exception as e:                 # a half-written file: wait for the next change
                    print(f"{time.strftime('%H:%M:%S')} {Path(p).name}: ERROR {e}", flush=True)
            time.sleep(0.5)
    except KeyboardInterrupt:
        pass


def x_report(x, flip):
    return TILE - x if flip else x


# ---------------------------------------------------------------- sheet
def sheet(img, curves, bands, ramp, rows_px, bad_x, bad_pts, flip, axis, previews, results, out, home_img):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    shown = img.transpose(Image.Transpose.TRANSPOSE) if axis == "y" else img
    shown = shown.transpose(Image.Transpose.FLIP_LEFT_RIGHT) if flip else shown
    rows = 6 + (2 if home_img is not None else 0)
    fig = plt.figure(figsize=(14, 3 * rows))
    gs = fig.add_gridspec(rows, 4, height_ratios=[3, 1, 1, 1, 1, 1] + ([3, 3] if home_img is not None else []))
    ax = fig.add_subplot(gs[0, :3])
    ax.imshow(shown, extent=(0, TILE, TILE, 0))
    for x in bad_x:
        ax.axvspan(x - 4, x + 4, color="red", alpha=0.25)
    for x, y in bad_pts:                               # failing marks (touching / merged)
        ax.add_patch(matplotlib.patches.Circle((x, y), 9, fill=False, color="red", lw=1.2))
    ax.axvline(ramp[0], color="tab:blue", lw=0.8); ax.axvline(ramp[1], color="tab:blue", lw=0.8)
    for y in rows_px:
        ax.axhline(y, color="tab:blue", lw=0.5, ls=":")
    ax.set_title(f"{'flipped so ink rises left to right, ' if flip else ''}{'axis y shown as x, ' if axis == 'y' else ''}"
                 "red = failing spot (circle = failing mark), blue = ramp and profiled rows", fontsize=9)
    pv = gs[0, 3].subgridspec(2, 1)
    for k, size in enumerate((58, 29)):
        a = fig.add_subplot(pv[k])
        a.imshow(previews[size].resize((232, 232), Image.NEAREST)); a.set_title(f"{size} px, enlarged", fontsize=8)
        a.axis("off")
    plots = [("coverage (black 1024 blurred, grey raw 8 px, blue 58, orange 29)", None),
             ("|step| / limit", 0), ("drawdown / limit", 1), ("|2nd diff| / limit", 2)]
    colors = {1024: "black", 58: "tab:blue", 29: "tab:orange"}
    for r, (title, m) in enumerate(plots, start=1):
        a = fig.add_subplot(gs[r, :3]); a.set_xlim(0, TILE); a.set_title(title, fontsize=9, loc="left")
        for size, (xs, p, raw, (i0, i1, steps, draw, d2)) in curves.items():
            if m is None:
                a.plot(xs, p, color=colors[size], lw=1.2)
                if raw is not None:
                    a.plot(xs, raw, color="0.7", lw=0.8)
            else:
                arr = (steps, draw, d2)[m] / PROFILE_LIMITS[size][m]
                off = (0.5, 0, 1)[m]
                a.plot(np.interp(np.arange(len(arr)) + i0 + off, np.arange(len(xs)), xs), arr, color=colors[size], lw=1.2)
        if m is not None:
            a.axhline(1, color="red", lw=0.8, ls="--")
        for x in bad_x:
            a.axvspan(x - 4, x + 4, color="red", alpha=0.15)
        a.axvline(ramp[0], color="tab:blue", lw=0.5); a.axvline(ramp[1], color="tab:blue", lw=0.5)
    a = fig.add_subplot(gs[5, :3]); a.set_xlim(0, TILE)
    a.set_title(f"order per {ORDER_BAND_PX} px band of marks: |psi6| (green), 1-CV(NN) (purple); mark radius / max "
                "(grey); hole fraction (orange)",
                fontsize=9, loc="left")
    if len(bands):
        a.plot(bands[:, 0], bands[:, 1], "o-", color="tab:green"); a.plot(bands[:, 0], bands[:, 2], "o-", color="tab:purple")
        a.plot(bands[:, 0], bands[:, 3] / bands[:, 3].max(), "o-", color="0.6")
        a.plot(bands[:, 0], bands[:, 6], "o-", color="tab:orange")
    a.set_ylim(0, 1.05)
    txt = fig.add_subplot(gs[1:6, 3]); txt.axis("off")
    txt.text(0, 1, "\n".join(f"{'PASS' if ok else 'FAIL'} {m}: {v:.3f}" for m, v, _, ok, _ in results),
             fontsize=7, va="top", family="monospace")
    if home_img is not None:
        a = fig.add_subplot(gs[6:, :]); a.imshow(home_img); a.axis("off")
    fig.tight_layout(); fig.savefig(out, dpi=90); plt.close(fig)


# ---------------------------------------------------------------- home screen mock
def fetch_icons():
    """Apple's own app icons via the public iTunes lookup API, cached in a gitignored folder."""
    ICON_CACHE.mkdir(parents=True, exist_ok=True)
    meta = ICON_CACHE / "icons.json"
    if not meta.exists():
        try:
            url = "https://itunes.apple.com/lookup?country=us&id=" + ",".join(map(str, ICON_IDS))
            with urllib.request.urlopen(url, timeout=10) as r:
                res = json.load(r)["results"]
            for app in res:
                urllib.request.urlretrieve(app["artworkUrl512"], ICON_CACHE / f"{app['trackId']}.jpg")
            meta.write_text(json.dumps({str(a["trackId"]): a["trackName"].replace("Apple ", "") for a in res}))
        except Exception as e:
            print(f"home: icon fetch failed ({e}); using neutral stand-ins", file=sys.stderr)
            return [(None, "App")] * len(ICON_IDS)
    names = json.loads(meta.read_text())
    return [(Image.open(ICON_CACHE / f"{i}.jpg").convert("RGB"), names.get(str(i), "App")) for i in ICON_IDS]


def squircle_mask(size, scale=4):
    """iOS continuous-corner icon shape, approximated by a superellipse |x|^5 + |y|^5 = 1."""
    n = size * scale
    t = (np.arange(n) + 0.5) / n * 2 - 1
    m = (np.abs(t)[None, :] ** 5 + np.abs(t)[:, None] ** 5) <= 1
    return Image.fromarray((m * 255).astype(np.uint8)).resize((size, size), Image.LANCZOS)


def home_mock(render, out):
    """Two wallpapers (dark, light), 4-column grid at @3x of a 402 pt wide iPhone: 60 pt icons = 180 px,
    labels 12 pt; the render sits in the first row, third column."""
    icon, w = 180, 1206
    gap = (w - 4 * icon) // 5
    mask = squircle_mask(icon)
    icons = fetch_icons()
    font_path = "/System/Library/Fonts/SFNS.ttf"
    font = ImageFont.truetype(font_path, 34) if os.path.exists(font_path) else ImageFont.load_default(34)
    panels = []
    for top, bottom, label in (((28, 30, 44), (10, 10, 14), (255, 255, 255)), ((214, 222, 232), (238, 240, 236), (20, 20, 20))):
        h = 2 * (icon + 90) + 60
        g = np.linspace(0, 1, h)[:, None, None]
        bgarr = (np.array(top) * (1 - g) + np.array(bottom) * g) * np.ones((h, w, 3))
        panel = Image.fromarray(bgarr.astype(np.uint8))
        draw = ImageDraw.Draw(panel)
        apps = [icons[0], icons[1], (render, "La Carte"), icons[2], icons[3], icons[4], icons[5], (None, "App")]
        for k, (im, name) in enumerate(apps):
            x, y = gap + (k % 4) * (icon + gap), 40 + (k // 4) * (icon + 90)
            tile = im.resize((icon, icon), Image.LANCZOS) if im is not None else Image.new("RGB", (icon, icon), (142, 142, 147))
            panel.paste(tile, (x, y), mask)
            draw.text((x + icon / 2, y + icon + 12), name, fill=label, font=font, anchor="ma")
        panels.append(panel)
    sheet = Image.new("RGB", (w * 2 + 40, panels[0].height), (255, 255, 255))
    sheet.paste(panels[0], (0, 0)); sheet.paste(panels[1], (w + 40, 0))
    sheet.save(out)
    return sheet


# ---------------------------------------------------------------- synthetic reference ramp
def synthetic_ramp(out, seed=7):
    """A smooth noise -> structure -> solid card (round 6 silhouette): the reference that must PASS.
    1. Hex lattice (pitch A) over the ramp, and Bridson Poisson-disc points of about the same density.
    2. Match them one-to-one (linear_sum_assignment); each dot sits at lerp(random, lattice, w(x)), w easing
       out until c = SYN_ON_SITE: order rises continuously while density stays put.
    3. One coverage c(x) = smoothstep from 0.04 to 1 (zero slope into the solid). Each lattice cell holds one
       ink mark of area c * cell: a round dot below C1 = 0.35, then a rounded hexagon (a hexagon of apothem k
       Minkowski-summed with a disc of radius rho) whose extent k + rho grows to A/2 while rho shrinks to 0,
       so the marks become the lattice's own cells and close into solid. No dots -> holes flip, so no seam
       (a flip in one column is a seam: it fails `seam: polarity mix`)."""
    rng = np.random.default_rng(seed)
    S = 4                                          # supersampling
    BG, INK = np.array([249, 250, 245]), np.array([28, 28, 28])
    W, H, R, CX, CY = 620, 400, 64, 490, 512
    XL = CX - W / 2
    XS = XL + 0.72 * W                             # solid from here (c = 1)
    A = 12.0                                       # lattice pitch
    SYN_ON_SITE = 0.55                             # dots reach their lattice site at this coverage
    sstep = lambda t: (lambda u: u * u * (3 - 2 * u))(np.clip(t, 0, 1))
    c = lambda x: 0.04 + 0.96 * sstep((x - XL) / (XS - XL))
    gx = np.linspace(XL, XS, 4000)
    xh = gx[np.argmax(c(gx) >= SYN_ON_SITE)]
    w = lambda x: 1 - (1 - np.clip((x - XL) / (xh - XL), 0, 1)) ** 2    # ease out: |psi6| rises evenly

    dx = A * math.sqrt(3) / 2                      # hex lattice in vertical columns
    lat = np.array([(x, y) for i, x in enumerate(np.arange(XS, XL - 2 * A, -dx))
                    for y in np.arange(CY - H / 2 - A + (A / 2) * (i % 2), CY + H / 2 + A, A)])
    box = (XL - A, xh + A, CY - H / 2 - A, CY + H / 2 + A)      # Bridson Poisson-disc in the dot zone
    rmin = 0.8 * A
    cell = rmin / math.sqrt(2)
    pts, active, grid = [], [], {}
    def add(p):
        pts.append(p); active.append(p); grid[(int(p[0] // cell), int(p[1] // cell))] = p
    add((rng.uniform(box[0], box[1]), rng.uniform(box[2], box[3])))
    while active:
        k = rng.integers(len(active)); base = active[k]
        for _ in range(30):
            a, d = rng.uniform(0, 2 * math.pi), rng.uniform(rmin, 2 * rmin)
            p = (base[0] + d * math.cos(a), base[1] + d * math.sin(a))
            if not (box[0] <= p[0] < box[1] and box[2] <= p[1] < box[3]):
                continue
            gx, gy = int(p[0] // cell), int(p[1] // cell)
            if all(math.dist(p, q) >= rmin for i in range(gx - 2, gx + 3) for j in range(gy - 2, gy + 3)
                   if (q := grid.get((i, j)))):
                add(p); break
        else:
            active.pop(k)
    rnd = np.array(pts)
    zone = lat[:, 0] < xh + A
    li, ri = linear_sum_assignment(np.linalg.norm(lat[zone][:, None] - rnd[None], axis=2))
    pos = lat.copy()
    zi = np.nonzero(zone)[0][li]
    pos[zi] = lat[zi] + (rnd[ri] - lat[zi]) * (1 - w(lat[zi, 0]))[:, None]
    keep = ~zone; keep[zi] = True                  # lattice points left without a random partner are dropped
    lat, pos = lat[keep], pos[keep]

    ys, xs = (np.mgrid[0:TILE * S, 0:TILE * S] + 0.5) / S
    qx, qy = np.abs(xs - CX) - (W / 2 - R), np.abs(ys - CY) - (H / 2 - R)
    sd = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - R
    ink = (sd <= 0) & (xs >= XS)                   # the solid
    ramp = (sd <= 0) & (xs < XS)
    p = np.column_stack([xs[ramp], ys[ramp]])
    # mark shape per coverage: round dot (k = 0) below C1, then a rounded hexagon of exact area c * cell
    cell_area, C1 = math.sqrt(3) / 2 * A * A, 0.35
    e1 = A * math.sqrt(C1 * math.sqrt(3) / (2 * math.pi))
    es = np.linspace(e1, A / 2, 600)                                    # extent k + rho
    rhos = e1 * (A / 2 - es) / (A / 2 - e1)
    covs = (2 * math.sqrt(3) * (es - rhos) ** 2 + 4 * math.sqrt(3) * (es - rhos) * rhos + math.pi * rhos ** 2) / cell_area
    cl = cKDTree(lat).query(p)[1]                  # Voronoi cell of each pixel
    cc = c(lat[:, 0])
    e = np.where(cc < C1, A * np.sqrt(cc * math.sqrt(3) / (2 * math.pi)), np.interp(cc, covs, es))
    rho = np.where(cc < C1, e, np.interp(cc, covs, rhos))
    pc = pos[cl]                                   # marks stay whole: drop any not fully inside the card
    qx, qy = np.abs(pc[:, 0] - CX) - (W / 2 - R), np.abs(pc[:, 1] - CY) - (H / 2 - R)
    whole = (np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - R <= -e[cl]) | (cc[cl] >= 0.9)
    q = np.abs(p - pc)                             # signed distance to a flat-top hexagon of apothem k (iq)
    k = (e - rho)[cl]
    d = np.minimum(-0.866025404 * q[:, 0] + 0.5 * q[:, 1], 0)
    hx, hy = q[:, 0] + 2 * d * 0.866025404, q[:, 1] - 2 * d * 0.5
    hx, hy = hx - np.clip(hx, -0.577350269 * k, 0.577350269 * k), hy - k
    ink[ramp] = (np.hypot(hx, hy) * np.sign(hy) - rho[cl] <= 0) & whole
    cov = ink.reshape(TILE, S, TILE, S).mean(axis=(1, 3))[..., None]
    Image.fromarray((BG * (1 - cov) + INK * cov).astype(np.uint8)).save(out)
    print(f"synthetic ramp: {out}")


# ---------------------------------------------------------------- main
if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("render", nargs="*", help="render-1024.png or .svg (several: each is reviewed)")
    ap.add_argument("--axis", choices=("x", "y"), default="x", help="transition axis (default x)")
    ap.add_argument("--region", help="x0,y0,x1,y1 in 1024 px (default: the ink bounding box)")
    ap.add_argument("--home", action="store_true", help="also render home-screen rows with Apple's icons")
    ap.add_argument("--out", help="sheet path (default: $TMPDIR/design-review/<name>-review.png)")
    ap.add_argument("--make-synthetic", metavar="OUT.png", help="write the smooth reference ramp and review it")
    ap.add_argument("--watch", action="store_true", help="re-run when a render changes; one PASS/FAIL line per run")
    a = ap.parse_args()
    if a.make_synthetic:
        synthetic_ramp(a.make_synthetic)
        a.render = a.render or [a.make_synthetic]
    if not a.render:
        ap.error("render path required")
    if a.out and len(a.render) > 1:
        ap.error("--out takes one render")
    region = tuple(int(v) for v in a.region.split(",")) if a.region else None
    if a.watch:
        watch(a.render, lambda p: review(p, a.axis, region, a.out, a.home, quiet=True))
        sys.exit(0)
    fails = 0
    for k, path in enumerate(a.render):
        if k:
            print()
        fails += review(path, a.axis, region, a.out, a.home)[0]
    sys.exit(1 if fails else 0)
