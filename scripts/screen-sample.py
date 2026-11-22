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

`--json` (before or after the subcommand) prints one JSON object, e.g.:
    at       {"scale": 3, "points": [{"x": 70, "y": 370, "hex": "#1C1C1C"}]}
    region   {"scale": 3, "rect": [10, 600, 390, 700], "pixels": 342000, "mean": "#F9FAF5",
              "stdev": [0.0, 0.0, 0.0], "max_delta_e": 0.0, "top": [{"hex": "#F9FAF5", "share": 1.0}]}
    diff     {"a": "#F9FAF5", "b": "#1C1C1C", "delta_e": 89.1, "contrast": 16.24, "delta_rgb": [-221, -222, -217]}
    contrast {"scale": 3, "rect": [...], "background": "#F9FAF5", "text": "#1C1C1C", "contrast": 16.24,
              "aa": true, "aaa": true, "min": 4.5, "pass": true}
    gap      {"scale": 3, "rect": [...], "fg": "#B8325A", "bg": "#1C1C1C", "tol": 10, "fg_pixels": 1200,
              "bg_pixels": 3400, "gap_pt": 4.33, "gap_px": 13.0}     # gap_pt null when a mask is empty
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


def crop(img: np.ndarray, rect: list[float], scale: float) -> np.ndarray:
    x0, y0, x1, y1 = (int(round(v * scale)) for v in rect)
    h, w = img.shape[:2]
    x0, x1 = sorted((max(0, min(w, x0)), max(0, min(w, x1))))
    y0, y1 = sorted((max(0, min(h, y0)), max(0, min(h, y1))))
    if x1 <= x0 or y1 <= y0:
        sys.exit(f"empty region {rect} (image is {w}x{h}px, scale {scale})")
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


def run(args) -> int:
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
    args = parser.parse_args()
    for name, default in (("json", False), ("scale", None), ("px", False)):
        setattr(args, name, getattr(args, name, default))
    if args.selftest:
        return selftest()
    if not args.cmd:
        parser.error("give a subcommand or --selftest")
    if args.cmd != "diff" and not Path(args.png).is_file():
        sys.exit(f"no such file: {args.png}")
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
