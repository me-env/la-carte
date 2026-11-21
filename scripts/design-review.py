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

    uv run scripts/design-review.py <render-1024.png|.svg> [--home] [--axis x|y] [--region x0,y0,x1,y1] [--out sheet.png]
    uv run scripts/design-review.py --make-synthetic out.png     # a smooth reference ramp that must PASS

Prints PASS/FAIL per metric (value vs limit) and writes an annotated sheet (render, curves under it on the
same x axis with failing spots in red, 58/29 px previews). Exit code 1 on any FAIL.
All lengths are in px of a 1024 tile; other sizes are resampled to 1024 first. SVGs go through rsvg-convert.

What it measures, along the transition axis (default x; the direction of rising ink is auto-detected):
1. Coverage profile at 1024: ink per 8 px column over the middle 60% of the mark's height (avoids rounded
   corners), after a Gaussian blur at the grain scale (sigma = median dot nearest-neighbour distance), so a
   regular lattice doesn't alias against the 8 px columns. Max |step|, max drawdown (fall below the running
   max = a reversal), max |second difference| (a slope change = a visible seam).
2. The same on the 58 px and 29 px icons (area downsample + 0.7 px blur: roughly what the eye integrates).
3. Order along the axis, per 32 px band of detected dots (SVG circles, or PNG connected components):
   hexatic order |psi6| over Delaunay neighbours, and regularity 1 - CV(nearest-neighbour distance). Both
   must rise without an adjacent-band step or a drop: "random, then suddenly a lattice" fails here.
4. Geometry: merged (touching) blobs and the smallest dot gap; optical centre (midpoint of the bbox centre
   and the ink centroid) vs tile centre; dot size spread inside each band (one size per position) and
   size steps between bands.

The ramp analysed runs from the first column with ink to the first column at the solid plateau (97% of the
max), so the joint into the solid is always inside the checked range.

Synthetic reference (`--make-synthetic`, function `synthetic_ramp`), the generation idea for design-lead:
blue-noise points (Bridson Poisson-disc) matched one-to-one to a hex lattice of the same density
(linear_sum_assignment), each dot at lerp(random, lattice, w(x)) with w easing out (|psi6| only climbs
once dots are within ~0.2 pitch of their site, so a linear or smoothstep w bunches the order rise at the
end); one coverage function c(x)
drives the dot radius up to 50%, then inverts to white holes shrinking into solid (AM halftone), so
coverage is continuous 0 -> 1 with no gap column and no jump into the solid.
"""
import argparse, json, math, os, re, subprocess, sys, tempfile, urllib.request
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage
from scipy.optimize import linear_sum_assignment
from scipy.spatial import Delaunay, cKDTree

# ---- Thresholds (calibrated 2026-11-21 on round6/pass5, which must FAIL, and --make-synthetic, which must
# PASS; revisit after two design rounds). Units: coverage fraction 0..1 per column of the given size.
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
ORDER_MIN_DOTS = 10             # bands with fewer dots are skipped
ORDER_MAX_STEP = 0.25           # max change of |psi6| or 1-CV(NN) between adjacent bands (band noise ~0.05)
ORDER_DRAWDOWN = 0.08           # max fall of an order measure below its running max (order must rise)
MIN_GAP_RATIO = 0.20            # dot gap >= 20% of the pair's summed radii (round 6 built with 25%)
MERGED_ASPECT = 1.4             # a dot blob this elongated (second moments) is two touching dots
CENTROID_TOL = 0.03             # optical centre (midpoint of bbox centre and ink centroid) within 3% of the
                                # tile (31 px) of the tile centre, per axis
SIZE_CV_MAX = 0.20              # dot radius CV inside one band (one size per position)
SIZE_STEP_MAX = 0.20            # change of median dot radius between adjacent bands, as a fraction of the max

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
def detect_dots(ink, circles):
    """Returns (dots[n, 3] = x, y, r; merged blob count). Big shapes (the solid) are not dots."""
    lab, n = ndimage.label(ink > 0.5)
    idx = np.arange(1, n + 1)
    areas = ndimage.sum(np.ones_like(ink), lab, idx)
    small = (areas >= 3) & (areas < 0.002 * TILE * TILE)
    merged = 0
    for i, sl in enumerate(ndimage.find_objects(lab)):
        if small[i] and areas[i] > 12:
            pts = np.argwhere(lab[sl] == i + 1).astype(float)
            ev = np.linalg.eigvalsh(np.cov(pts.T))
            merged += math.sqrt(ev[1] / max(ev[0], 1e-9)) > MERGED_ASPECT
    if circles is not None:
        big = circles[:, 2] >= 0.05 * TILE
        return circles[~big], merged
    cy, cx = np.array(ndimage.center_of_mass(ink > 0.5, lab, idx[small])).T.reshape(2, -1)
    return np.column_stack([cx, cy, np.sqrt(areas[small] / math.pi)]), merged


def order_bands(dots, x0, x1):
    """Per 32 px band: centre x, mean |psi6|, 1 - CV(NN), median r, CV(r), dot count."""
    if len(dots) < 8:
        return np.zeros((0, 6)), np.inf
    xy = dots[:, :2]
    nn = cKDTree(xy).query(xy, k=2)[0][:, 1]
    tri = Delaunay(xy)
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
    lo, hi = np.percentile(xy[:, 0], [1, 99])
    lo, hi = max(lo, x0), min(hi, x1)
    rows = []
    for b0 in np.arange(lo, hi, ORDER_BAND_PX):
        sel = (xy[:, 0] >= b0) & (xy[:, 0] < b0 + ORDER_BAND_PX)
        if sel.sum() < ORDER_MIN_DOTS:
            continue
        p = psi[sel][~np.isnan(psi[sel])]
        r = dots[sel, 2]
        rows.append([b0 + ORDER_BAND_PX / 2, p.mean() if len(p) else np.nan,
                     1 - nn[sel].std() / nn[sel].mean(), np.median(r), r.std() / r.mean(), sel.sum()])
    # smallest gap relative to the pair's radii, over Delaunay edges
    e = np.unique(np.sort(np.concatenate([tri.simplices[:, [0, 1]], tri.simplices[:, [1, 2]],
                                          tri.simplices[:, [0, 2]]]), axis=1), axis=0)
    rs = dots[e[:, 0], 2] + dots[e[:, 1], 2]
    gap = np.hypot(*(xy[e[:, 0]] - xy[e[:, 1]]).T) - rs
    return np.array(rows), (gap / rs).min()


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
def review(path, axis="x", region=None, out=None, home=False):
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
    dots, merged = detect_dots(ink, circles)
    in_rows = (dots[:, 1] >= y0) & (dots[:, 1] < y1) if len(dots) else np.zeros(0, bool)
    dots = dots[in_rows]
    sigma = max(4.0, float(np.median(cKDTree(dots[:, :2]).query(dots[:, :2], k=2)[0][:, 1]))) if len(dots) > 8 else 4.0

    results, curves = [], {}
    # 1. coverage profile at 1024, sampled every 8 px
    full = profile(ink, ry0, ry1, sigma)
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
            results.append((f"coverage {size:>4} {name} / {unit}", arr[j], limit, ok, f"at {axis} {x_report(xs_at, flip):.0f}"))
            for jj in np.nonzero(arr > limit)[0]:
                bad_x.append(float(np.interp(i0 + jj + off, np.arange(len(xs_)), xs_)))
    i0, i1 = curves[1024][3][:2]
    ramp = (curves[1024][0][i0] - COL_PX / 2, curves[1024][0][i1] + COL_PX / 2)

    # 3. order along the axis
    bands, gap_ratio = order_bands(dots, ramp[0], ramp[1])
    for col, name in ((1, "order |psi6|"), (2, "order 1-CV(NN)")):
        v = bands[:, col] if len(bands) else np.zeros(0)
        v = v[~np.isnan(v)]
        if len(v) < 2:
            results.append((f"{name} band step", 0, ORDER_MAX_STEP, True, "fewer than 2 dot bands"))
            continue
        st = np.abs(np.diff(v)); dd = np.maximum.accumulate(v) - v
        j = int(np.argmax(st))
        results.append((f"{name} band step", st[j], ORDER_MAX_STEP, st[j] <= ORDER_MAX_STEP,
                        f"{v.min():.2f} -> {v.max():.2f}, {len(v)} bands of {ORDER_BAND_PX} px"))
        results.append((f"{name} drawdown", dd.max(), ORDER_DRAWDOWN, dd.max() <= ORDER_DRAWDOWN, "must rise"))
        if st[j] > ORDER_MAX_STEP:
            bad_x.append(float(bands[~np.isnan(bands[:, col]), 0][j] + ORDER_BAND_PX / 2))

    # 4. geometry
    results.append(("touching: merged blobs", merged, 0, merged == 0, "count"))
    if np.isfinite(gap_ratio):
        results.append(("touching: min gap / (r1+r2)", gap_ratio, MIN_GAP_RATIO, gap_ratio >= MIN_GAP_RATIO, "min"))
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
        cv = np.nanmax(bands[:, 4])
        results.append(("dot size CV within band", cv, SIZE_CV_MAX, cv <= SIZE_CV_MAX,
                        f"r {bands[:, 3].min():.1f} -> {bands[:, 3].max():.1f} px"))
        rel = np.abs(np.diff(bands[:, 3])) / bands[:, 3].max() if len(bands) > 1 else np.zeros(1)
        results.append(("dot size step between bands", rel.max(), SIZE_STEP_MAX, rel.max() <= SIZE_STEP_MAX,
                        "fraction of max radius"))

    # report
    name = Path(path).name
    print(f"design-review {name}: axis {axis}, ink rises {'<-' if flip else '->'}, ramp {axis} "
          f"{x_report(ramp[0], flip):.0f}-{x_report(ramp[1], flip):.0f}, {len(dots)} dots, grain blur sigma {sigma:.1f} px")
    print(f"{'METRIC':<40}{'VALUE':>8}{'LIMIT':>8}  RESULT")
    for m, v, lim, ok, note in results:
        cmp = ">=" if "min gap" in m else "<="
        print(f"{m:<40}{v:>8.3f}{cmp:>4}{lim:<5.3g} {'PASS' if ok else 'FAIL'}  {note}")
    fails = sum(not r[3] for r in results)
    out = Path(out) if out else Path(tempfile.gettempdir()) / "design-review" / f"{Path(path).stem}-review.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    home_img = home_mock(img, out.with_name(f"{Path(path).stem}-home.png")) if home else None
    sheet(img, curves, bands, ramp, (ry0, ry1), bad_x, flip, axis, previews, results, out, home_img)
    print(f"RESULT: {'FAIL' if fails else 'PASS'} ({fails} of {len(results)} metrics failed)")
    print(f"sheet: {out}" + (f"\nhome:  {out.with_name(Path(path).stem + '-home.png')}" if home else ""))
    return fails


def x_report(x, flip):
    return TILE - x if flip else x


# ---------------------------------------------------------------- sheet
def sheet(img, curves, bands, ramp, rows_px, bad_x, flip, axis, previews, results, out, home_img):
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
    ax.axvline(ramp[0], color="tab:blue", lw=0.8); ax.axvline(ramp[1], color="tab:blue", lw=0.8)
    for y in rows_px:
        ax.axhline(y, color="tab:blue", lw=0.5, ls=":")
    ax.set_title(f"{'flipped so ink rises left to right, ' if flip else ''}{'axis y shown as x, ' if axis == 'y' else ''}"
                 "red = failing spot, blue = ramp and profiled rows", fontsize=9)
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
    a.set_title(f"order per {ORDER_BAND_PX} px band: |psi6| (green), 1-CV(NN) (purple); dot radius / max (grey)",
                fontsize=9, loc="left")
    if len(bands):
        a.plot(bands[:, 0], bands[:, 1], "o-", color="tab:green"); a.plot(bands[:, 0], bands[:, 2], "o-", color="tab:purple")
        a.plot(bands[:, 0], bands[:, 3] / bands[:, 3].max(), "o-", color="0.6")
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
    2. Match them one-to-one (linear_sum_assignment); each dot sits at lerp(random, lattice, w(x)),
       w = smoothstep over the dot zone: order rises continuously while density stays put.
    3. One coverage c(x) = smoothstep from 0.04 to 1 (zero slope into the solid). Each lattice cell
       (Voronoi) with c < 0.5 holds a black dot of radius A*sqrt(c*sqrt(3)/(2*pi)); with c >= 0.5 it is
       black with a white hole of radius A*sqrt((1-c)*sqrt(3)/(2*pi)) (AM halftone inversion)."""
    rng = np.random.default_rng(seed)
    S = 4                                          # supersampling
    BG, INK = np.array([249, 250, 245]), np.array([28, 28, 28])
    W, H, R, CX, CY = 620, 400, 64, 490, 512
    XL = CX - W / 2
    XS = XL + 0.72 * W                             # solid from here (c = 1)
    A = 12.0                                       # lattice pitch
    sstep = lambda t: (lambda u: u * u * (3 - 2 * u))(np.clip(t, 0, 1))
    c = lambda x: 0.04 + 0.96 * sstep((x - XL) / (XS - XL))
    xh = XL + (XS - XL) / 2                        # c(xh) = 0.5: dots -> holes
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
    cl = cKDTree(lat).query(p)[1]                  # Voronoi cell of each pixel
    cx_ = lat[cl, 0]
    cc = c(cx_)
    rd = A * np.sqrt(cc * math.sqrt(3) / (2 * math.pi))
    pc = pos[cl]                                   # dots stay whole: drop any not fully inside the card
    qx, qy = np.abs(pc[:, 0] - CX) - (W / 2 - R), np.abs(pc[:, 1] - CY) - (H / 2 - R)
    whole = np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - R <= -rd
    dot = (np.linalg.norm(p - pc, axis=1) < rd) & whole
    hole = np.linalg.norm(p - lat[cl], axis=1) < A * np.sqrt((1 - cc) * math.sqrt(3) / (2 * math.pi))
    ink[ramp] = np.where(cc < 0.5, dot, ~hole)
    cov = ink.reshape(TILE, S, TILE, S).mean(axis=(1, 3))[..., None]
    Image.fromarray((BG * (1 - cov) + INK * cov).astype(np.uint8)).save(out)
    print(f"synthetic ramp: {out}")


# ---------------------------------------------------------------- main
if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("render", nargs="?", help="render-1024.png or .svg")
    ap.add_argument("--axis", choices=("x", "y"), default="x", help="transition axis (default x)")
    ap.add_argument("--region", help="x0,y0,x1,y1 in 1024 px (default: the ink bounding box)")
    ap.add_argument("--home", action="store_true", help="also render home-screen rows with Apple's icons")
    ap.add_argument("--out", help="sheet path (default: $TMPDIR/design-review/<name>-review.png)")
    ap.add_argument("--make-synthetic", metavar="OUT.png", help="write the smooth reference ramp and review it")
    a = ap.parse_args()
    if a.make_synthetic:
        synthetic_ramp(a.make_synthetic)
        a.render = a.render or a.make_synthetic
    if not a.render:
        ap.error("render path required")
    region = tuple(int(v) for v in a.region.split(",")) if a.region else None
    sys.exit(1 if review(a.render, a.axis, region, a.out, a.home) else 0)
