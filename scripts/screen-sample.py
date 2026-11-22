#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = [
#   "pillow==12.0.0",
#   "coloraide==8.16",
#   "numpy==2.5.5",
# ]
# ///
"""Measure colours and contrast on exported screenshots, so acceptance criteria are numbers, not eyeballing.

    uv run scripts/screen-sample.py at       <png> x,y [x,y ...]
    uv run scripts/screen-sample.py region   <png> x0,y0,x1,y1
    uv run scripts/screen-sample.py diff     <A> <B>          # A, B: hex | png@x,y | png@x0,y0,x1,y1
    uv run scripts/screen-sample.py contrast <png> x0,y0,x1,y1 [--min 4.5]   # exit 1 below --min
    uv run scripts/screen-sample.py gap      <png> x0,y0,x1,y1 --fg HEX --bg HEX [--tol 10]
    uv run scripts/screen-sample.py bbox     <png> x0,y0,x1,y1 [--bg HEX] [--tol 24]
    uv run scripts/screen-sample.py bands    <png> x0,y0,x1,y1 [--bg HEX] [--tol 24] [--axis y|x] [--min-gap PT]
    uv run scripts/screen-sample.py compare  <A.png> <B.png> x0,y0,x1,y1 [bands options] [--max-offset PT]
    uv run scripts/screen-sample.py dots     <png> [<png> ...] x0,y0,x1,y1 [--bg HEX] [--tol 24] [--ring | --axis x|y]
                                             [--sym x|y|both] [--min-d PT] [--min-area PX2] [--dots-list]
    uv run scripts/screen-sample.py --selftest

Coordinates are in points. The scale comes from the image width (1206 -> 3, 804 -> 2, 402 -> 1); other
widths fail unless `--scale N` is given, or `--px` (coordinates are pixels). Hex may be written with or
without `#` (quote it in the shell: an unquoted `#...` word is a comment). Input PNGs are only read.
All colour maths (ΔE2000, WCAG 2.1 contrast) is coloraide's.

- at: per point, the median of the 3x3 pixels around it.
- region: mean colour, per-channel stdev, max ΔE2000 of any pixel from the mean (uniformity), top 3 colours.
- diff: ΔE2000, WCAG contrast ratio, per-channel delta (B - A). A region stands for its mean colour.
- contrast: background = commonest colour; text = commonest colour among the pixels at least 90 % as far
  from the background as the furthest one (distance = sum of |ΔR|+|ΔG|+|ΔB|).
- gap: minimum distance (points) between pixels within ΔE2000 `tol` of fg and pixels within `tol` of bg.
  Anti-aliased edges blend through mid colours: when bg is a mid-grey near the fg's edge blend, use a small
  `--tol` (e.g. 0.5) or a gap of 1 px may just be fg's own edge pixel.
- bbox: bounding box of the ink in the region. Ink = pixel whose largest per-channel |Δ| (0-255) from the
  background exceeds `--tol` (default 24); background = `--bg`, else the region's commonest colour. Boxes are
  in image points, end exclusive (x1 = last ink pixel + 1 px).
- bands: runs of rows (`--axis y`, text lines) or columns (`--axis x`) that contain ink: start, end, size and
  gap to the previous band, in points. Bands closer than `--min-gap` points (default 0) are merged, so
  accents and descenders don't split a line (e.g. `--min-gap 4`).
- compare: bbox and bands of the same region in A and B (each its own background unless `--bg`), and B - A:
  bbox dx/dy/dw/dh, band counts, per-band dy (paired in order; flagged when the counts differ). Exit 1 only
  with `--max-offset PT` when an offset exceeds it, the band counts differ, or ink is in only one image.
- dots: dots = 8-connected ink components (ink as in bbox). Components under `--min-area` px² (default 4) or
  `--min-d` pt equivalent diameter (default 0.15 x the median) are dropped as noise and counted. Per dot: centre,
  equivalent diameter d (from area) and bbox w x h, filled | ring (bbox holds background not connected to its
  outside), Δ = max per-channel |Δ| of its mean colour from bg, merged? (aspect > 1.3 or area > 1.6 x median).
  Per region: count, d min/median/max/spread, filled/ring, merged, Δ min-max (+ ink/track split when the largest
  jump in sorted Δ is > half the range and >= 16), smallest and largest gap between consecutive dots (edge gap =
  centre distance - both radii, so it can go negative for merged/odd shapes; order = clockwise angle from 12
  o'clock around the dots' centroid with `--ring`, else along `--axis`, default x; dots are numbered #i in that
  order), symmetry about the region's vertical centre line (`--sym x`), horizontal (y) or both: each centre
  mirrored, distance to the nearest dot (max, mean), unmatched = none within half its diameter. Several PNGs =
  a frame sequence: one line per frame, then count min/max, max |Δcount|, min gap, max gap, worst symmetry, each
  with its frame (0-based). `--dots-list` prints every dot.

`--json` (before or after the subcommand) prints one JSON object, e.g.:
    at       {"scale": 3, "points": [{"x": 70, "y": 370, "hex": "#1C1C1C"}]}
    region   {"scale": 3, "rect": [10, 600, 390, 700], "pixels": 342000, "mean": "#F9FAF5",
              "stdev": [0.0, 0.0, 0.0], "max_delta_e": 0.0, "top": [{"hex": "#F9FAF5", "share": 1.0}]}
    diff     {"a": "#F9FAF5", "b": "#1C1C1C", "delta_e": 89.1, "contrast": 16.24, "delta_rgb": [-221, -222, -217]}
    contrast {"scale": 3, "rect": [...], "background": "#F9FAF5", "text": "#1C1C1C", "contrast": 16.24,
              "aa": true, "aaa": true, "min": 4.5, "pass": true}
    gap      {"scale": 3, "rect": [...], "fg": "#B8325A", "bg": "#1C1C1C", "tol": 10, "fg_pixels": 1200,
              "bg_pixels": 3400, "gap_pt": 4.33, "gap_px": 13.0}     # gap_pt null when a mask is empty
    bbox     {"scale": 3, "rect": [...], "background": "#F9FAF5", "tol": 24, "ink_pixels": 5120,
              "box": [24.0, 148.0, 378.0, 190.33], "width": 354.0, "height": 42.33}   # box null: no ink
    bands    {"scale": 3, "rect": [...], "background": "#F9FAF5", "tol": 24, "axis": "y", "min_gap": 0,
              "bands": [{"start": 148.0, "end": 166.33, "size": 18.33, "gap": null}, ...]}
    compare  {"scale": 3, "rect": [...], "a": {bbox + bands}, "b": {...}, "bbox_delta": [dx, dy, dw, dh],
              "band_counts": [2, 2], "band_dy": [1.33, 1.33], "counts_differ": false, "max_offset": 1.33,
              "limit": null, "pass": true}
    dots     {"rect": [...], "png": ..., "scale": 3, "background": "#F9FAF5", "count": 12, "dropped": 0,
              "d_median": 4.3, "rings": 0, "merged": 0, "classes": null, "min_gap": {"gap": 1.2, "dots": [3, 4]},
              "max_gap": {...},
              "symmetry": {"x": {"line": 201.0, "max": 0.3, "mean": 0.1, "unmatched": 0}}, "dots": [...], ...}
              # several PNGs: {"rect": [...], "frames": [<one per PNG>], "summary": {"count_change": {"value": 1,
              #                "frame": 3}, "min_gap": {...}, "max_gap": {...}, "worst_symmetry": {...}, ...}}
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from coloraide import Color
from PIL import Image

SCALES = {1206: 3, 804: 2, 402: 1}


# --- colour helpers (coloraide does the maths) -------------------------------------------------------

def hex_of(rgb) -> str:
    return "#{:02X}{:02X}{:02X}".format(*(int(round(c)) for c in rgb))


def parse_hex(s: str) -> tuple[int, int, int]:
    s = s.lstrip("#")
    if len(s) != 6:
        sys.exit(f"bad colour {s!r}: expected 6 hex digits")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def color(rgb) -> Color:
    return Color("srgb", [c / 255 for c in rgb])


def delta_e(a, b) -> float:
    return color(a).delta_e(color(b), method="2000")


def contrast_ratio(a, b) -> float:
    return color(a).contrast(color(b), method="wcag21")


# --- image helpers -----------------------------------------------------------------------------------

def load(path: str) -> np.ndarray:
    with Image.open(path) as im:
        return np.asarray(im.convert("RGB"), dtype=np.int64)


def scale_for(img: np.ndarray, args) -> float:
    if args.px:
        return 1
    if args.scale is not None:
        if args.scale <= 0:
            sys.exit("--scale must be > 0")
        return args.scale
    width = img.shape[1]
    if width not in SCALES:
        sys.exit(f"image width {width}px is not 1206/804/402: pass --scale N or --px")
    return SCALES[width]


def nums(s: str, n: int) -> list[float]:
    parts = s.split(",")
    if len(parts) != n:
        sys.exit(f"bad coordinates {s!r}: expected {n} comma-separated numbers")
    return [float(p) for p in parts]


def px_rect(img: np.ndarray, rect: list[float], scale: float) -> tuple[int, int, int, int]:
    x0, y0, x1, y1 = (int(round(v * scale)) for v in rect)
    h, w = img.shape[:2]
    x0, x1 = sorted((max(0, min(w, x0)), max(0, min(w, x1))))
    y0, y1 = sorted((max(0, min(h, y0)), max(0, min(h, y1))))
    if x1 <= x0 or y1 <= y0:
        sys.exit(f"empty region {rect} (image is {w}x{h}px, scale {scale})")
    return x0, y0, x1, y1


def crop(img: np.ndarray, rect: list[float], scale: float) -> np.ndarray:
    x0, y0, x1, y1 = px_rect(img, rect, scale)
    return img[y0:y1, x0:x1]


def counts(pixels: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Unique colours of an (..., 3) array, their counts, and each pixel's index into them."""
    flat = pixels.reshape(-1, 3)
    packed = flat[:, 0] << 16 | flat[:, 1] << 8 | flat[:, 2]
    uniq, inverse, n = np.unique(packed, return_inverse=True, return_counts=True)
    rgbs = np.stack([uniq >> 16 & 255, uniq >> 8 & 255, uniq & 255], axis=1)
    return rgbs, n, inverse.reshape(pixels.shape[:2])


# --- subcommands (pure: arrays in, dicts out) --------------------------------------------------------

def sample_at(img: np.ndarray, x: float, y: float, scale: float) -> dict:
    h, w = img.shape[:2]
    px, py = int(round(x * scale)), int(round(y * scale))
    if not (0 <= px < w and 0 <= py < h):
        sys.exit(f"point {x},{y} is outside the image ({w}x{h}px, scale {scale})")
    patch = img[max(0, py - 1):py + 2, max(0, px - 1):px + 2].reshape(-1, 3)
    return {"x": x, "y": y, "hex": hex_of(np.median(patch, axis=0))}


def region_stats(pixels: np.ndarray) -> dict:
    flat = pixels.reshape(-1, 3).astype(float)
    mean = flat.mean(axis=0)
    rgbs, n, _ = counts(pixels)
    mean_rgb = tuple(int(round(c)) for c in mean)
    max_de = max(delta_e(mean_rgb, rgb) for rgb in rgbs)
    top = np.argsort(-n)[:3]
    return {
        "pixels": int(n.sum()),
        "mean": hex_of(mean),
        "stdev": [round(float(s), 2) for s in flat.std(axis=0)],
        "max_delta_e": round(max_de, 2),
        "top": [{"hex": hex_of(rgbs[i]), "share": round(float(n[i] / n.sum()), 4)} for i in top],
    }


def compare(a, b) -> dict:
    return {
        "a": hex_of(a), "b": hex_of(b),
        "delta_e": round(delta_e(a, b), 2),
        "contrast": round(contrast_ratio(a, b), 2),
        "delta_rgb": [int(y) - int(x) for x, y in zip(a, b)],
    }


def text_contrast(pixels: np.ndarray, minimum: float) -> dict:
    # Same rule as `expectText` in ios/LaCarteKit/Tests/ScreenColorTests/ScreenColorTests.swift
    # (there the background is the palette's; here it's the commonest colour). Keep them in sync.
    rgbs, n, _ = counts(pixels)
    background = rgbs[np.argmax(n)]
    distance = np.abs(rgbs - background).sum(axis=1)
    core = distance * 10 >= distance.max() * 9
    text = rgbs[core][np.argmax(n[core])]
    ratio = contrast_ratio(text, background)
    return {
        "background": hex_of(background), "text": hex_of(text), "contrast": round(ratio, 2),
        "aa": ratio >= 4.5, "aaa": ratio >= 7, "min": minimum, "pass": ratio >= minimum,
    }


def mask_near(pixels: np.ndarray, target, tol: float) -> np.ndarray:
    rgbs, _, inverse = counts(pixels)
    near = np.array([delta_e(target, rgb) <= tol for rgb in rgbs])
    return near[inverse]


def edge(mask: np.ndarray) -> np.ndarray:
    """Mask pixels with a 4-neighbour outside the mask (the nearest pair of two sets lies on their edges)."""
    p = np.pad(mask, 1, constant_values=False)
    inner = p[:-2, 1:-1] & p[2:, 1:-1] & p[1:-1, :-2] & p[1:-1, 2:]
    return mask & ~inner


def min_gap(pixels: np.ndarray, fg, bg, tol: float) -> dict:
    fg_mask, bg_mask = mask_near(pixels, fg, tol), mask_near(pixels, bg, tol)
    result = {"fg": hex_of(fg), "bg": hex_of(bg), "tol": tol,
              "fg_pixels": int(fg_mask.sum()), "bg_pixels": int(bg_mask.sum()), "gap_px": None}
    if fg_mask.any() and bg_mask.any():
        a = np.argwhere(edge(fg_mask)).astype(float)
        b = np.argwhere(edge(bg_mask)).astype(float)
        best = np.inf
        for i in range(0, len(a), 2048):  # chunked brute force over edge pixels only
            d = ((a[i:i + 2048, None, :] - b[None, :, :]) ** 2).sum(axis=2)
            best = min(best, float(d.min()))
        result["gap_px"] = round(best ** 0.5, 2)
    return result


def ink_mask(pixels: np.ndarray, bg, tol: float) -> tuple[np.ndarray, tuple]:
    """Ink = largest per-channel |Δ| (0-255) from bg above tol; bg None = the commonest colour."""
    if bg is None:
        rgbs, n, _ = counts(pixels)
        bg = tuple(int(c) for c in rgbs[np.argmax(n)])
    return np.abs(pixels - np.array(bg)).max(axis=2) > tol, bg


def pt(px: float, scale: float) -> float:
    return round(float(px) / scale, 2)


def ink_bbox(mask: np.ndarray, origin: tuple[int, int], scale: float) -> dict:
    """origin = the region's top-left pixel in the image, so the box is in image points."""
    result = {"ink_pixels": int(mask.sum()), "box": None, "width": None, "height": None}
    if result["ink_pixels"]:
        ys, xs = np.nonzero(mask.any(axis=1))[0], np.nonzero(mask.any(axis=0))[0]
        x0, y0 = origin[0] + xs[0], origin[1] + ys[0]
        x1, y1 = origin[0] + xs[-1] + 1, origin[1] + ys[-1] + 1
        result |= {"box": [pt(v, scale) for v in (x0, y0, x1, y1)],
                   "width": pt(x1 - x0, scale), "height": pt(y1 - y0, scale)}
    return result


def ink_bands(mask: np.ndarray, origin: tuple[int, int], scale: float, axis: str, min_gap: float) -> list[dict]:
    lines = mask.any(axis=1 if axis == "y" else 0)
    start = origin[1] if axis == "y" else origin[0]
    edges = np.diff(np.concatenate([[0], lines.astype(np.int8), [0]]))
    runs: list[list[int]] = []
    for a, b in zip(np.nonzero(edges == 1)[0], np.nonzero(edges == -1)[0]):
        if runs and a - runs[-1][1] < min_gap * scale:
            runs[-1][1] = int(b)
        else:
            runs.append([int(a), int(b)])
    bands, prev = [], None
    for a, b in runs:
        bands.append({"start": pt(start + a, scale), "end": pt(start + b, scale), "size": pt(b - a, scale),
                      "gap": None if prev is None else pt(a - prev, scale)})
        prev = b
    return bands


def measure(img: np.ndarray, rect: list[float], scale: float, args) -> dict:
    x0, y0, x1, y1 = px_rect(img, rect, scale)
    mask, bg = ink_mask(img[y0:y1, x0:x1], args.bg, args.tol)
    return ({"background": hex_of(bg), "tol": args.tol} | ink_bbox(mask, (x0, y0), scale) |
            {"axis": args.axis, "min_gap": args.min_gap,
             "bands": ink_bands(mask, (x0, y0), scale, args.axis, args.min_gap)})


def offsets(a: dict, b: dict, limit: float | None) -> dict:
    """B - A for two `measure` results."""
    delta = None
    if a["box"] and b["box"]:
        delta = [round(b["box"][0] - a["box"][0], 2), round(b["box"][1] - a["box"][1], 2),
                 round(b["width"] - a["width"], 2), round(b["height"] - a["height"], 2)]
    band_dy = [round(y["start"] - x["start"], 2) for x, y in zip(a["bands"], b["bands"])]
    differ = len(a["bands"]) != len(b["bands"])
    worst = max(map(abs, (delta or []) + band_dy), default=0.0)
    ok = limit is None or (worst <= limit and not differ and (a["box"] is None) == (b["box"] is None))
    return {"bbox_delta": delta, "band_counts": [len(a["bands"]), len(b["bands"])], "band_dy": band_dy,
            "counts_differ": differ, "max_offset": worst, "limit": limit, "pass": ok}


def bbox_line(r: dict) -> str:
    if r["box"] is None:
        return f"no ink (bg {r['background']}, tol {r['tol']:g})"
    return (f"ink box {', '.join(f'{v:g}' for v in r['box'])}  ({r['width']:g} x {r['height']:g} pt, "
            f"{r['ink_pixels']} ink px; bg {r['background']}, tol {r['tol']:g})")


def band_lines(r: dict) -> list[str]:
    return [f"  {r['axis']} {b['start']:g}-{b['end']:g}  size {b['size']:g}" +
            ("" if b["gap"] is None else f"  gap {b['gap']:g}") for b in r["bands"]]


def components(mask: np.ndarray, eight: bool = True) -> tuple[np.ndarray, int]:
    """Connected components (8- or 4-neighbour) of a boolean mask: labels 1..n, 0 off the mask.
    Each pixel takes the smallest pixel index among its neighbours, plus pointer jumping, until stable."""
    h, w = mask.shape
    off = h * w
    lab = np.where(mask, np.arange(off).reshape(h, w), off)
    steps = [(dy, dx) for dy in (-1, 0, 1) for dx in (-1, 0, 1) if (dy or dx) and (eight or not (dy and dx))]
    while True:
        p = np.pad(lab, 1, constant_values=off)
        new = lab
        for dy, dx in steps:
            new = np.minimum(new, p[1 + dy:1 + dy + h, 1 + dx:1 + dx + w])
        flat = np.append(np.where(mask, new, off).ravel(), off)
        while not np.array_equal(jumped := flat[flat], flat):
            flat = jumped
        new = flat[:-1].reshape(h, w)
        if np.array_equal(new, lab):
            break
        lab = new
    ids = np.unique(lab[mask])
    labels = np.zeros((h, w), dtype=np.int64)
    labels[mask] = np.searchsorted(ids, lab[mask]) + 1
    return labels, len(ids)


def has_hole(ys: np.ndarray, xs: np.ndarray) -> bool:
    """True if the component's bbox has non-component pixels not 4-connected to its outside (a ring)."""
    comp = np.zeros((ys.max() - ys.min() + 3, xs.max() - xs.min() + 3), dtype=bool)
    comp[ys - ys.min() + 1, xs - xs.min() + 1] = True
    outside, _ = components(~comp, eight=False)
    return bool((~comp & (outside != outside[0, 0])).any())


def find_dots(pixels: np.ndarray, origin: tuple[int, int], scale: float, args) -> dict:
    """Dots = 8-connected ink components, minus noise (area < --min-area px², diameter < --min-d pt)."""
    mask, bg = ink_mask(pixels, args.bg, args.tol)
    labels, n = components(mask)
    ys, xs = np.nonzero(labels)
    lab = labels[ys, xs]
    order = np.argsort(lab, kind="stable")
    raw = [i for i in np.split(order, np.cumsum(np.bincount(lab, minlength=n + 1)[1:])[:-1]) if len(i)]
    raw = [i for i in raw if len(i) >= args.min_area]

    def diam(i):  # equivalent diameter (pt) of a component given by its pixel indices
        return 2 * (len(i) / np.pi) ** 0.5 / scale

    median_d = float(np.median([diam(i) for i in raw])) if raw else 0.0
    min_d = 0.15 * median_d if args.min_d is None else args.min_d
    kept = [i for i in raw if diam(i) >= min_d]
    dots = []
    for i in kept:
        y, x = ys[i], xs[i]
        w, h = x.max() - x.min() + 1, y.max() - y.min() + 1
        mean = pixels[y, x].mean(axis=0)
        dots.append({"x": pt(origin[0] + x.mean() + 0.5, scale), "y": pt(origin[1] + y.mean() + 0.5, scale),
                     "d": round(diam(i), 2), "w": pt(w, scale), "h": pt(h, scale), "area_px": len(i),
                     "aspect": round(float(max(w, h) / min(w, h)), 2), "kind": "ring" if has_hole(y, x) else "filled",
                     "delta": int(round(np.abs(mean - np.array(bg)).max()))})
    median_area = float(np.median([d["area_px"] for d in dots])) if dots else 0.0
    for d in dots:
        d["merged"] = bool(d["aspect"] > 1.3 or d["area_px"] > 1.6 * median_area)
    return {"background": hex_of(bg), "tol": args.tol, "min_area": args.min_area, "min_d": round(min_d, 2),
            "dropped": n - len(kept), "dots": dots}


def dot_stats(r: dict, centre: tuple[float, float], args) -> dict:
    """Region summary of `find_dots`. Gaps are edge to edge: centre distance minus both equivalent radii."""
    dots = r["dots"]
    if args.ring and dots:
        cx, cy = np.mean([d["x"] for d in dots]), np.mean([d["y"] for d in dots])
        dots.sort(key=lambda d: np.arctan2(d["x"] - cx, cy - d["y"]) % (2 * np.pi))  # clockwise from 12 o'clock
    else:
        dots.sort(key=lambda d: (d[args.axis], d["y" if args.axis == "x" else "x"]))
    for k, d in enumerate(dots):
        d["i"] = k

    def gap(a, b):
        return round(float(np.hypot(a["x"] - b["x"], a["y"] - b["y"])) - (a["d"] + b["d"]) / 2, 2)

    ds, deltas = [d["d"] for d in dots], sorted(d["delta"] for d in dots)
    s = {"count": len(dots), "order": "angle" if args.ring else f"axis {args.axis}",
         "gap_kind": "edge (centre distance - radii)",
         "d_min": min(ds, default=None), "d_median": round(float(np.median(ds)), 2) if ds else None,
         "d_max": max(ds, default=None), "d_spread": round(max(ds) - min(ds), 2) if ds else None,
         "filled": sum(d["kind"] == "filled" for d in dots), "rings": sum(d["kind"] == "ring" for d in dots),
         "merged": sum(d["merged"] for d in dots),
         "delta_min": deltas[0] if deltas else None, "delta_max": deltas[-1] if deltas else None,
         "classes": None, "min_gap": None, "max_gap": None, "symmetry": {}}
    if len(deltas) > 1:
        jumps = np.diff(deltas)
        k = int(np.argmax(jumps))
        if jumps[k] > (deltas[-1] - deltas[0]) / 2 and jumps[k] >= 16:  # two clearly separated groups
            cut = (deltas[k] + deltas[k + 1]) / 2
            for d in dots:
                d["class"] = "ink" if d["delta"] > cut else "track"
            s["classes"] = {"ink": sum(d["delta"] > cut for d in dots), "track": sum(d["delta"] < cut for d in dots),
                            "cut": cut}
    if len(dots) > 1:
        a, b = min(((a, b) for a in dots for b in dots if a["i"] < b["i"]), key=lambda p: gap(*p))
        s["min_gap"] = {"gap": gap(a, b), "dots": [a["i"], b["i"]]}
        pairs = list(zip(dots, dots[1:] + dots[:1])) if args.ring else list(zip(dots, dots[1:]))
        a, b = max(pairs, key=lambda p: gap(*p))
        s["max_gap"] = {"gap": gap(a, b), "dots": [a["i"], b["i"]]}
    for axis in ("x", "y") if args.sym == "both" else (args.sym,):
        if not dots:
            continue
        line = centre[0] if axis == "x" else centre[1]
        far = []
        for d in dots:
            mx, my = (2 * line - d["x"], d["y"]) if axis == "x" else (d["x"], 2 * line - d["y"])
            far.append((min(np.hypot(o["x"] - mx, o["y"] - my) for o in dots), d["d"]))
        s["symmetry"][axis] = {"line": round(line, 2), "max": round(float(max(f for f, _ in far)), 2),
                               "mean": round(float(np.mean([f for f, _ in far])), 2),
                               "unmatched": int(sum(f > dd / 2 for f, dd in far))}
    return s


def dots_line(r: dict) -> str:
    if not r["count"]:
        return f"0 dots ({r['dropped']} dropped as noise; bg {r['background']}, tol {r['tol']:g})"
    parts = [f"{r['count']} dots ({r['dropped']} dropped)",
             f"d {r['d_min']:g}/{r['d_median']:g}/{r['d_max']:g} pt (spread {r['d_spread']:g})",
             f"{r['filled']} filled {r['rings']} ring", f"{r['merged']} merged",
             f"Δ {r['delta_min']}-{r['delta_max']}" + ("" if r["classes"] is None else
                                                      f" ({r['classes']['ink']} ink / {r['classes']['track']} track)")]
    if r["min_gap"]:
        parts.append("gap min {:g} #{}-#{}, max {:g} #{}-#{} pt (edge, {})".format(
            r["min_gap"]["gap"], *r["min_gap"]["dots"], r["max_gap"]["gap"], *r["max_gap"]["dots"], r["order"]))
    parts += [f"sym {k} max {v['max']:g} mean {v['mean']:g} pt, {v['unmatched']} unmatched"
              for k, v in r["symmetry"].items()]
    return " · ".join(parts)


def dot_lines(r: dict) -> list[str]:
    return [f"  #{d['i']} {d['x']:g},{d['y']:g}  d {d['d']:g} ({d['w']:g}x{d['h']:g}) {d['kind']}  Δ {d['delta']}"
            + (f" {d['class']}" if "class" in d else "") + ("  MERGED?" if d["merged"] else "") for d in r["dots"]]


def frames_summary(frames: list[dict]) -> dict:
    """Worst values over a frame sequence, each with its frame index (0-based)."""
    c = [f["count"] for f in frames]
    steps = [abs(b - a) for a, b in zip(c, c[1:])]

    def pick(key, worst, value):
        ks = [k for k, f in enumerate(frames) if f[key]]
        k = worst(ks, key=lambda k: value(frames[k])) if ks else None
        return None if k is None else {"value": value(frames[k]), "frame": k}

    return {"count_min": min(c), "count_max": max(c),
            "count_change": None if not steps else {"value": max(steps), "frame": int(np.argmax(steps)) + 1},
            "min_gap": pick("min_gap", min, lambda f: f["min_gap"]["gap"]),
            "max_gap": pick("max_gap", max, lambda f: f["max_gap"]["gap"]),
            "worst_symmetry": pick("symmetry", max, lambda f: max(v["max"] for v in f["symmetry"].values()))}


# --- CLI ---------------------------------------------------------------------------------------------

def colour_spec(spec: str, args) -> tuple:
    if "@" not in spec:
        return parse_hex(spec)
    path, coords = spec.rsplit("@", 1)
    img = load(path)
    scale = scale_for(img, args)
    if coords.count(",") == 1:
        return parse_hex(sample_at(img, *nums(coords, 2), scale)["hex"])
    return parse_hex(region_stats(crop(img, nums(coords, 4), scale))["mean"])


def show(result: dict, as_json: bool, lines: list[str]) -> None:
    print(json.dumps(result) if as_json else "\n".join(lines))


def dots_frame(path: str, rect: list[float], args) -> dict:
    img = load(path)
    scale = scale_for(img, args)
    x0, y0, x1, y1 = px_rect(img, rect, scale)
    r = find_dots(img[y0:y1, x0:x1], (x0, y0), scale, args)
    return {"png": path, "scale": scale} | r | dot_stats(r, (pt((x0 + x1) / 2, scale), pt((y0 + y1) / 2, scale)), args)


def run(args) -> int:
    if args.cmd == "dots":
        rect = nums(args.rect, 4)
        frames = [dots_frame(p, rect, args) for p in args.pngs]
        lines = []
        for k, f in enumerate(frames):
            lines.append((f"frame {k} {Path(f['png']).name}: " if len(frames) > 1 else "") + dots_line(f))
            lines += dot_lines(f) if args.dots_list else []
        if len(frames) == 1:
            show({"rect": rect} | frames[0], args.json, lines)
            return 0
        s = frames_summary(frames)

        def at(v):
            return "n/a" if v is None else f"{v['value']:g} (frame {v['frame']})"

        lines.append(f"{len(frames)} frames: count {s['count_min']}-{s['count_max']}, max |Δcount| "
                     f"{at(s['count_change'])}, min gap {at(s['min_gap'])}, max gap {at(s['max_gap'])}, "
                     f"worst symmetry {at(s['worst_symmetry'])} pt")
        show({"rect": rect, "frames": frames, "summary": s}, args.json, lines)
        return 0
    if args.cmd == "compare":
        img_a, img_b = load(args.a), load(args.png)
        scale = scale_for(img_a, args)
        if img_a.shape != img_b.shape:
            sys.exit(f"A is {img_a.shape[1]}x{img_a.shape[0]}px, B {img_b.shape[1]}x{img_b.shape[0]}px: "
                     "compare needs the same size")
        rect = nums(args.rect, 4)
        a, b = measure(img_a, rect, scale, args), measure(img_b, rect, scale, args)
        r = offsets(a, b, args.max_offset)
        dy = ", ".join(f"{v:+g}" for v in r["band_dy"]) or "-"
        show({"scale": scale, "rect": rect, "a": a, "b": b} | r, args.json, [
            f"A {bbox_line(a)}", f"B {bbox_line(b)}",
            "bbox B - A: " + ("n/a (no ink in one image)" if r["bbox_delta"] is None else
                              "dx {:+g} dy {:+g} dw {:+g} dh {:+g} pt".format(*r["bbox_delta"])),
            f"bands A {r['band_counts'][0]}, B {r['band_counts'][1]}"
            + (" (COUNTS DIFFER: dy paired in order)" if r["counts_differ"] else "") + f"; band dy {dy} pt",
            f"max offset {r['max_offset']:g} pt" + ("" if r["limit"] is None else
                                                      f" (limit {r['limit']:g}: {'pass' if r['pass'] else 'FAIL'})")])
        return 0 if r["pass"] else 1
    if args.cmd == "diff":
        r = compare(colour_spec(args.a, args), colour_spec(args.b, args))
        show(r, args.json, [(f"{r['a']} vs {r['b']}: ΔE2000 {r['delta_e']}, contrast {r['contrast']}:1, "
                             f"ΔRGB {r['delta_rgb']}")])
        return 0
    img = load(args.png)
    scale = scale_for(img, args)
    if args.cmd == "at":
        pts = [sample_at(img, *nums(p, 2), scale) for p in args.points]
        show({"scale": scale, "points": pts}, args.json, [f"{p['x']:g},{p['y']:g}  {p['hex']}" for p in pts])
        return 0
    rect = nums(args.rect, 4)
    pixels = crop(img, rect, scale)
    head = {"scale": scale, "rect": rect}
    if args.cmd == "region":
        r = region_stats(pixels)
        show(head | r, args.json, [
            f"mean {r['mean']}  stdev {r['stdev']}  max ΔE2000 {r['max_delta_e']}  ({r['pixels']} px)",
            "top " + ", ".join(f"{t['hex']} {t['share']:.1%}" for t in r["top"])])
        return 0
    if args.cmd in ("bbox", "bands"):
        r = measure(img, rect, scale, args)
        if args.cmd == "bbox":
            r = {k: r[k] for k in ("background", "tol", "ink_pixels", "box", "width", "height")}
            show(head | r, args.json, [bbox_line(r)])
        else:
            r = {k: r[k] for k in ("background", "tol", "axis", "min_gap", "bands")}
            title = f"{len(r['bands'])} bands (bg {r['background']}, tol {r['tol']:g}, min gap {r['min_gap']:g} pt)"
            show(head | r, args.json, [title, *band_lines(r)])
        return 0
    if args.cmd == "contrast":
        r = text_contrast(pixels, args.min)
        if r["text"] == r["background"]:
            print(f"no text: region is uniform {r['background']}", file=sys.stderr)
        show(head | r, args.json, [(
            f"text {r['text']} on {r['background']}: {r['contrast']}:1  AA {'pass' if r['aa'] else 'FAIL'}  "
            f"AAA {'pass' if r['aaa'] else 'FAIL'}  (min {r['min']}: {'pass' if r['pass'] else 'FAIL'})")])
        return 0 if r["pass"] else 1
    r = min_gap(pixels, parse_hex(args.fg), parse_hex(args.bg), args.tol)
    r["gap_pt"] = None if r["gap_px"] is None else round(r["gap_px"] / scale, 2)
    show(head | r, args.json, [
        f"fg {r['fg']} ({r['fg_pixels']} px) to bg {r['bg']} ({r['bg_pixels']} px), ΔE tol {r['tol']}: " +
        ("no pixels in one of the masks" if r["gap_pt"] is None else
         f"min gap {r['gap_pt']} pt ({r['gap_px']} px between pixel centres)")])
    return 0


def dots_selftest(bg, ink) -> list[tuple[str, bool]]:
    def canvas(w, h):
        img = np.empty((h, w, 3), dtype=np.int64)
        img[:] = bg
        return img

    def disk(img, cx, cy, r, rgb, inner=0.0, aa=False):
        """Pixel (centre i+0.5) inked if within r of (cx, cy) and not within inner; aa: 1 px linear edge."""
        yy, xx = np.mgrid[0:img.shape[0], 0:img.shape[1]] + 0.5
        dist = np.hypot(xx - cx, yy - cy)
        cover = np.clip(r + 0.5 - dist, 0, 1) if aa else (dist <= r) & (dist >= inner)
        img[:] = np.rint(img * (1 - cover[..., None]) + np.array(rgb) * cover[..., None]).astype(np.int64)

    def dots_of(img, scale=1, **kw):
        opts = argparse.Namespace(bg=None, tol=24.0, min_area=4, min_d=None, ring=False, axis="x", sym="x")
        for k, v in kw.items():
            setattr(opts, k, v)
        h, w = img.shape[:2]
        r = find_dots(img, (0, 0), scale, opts)
        return r | dot_stats(r, (w / 2 / scale, h / 2 / scale), opts)

    checks = []
    two = np.zeros((4, 4), dtype=bool)
    two[0, 0] = two[1, 1] = True
    checks.append(("components 8- vs 4-neighbour", components(two)[1] == 1 and components(two, eight=False)[1] == 2))
    # a regular ring of 12 dots (r 4 px) on a circle of radius 40 px, centred in the region
    ring = canvas(120, 120)
    for k in range(12):
        a = k * np.pi / 6
        disk(ring, 60 + 40 * np.sin(a), 60 - 40 * np.cos(a), 4, ink)
    r = dots_of(ring, ring=True, sym="both")
    chord = 2 * 40 * np.sin(np.pi / 12) - r["d_median"]
    checks += [("dots ring count 12, all filled, none merged", (r["count"], r["filled"], r["merged"]) == (12, 12, 0)),
               ("dots ring gaps equal (edge)", abs(r["min_gap"]["gap"] - chord) < 0.6
                and abs(r["max_gap"]["gap"] - chord) < 0.6),
               ("dots ring order clockwise from top", r["dots"][0]["y"] < 25 and r["dots"][3]["x"] > 95),
               ("dots ring symmetric x and y", all(v["max"] < 0.2 and v["unmatched"] == 0
                                                   for v in r["symmetry"].values()) and len(r["symmetry"]) == 2),
               ("dots scale to points", dots_of(ring, scale=2)["d_median"] == round(r["d_median"] / 2, 2))]
    # a row: 4 dots and a merged (overlapping) pair; ordered along x
    row = canvas(110, 20)
    for x in (10, 30, 50, 70, 90, 97):
        disk(row, x, 10, 4, ink)
    r = dots_of(row)
    checks += [("dots merged pair: one component, flagged", r["count"] == 5 and r["merged"] == 1
                and r["dots"][-1]["merged"] and r["dots"][-1]["aspect"] > 1.3),
               ("dots largest gap along x", r["max_gap"]["dots"] == [0, 1] or r["max_gap"]["dots"] == [3, 4])]
    # an anti-aliased dot: equivalent diameter close to the true 12 px, filled
    soft = canvas(30, 30)
    disk(soft, 15, 15, 6, ink, aa=True)
    r = dots_of(soft)
    checks.append(("dots anti-aliased dot", r["count"] == 1 and r["filled"] == 1 and abs(r["d_median"] - 12) < 1.5))
    # a hollow ring dot touching the region edge, a filled dot, a 2 px speck (noise), a faint track dot
    mix = canvas(60, 20)
    disk(mix, 6, 10, 6, ink, inner=3)
    disk(mix, 30, 10, 6, ink)
    mix[2, 50:52] = ink
    disk(mix, 50, 12, 6, (0xC0, 0xC0, 0xC0))
    r = dots_of(mix)
    checks += [("dots ring touching edge is a ring", r["dots"][0]["kind"] == "ring" and r["rings"] == 1
                and r["filled"] == 2),
               ("dots noise dropped", r["count"] == 3 and r["dropped"] == 1),
               ("dots ink/track classes", r["classes"] is not None and
                (r["classes"]["ink"], r["classes"]["track"]) == (2, 1) and r["dots"][2]["class"] == "track"),
               ("dots no classes when deltas close", dots_of(row)["classes"] is None),
               ("dots result is JSON-serialisable", bool(json.dumps(r)))]
    # a two-frame sequence: the second frame loses a dot
    less = canvas(120, 120)
    for k in range(11):
        a = k * np.pi / 6
        disk(less, 60 + 40 * np.sin(a), 60 - 40 * np.cos(a), 4, ink)
    f = [dots_of(ring, ring=True), dots_of(less, ring=True)]
    s = frames_summary(f)
    checks += [("dots frames count change", (s["count_min"], s["count_max"]) == (11, 12)
                and s["count_change"] == {"value": 1, "frame": 1}),
               ("dots frames worst gap and symmetry in frame 1", s["max_gap"]["frame"] == 1
                and s["worst_symmetry"]["frame"] == 1 and f[1]["symmetry"]["x"]["unmatched"] >= 1)]
    return checks


def selftest() -> int:
    bg, ink, accent = (0xF9, 0xFA, 0xF5), (0x1C, 0x1C, 0x1C), (0xB8, 0x32, 0x5A)
    img = np.empty((60, 90, 3), dtype=np.int64)
    img[:] = bg
    img[10:20, 10:40] = ink           # "text"
    img[10:20, 9] = (0x8A, 0x8B, 0x88)  # anti-aliased edge: must not win
    img[10:20, 50:53] = accent        # "dot", 10 px right of the text
    checks = [
        ("at median", sample_at(img, 15, 15, 1)["hex"] == "#1C1C1C"),
        ("at edge median", sample_at(img, 9, 15, 1)["hex"] == "#8A8B88"),
        ("region uniform", region_stats(img[30:60, :])["max_delta_e"] == 0),
        ("region top", region_stats(img)["top"][0]["hex"] == "#F9FAF5"),
        ("diff same", compare(bg, bg)["delta_e"] == 0 and compare(bg, bg)["contrast"] == 1),
        ("diff white/black 21:1", compare((255,) * 3, (0,) * 3)["contrast"] == 21),
    ]
    c = text_contrast(img[5:25, 5:45], 4.5)
    checks += [("contrast picks ink on bg", (c["text"], c["background"]) == ("#1C1C1C", "#F9FAF5")),
               ("contrast ink ≈16:1", 15.5 < c["contrast"] < 17 and c["aaa"])]
    a = text_contrast(img[5:25, 45:58], 4.5)
    checks.append(("contrast accent passes AA", a["text"] == "#B8325A" and a["aa"]))
    g = min_gap(img, accent, ink, 10)
    checks.append(("gap 11 px between centres", g["gap_px"] == 11.0))
    checks.append(("gap empty mask", min_gap(img, (0, 255, 0), ink, 10)["gap_px"] is None))
    # bbox / bands / compare: two "lines" of text, B shifted down 2 px (and the second line 1 px wider)
    page = np.empty((80, 60, 3), dtype=np.int64)
    page[:] = bg
    page[10:16, 5:40] = ink
    page[17:18, 8:9] = ink            # "descender" 1 px below line 1
    page[30:36, 5:50] = ink
    page[20:22, 52:54] = (0xEE, 0xEF, 0xEA)  # faint smudge: Δ 11 < tol 24, not ink
    shifted = np.empty_like(page)
    shifted[:] = bg
    shifted[12:38] = page[10:36]
    shifted[32:38, 50] = ink
    opts = argparse.Namespace(bg=None, tol=24.0, axis="y", min_gap=0.0)
    ma, mb = measure(page, [0, 0, 60, 80], 1, opts), measure(shifted, [0, 0, 60, 80], 1, opts)
    checks += [("bbox box and size", ma["box"] == [5, 10, 50, 36] and (ma["width"], ma["height"]) == (45, 26)),
               ("bbox background commonest", ma["background"] == "#F9FAF5"),
               ("bbox ink pixel count", ma["ink_pixels"] == 6 * 35 + 1 + 6 * 45),
               ("bbox scaled to points", measure(page, [0, 0, 30, 40], 2, opts)["box"] == [2.5, 5, 25, 18]),
               ("bbox no ink", measure(page, [0, 50, 60, 80], 1, opts)["box"] is None),
               ("bands split by descender gap",
                [(b["start"], b["end"]) for b in ma["bands"]] == [(10, 16), (17, 18), (30, 36)]),
               ("bands gap to previous", [b["gap"] for b in ma["bands"]] == [None, 1, 12])]
    merged = measure(page, [0, 0, 60, 80], 1, argparse.Namespace(bg=None, tol=24.0, axis="y", min_gap=2.0))
    checks.append(("bands --min-gap merges", [(b["start"], b["end"], b["gap"]) for b in merged["bands"]]
                   == [(10, 18, None), (30, 36, 12)]))
    cols = measure(page, [0, 0, 60, 80], 1, argparse.Namespace(bg=bg, tol=24.0, axis="x", min_gap=0.0))
    checks.append(("bands --axis x", [(b["start"], b["end"]) for b in cols["bands"]] == [(5, 50)]))
    o = offsets(ma, mb, 1)
    checks += [("compare bbox delta", o["bbox_delta"] == [0, 2, 1, 0]),
               ("compare band dy", o["band_dy"] == [2, 2, 2] and not o["counts_differ"]),
               ("compare limit 1 fails, 2 passes", not o["pass"] and offsets(ma, mb, 2)["pass"]),
               ("compare same passes at 0", offsets(ma, ma, 0)["pass"] and offsets(ma, ma, 0)["max_offset"] == 0),
               ("compare counts differ fails", offsets(ma, merged, 100)["counts_differ"]
                and not offsets(ma, merged, 100)["pass"] and offsets(ma, merged, None)["pass"])]
    checks += dots_selftest(bg, ink)
    for name, ok in checks:
        print(f"{'ok  ' if ok else 'FAIL'} {name}")
    return 0 if all(ok for _, ok in checks) else 1


def main() -> int:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", default=argparse.SUPPRESS, help="machine output")
    common.add_argument("--scale", type=float, default=argparse.SUPPRESS, help="pixels per point")
    common.add_argument("--px", action="store_true", default=argparse.SUPPRESS, help="coordinates are pixels")
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0], parents=[common])
    parser.add_argument("--selftest", action="store_true")
    sub = parser.add_subparsers(dest="cmd")
    p = sub.add_parser("at", parents=[common]); p.add_argument("png"); p.add_argument("points", nargs="+")
    p = sub.add_parser("region", parents=[common]); p.add_argument("png"); p.add_argument("rect")
    p = sub.add_parser("diff", parents=[common]); p.add_argument("a"); p.add_argument("b")
    p = sub.add_parser("contrast", parents=[common]); p.add_argument("png"); p.add_argument("rect")
    p.add_argument("--min", type=float, default=4.5)
    p = sub.add_parser("gap", parents=[common]); p.add_argument("png"); p.add_argument("rect")
    p.add_argument("--fg", required=True); p.add_argument("--bg", required=True)
    p.add_argument("--tol", type=float, default=10)
    inkbg = argparse.ArgumentParser(add_help=False)
    inkbg.add_argument("--bg", help="background hex (default: the region's commonest colour)")
    inkbg.add_argument("--tol", type=float, default=24, help="ink if max per-channel |Δ| (0-255) from bg > tol")
    p = sub.add_parser("dots", parents=[common, inkbg])
    p.add_argument("pngs", nargs="+", metavar="png"); p.add_argument("rect")
    order = p.add_mutually_exclusive_group()
    order.add_argument("--ring", action="store_true", help="order dots by angle around their centroid")
    order.add_argument("--axis", choices=("x", "y"), default="x", help="order dots along this axis")
    p.add_argument("--sym", choices=("x", "y", "both"), default="x", help="mirror line: vertical (x), horizontal (y)")
    p.add_argument("--min-d", type=float, help="drop dots under this diameter (pt; default 0.15 x median)")
    p.add_argument("--min-area", type=float, default=4, help="drop components under this many px²")
    p.add_argument("--dots-list", action="store_true", help="print every dot")
    ink = argparse.ArgumentParser(add_help=False, parents=[inkbg])
    ink.add_argument("--axis", choices=("y", "x"), default="y", help="bands of rows (y) or columns (x)")
    ink.add_argument("--min-gap", type=float, default=0, help="merge bands closer than this (points)")
    for name in ("bbox", "bands"):
        p = sub.add_parser(name, parents=[common, ink]); p.add_argument("png"); p.add_argument("rect")
    p = sub.add_parser("compare", parents=[common, ink]); p.add_argument("a"); p.add_argument("png", metavar="b")
    p.add_argument("rect"); p.add_argument("--max-offset", type=float, help="exit 1 if any offset exceeds (pt)")
    args = parser.parse_args()
    if args.cmd in ("bbox", "bands", "compare", "dots") and args.bg is not None:
        args.bg = parse_hex(args.bg)
    for name, default in (("json", False), ("scale", None), ("px", False)):
        setattr(args, name, getattr(args, name, default))
    if args.selftest:
        return selftest()
    if not args.cmd:
        parser.error("give a subcommand or --selftest")
    paths = ([] if args.cmd == "diff" else args.pngs if args.cmd == "dots" else
             [args.png] + ([args.a] if args.cmd == "compare" else []))
    for path in paths:
        if not Path(path).is_file():
            sys.exit(f"no such file: {path}")
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
