#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = [
#   "pillow==12.0.0",
#   "numpy==2.5.5",
#   "av==19.0.2",
# ]
# ///
"""Crop, contact-sheet and video-measure tool, so nobody writes ad-hoc PIL scripts for these jobs.

    uv run scripts/image-ops.py crop    <png|svg> x0,y0,x1,y1 [--zoom K] [--svg-size N] [--out FILE]
    uv run scripts/image-ops.py montage <png|svg ...> [--sizes 1024,58,29] [--labels a,b] [--apple] [--mask]
                                        [--cols N] [--bg HEX] [--out FILE]
    uv run scripts/image-ops.py frames  <mp4> [--from S] [--to S] [--every S] [--out DIR]
    uv run scripts/image-ops.py track   <mp4> x0,y0,x1,y1 [--from S] [--to S] [--min-change L] [--event-threshold C]
                                        [--match HEX[:TOL] ...] [--scroll-indicator] [--json]
    uv run scripts/image-ops.py grid    'dir/{col}-{row}.png' --cols a,b,c --rows x,y [--col-label a=TEXT ...]
                                        [--size PX] [--bg HEX] [--out FILE]
    uv run scripts/image-ops.py strip   <mp4> [x0,y0,x1,y1] (--every S | --at t1,t2,...) [--from S] [--to S]
                                        [--height PX] [--out FILE]
    uv run scripts/image-ops.py --selftest

Coordinates are in points. The scale comes from the image/video width (1206 -> 3, 804 -> 2, 402 -> 1); other
widths fail unless `--scale N` is given, or `--px` (coordinates are pixels). Inputs are only read; outputs
default to $TMPDIR/image-ops/ and their paths are printed.

- crop: the region, optionally upscaled K times: an integer K with nearest neighbour (to inspect single pixels), a
  fractional K (e.g. 2.5) with LANCZOS. An SVG is rasterised at 1024 px (`--svg-size N`) with rsvg-convert and the
  coordinates are pixels of that raster.
- montage: one entry per input (label, then one column per size); each size is a LANCZOS downscale of the source
  shown at its true pixel size, plus a 4x nearest-neighbour zoom for sizes < 100. Entries fill a grid of columns
  so the sheet stays no taller than ~1.5x its width (`--cols N` to choose). `--mask`: iOS-like squircle mask.
  `--apple`: ONE ROW PER CANDIDATE (`--cols N` still wraps): sizes >= 100 are shown scaled to 256 px (the header
  says so), then Apple's own app icons (cache shared with design-review.py) at the sizes < 100, true size, in the
  same row. SVG needs rsvg-convert.
- frames: PNG per decoded frame named by its real timestamp (t0001.234.png) + frames.tsv (index, time, file).
  `--every S`: the first frame at or after each multiple of S. Recordings are variable frame rate.
- track: per frame the region's mean colour, luma (Rec. 709, 0-255) and `change` (mean abs pixel difference from
  the previous frame, 0-255, so motion at constant mean luma counts). Two reports:
  - transitions between two stable levels (held >= 0.1 s, within 3 luma) that differ by >= `--min-change`
    (default 10): the time luma crosses 10 % and 90 % of the change (searched up to the end of the next level;
    a crossing never reached is null with a `note`), duration, direction.
  - events: runs of frames whose change > `--event-threshold` (default 0.5; consecutive changed frames and gaps
    < 0.1 s merge), all of them: start, end, duration, peak change, mean colour/luma before (the frame before
    the event) -> after (its last frame), and the 10-90 % timing when luma moves monotonically (no step back
    > 5 % of the change) by >= 2; else a `note` says why not.
  A crossing or an event start is stamped at the first frame past it; its resolution is the gap to the previous
  frame (the change happened inside that gap). `--match HEX[:TOL]` (repeatable): per frame the share of region
  pixels within TOL (RGB Euclidean, default 24) of the colour; events show it before -> after.
  `--scroll-indicator`: per frame whether an iOS scroll indicator is in the region's right-edge 10 pt (a bar
  2.3-4 pt wide, 1.7-4.3 pt from the edge, >= 20 pt tall, contrasting by > 8 luma with the strip row's median)
  and its y-range in pt. `--json`: everything above.
- grid: PATTERN with {col} and {row}, one column per variant, one row per case, headers (`--col-label` renames)
  and row labels. Cells share one size: `--size PX` (long side), else the first image's, capped at 512. SVG via
  rsvg-convert. A missing file is a grey "missing" cell and a warning on stderr, not a failure.
- strip: frames side by side, each labelled with its real timestamp (3 decimals); `--every S` as in frames, or
  `--at t1,...` the first frame at or after each time. Optional crop region (same rules as crop).
"""

import argparse
import contextlib
import fractions
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import av
import numpy as np
from PIL import Image, ImageDraw, ImageFont

SCALES = {1206: 3, 804: 2, 402: 1}
OUT = Path(os.environ.get("TMPDIR", "/tmp")) / "image-ops"
ICON_IDS = [1110145109, 1108187841, 1108185179, 1069512882, 1584215688, 915056765]  # same as design-review.py
ICON_CACHE = Path(__file__).resolve().parent.parent / "docs/design/reference/home-icons"   # gitignored
STABLE_TOL, STABLE_HOLD = 3.0, 0.1
EVENT_THRESHOLD, EVENT_GAP, EVENT_MIN_LUMA = 0.5, 0.1, 2.0   # change: mean abs pixel difference, 0-255
MONO_TOL, MONO_REL = 0.5, 0.05   # monotonic: no step back > max(0.5 luma, 5 % of the change)
MATCH_TOL = 24.0
SCROLL_STRIP, SCROLL_WIDTH, SCROLL_GAP, SCROLL_MIN_RUN, SCROLL_CONTRAST = 10, (2.3, 4.0), (1.7, 4.3), 20, 8   # pt, luma
GRID_CAP = 512


def scale_for(width: int, args) -> float:
    if args.px:
        return 1
    if args.scale is not None:
        if args.scale <= 0:
            sys.exit("--scale must be > 0")
        return args.scale
    if width not in SCALES:
        sys.exit(f"width {width}px is not 1206/804/402: pass --scale N or --px")
    return SCALES[width]


def rect_px(s: str, scale: float, w: int, h: int) -> tuple[int, int, int, int]:
    parts = s.split(",")
    if len(parts) != 4:
        sys.exit(f"bad region {s!r}: expected x0,y0,x1,y1")
    x0, y0, x1, y1 = (int(round(float(v) * scale)) for v in parts)
    x0, x1 = sorted((max(0, min(w, x0)), max(0, min(w, x1))))
    y0, y1 = sorted((max(0, min(h, y0)), max(0, min(h, y1))))
    if x1 <= x0 or y1 <= y0:
        sys.exit(f"empty region {s} (image is {w}x{h}px, scale {scale})")
    return x0, y0, x1, y1


def out_path(given, name: str) -> Path:
    p = Path(given) if given else OUT / name
    p.parent.mkdir(parents=True, exist_ok=True)
    return p


# --- crop ------------------------------------------------------------------------------------------------

def crop(args) -> Path:
    svg = args.png.lower().endswith(".svg")
    im = rasterise(args.png, args.svg_size).convert("RGB") if svg else Image.open(args.png).convert("RGB")
    box = rect_px(args.rect, 1 if svg else scale_for(im.width, args), *im.size)   # SVG: px of the raster
    part = im.crop(box)
    if args.zoom <= 0:
        sys.exit("--zoom must be > 0")
    if args.zoom != 1:
        whole = float(args.zoom).is_integer()
        part = part.resize((round(part.width * args.zoom), round(part.height * args.zoom)),
                           Image.NEAREST if whole else Image.LANCZOS)
    zoom = f"{args.zoom:g}".replace(".", "_")
    out = out_path(args.out, f"{Path(args.png).stem}-crop-{'_'.join(map(str, box))}-x{zoom}.png")
    part.save(out)
    print(f"{out}  ({part.width}x{part.height}px, source px {box})")
    return out


# --- montage ---------------------------------------------------------------------------------------------

def rasterise(path: str, size: int = 1024) -> Image.Image:
    """An SVG rendered by rsvg-convert, size px on its longer side."""
    if not shutil.which("rsvg-convert"):
        sys.exit("SVG input needs rsvg-convert on PATH (brew librsvg); or pass a PNG")
    png = subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), "--keep-aspect-ratio", path],
                         check=True, capture_output=True).stdout
    return Image.open(io.BytesIO(png))


def load_icon(path: str) -> Image.Image:
    if path.endswith(".svg"):
        im = rasterise(path).convert("RGBA")
    else:
        im = Image.open(path).convert("RGBA")
    side = max(im.size)   # pad to a square, centred
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(im, ((side - im.width) // 2, (side - im.height) // 2))
    return square


def fetch_icons() -> list[tuple[Image.Image, str]]:
    """Apple's own app icons via the public iTunes lookup API; same cache as design-review.py's fetch_icons."""
    import urllib.request
    meta = ICON_CACHE / "icons.json"
    if not meta.exists():
        ICON_CACHE.mkdir(parents=True, exist_ok=True)
        try:
            url = "https://itunes.apple.com/lookup?country=us&id=" + ",".join(map(str, ICON_IDS))
            with urllib.request.urlopen(url, timeout=10) as r:
                res = json.load(r)["results"]
            for app in res:
                urllib.request.urlretrieve(app["artworkUrl512"], ICON_CACHE / f"{app['trackId']}.jpg")
            meta.write_text(json.dumps({str(a["trackId"]): a["trackName"].replace("Apple ", "") for a in res}))
        except Exception as e:
            print(f"--apple: icon fetch failed ({e}); skipping Apple rows", file=sys.stderr)
            return []
    names = json.loads(meta.read_text())
    return [(load_icon(str(ICON_CACHE / f"{i}.jpg")), names.get(str(i), "App")) for i in ICON_IDS
            if (ICON_CACHE / f"{i}.jpg").exists()]


def squircle(size: int) -> Image.Image:
    """iOS continuous-corner icon shape, approximated by a superellipse |x|^5 + |y|^5 = 1 (4x supersampled)."""
    n = size * 4
    t = (np.arange(n) + 0.5) / n * 2 - 1
    m = (np.abs(t)[None, :] ** 5 + np.abs(t)[:, None] ** 5) <= 1
    return Image.fromarray((m * 255).astype(np.uint8)).resize((size, size), Image.LANCZOS)


def montage(args) -> Path:
    """Without --apple: one entry per input, in a grid. With --apple: one row per candidate with the Apple icons
    beside it at the small sizes (a 1024 is shown at 256 px so rows stay short)."""
    sizes = [int(s) for s in args.sizes.split(",")]
    labels = args.labels.split(",") if args.labels else [Path(p).stem for p in args.inputs]
    if len(labels) != len(args.inputs):
        sys.exit(f"--labels has {len(labels)} names for {len(args.inputs)} inputs")
    rows = [(load_icon(p), l) for p, l in zip(args.inputs, labels)]
    refs = (getattr(args, "apple_icons", None) or fetch_icons()) if args.apple else []
    if args.apple:                                  # row mode: Apple refs at the small sizes inside each row
        shown, small = [min(s, 256) for s in sizes], [s for s in sizes if s < 100]
    else:                                           # grid mode: every size at its true pixel size
        shown, small = sizes, []
    bg = "#" + args.bg.lstrip("#")
    font = ImageFont.load_default(size=14)
    pad, label_w = 16, 150
    cols = [d + (pad + 4 * s if s < 100 else 0) for s, d in zip(sizes, shown)]
    ref_w = max(sum(small) + pad * (len(small) - 1), 80) if small else 0
    cols += [ref_w] * len(refs) if small else []
    row_h = max(max(shown), 4 * max([s for s in sizes if s < 100], default=0)) + 2 * pad
    row_w = label_w + sum(cols) + pad * (len(cols) + 1)
    n = len(rows)                      # grid: the fewest columns that keep the sheet <= 1.5x as tall as wide
    if args.cols is not None and args.cols < 1:
        sys.exit("--cols must be >= 1")
    ncol = args.cols or (1 if args.apple else
                         next(c for c in range(1, n + 1) if -(-n // c) * row_h + 28 <= 1.5 * c * row_w or c == n))
    sheet = Image.new("RGB", (row_w * ncol, 28 + row_h * -(-n // ncol)), bg)
    draw = ImageDraw.Draw(sheet)
    ink = "#000000" if sum(sheet.getpixel((0, 0))) > 382 else "#FFFFFF"
    heads = [f"{s}px" + (f" (shown at {d})" if d != s else "") + (" + 4x" if s < 100 else "")
             for s, d in zip(sizes, shown)] + [f"{name[:10]} {'/'.join(map(str, small))}" for _, name in (refs if small else [])]
    for g in range(ncol):
        x = g * row_w + label_w + pad
        for h, w in zip(heads, cols):
            draw.text((x, 6), h, fill=ink, font=font)
            x += w + pad

    def put(src: Image.Image, s: int, d: int, x: int, y: int, zoom: bool):
        icon = src.resize((s, s), Image.LANCZOS)
        if args.mask:
            icon.putalpha(Image.fromarray(np.minimum(np.asarray(icon.getchannel("A")), np.asarray(squircle(s)))))
        if d != s:
            icon = icon.resize((d, d), Image.LANCZOS)
        sheet.paste(icon, (x, y), icon)
        if zoom and s < 100:
            big = sheet.crop((x, y, x + s, y + s)).resize((4 * s, 4 * s), Image.NEAREST)
            sheet.paste(big, (x + s + pad, y))

    for r, (src, label) in enumerate(rows):
        x0, y = (r % ncol) * row_w, 28 + (r // ncol) * row_h
        draw.text((x0 + pad, y + row_h // 2 - 8), label[:18], fill=ink, font=font)
        x = x0 + label_w + pad
        for s, d, w in zip(sizes, shown, cols):
            put(src, s, d, x, y + pad, zoom=True)
            x += w + pad
        for ref, _ in refs if small else []:   # each Apple icon at the small sizes, true size, side by side
            for s in small:
                put(ref, s, s, x, y + pad, zoom=False)
                x += s + pad
            x += ref_w - (sum(small) + pad * (len(small) - 1))
    out = out_path(args.out, "montage.png")
    sheet.save(out)
    layout = (f"{n} rows (one per candidate, {len(refs)} Apple icons beside each at {'/'.join(map(str, small))} px)"
              if args.apple else f"{n} entries in {ncol} column(s) x {len(sizes)} sizes")
    print(f"{out}  ({sheet.width}x{sheet.height}px, {layout})")
    return out


# --- video -----------------------------------------------------------------------------------------------

def decode(path: str, t0: float, t1: float):
    """Yield (time, frame) using each frame's real timestamp (recordings are variable frame rate)."""
    with av.open(path) as c:
        for f in c.decode(video=0):
            t = float(f.time)
            if t > t1:
                break
            if t >= t0:
                yield t, f


def frames(args) -> Path:
    out = Path(args.out) if args.out else OUT / f"{Path(args.mp4).stem}-frames"
    out.mkdir(parents=True, exist_ok=True)
    rows, next_t = ["index\ttime\tfile"], args.start
    for i, (t, f) in enumerate(decode(args.mp4, args.start, args.end)):
        if args.every:
            if t < next_t:
                continue
            next_t += args.every * (1 + int((t - next_t) // args.every))
        name = f"t{t:08.3f}.png"
        f.to_image().save(out / name)
        rows.append(f"{i}\t{t:.3f}\t{name}")
    (out / "frames.tsv").write_text("\n".join(rows) + "\n")
    print(f"{out}  ({len(rows) - 1} frames)")
    return out


def parse_matches(specs) -> list[tuple[str, np.ndarray, float]]:
    """--match HEX[:TOL] -> (name, rgb, tolerance)."""
    out = []
    for spec in specs or []:
        hx, _, tol = spec.lstrip("#").partition(":")
        if len(hx) != 6:
            sys.exit(f"bad --match {spec!r}: expected HEX[:TOL], e.g. FF2D55:24")
        out.append(("#" + hx.upper(), np.array([int(hx[i:i + 2], 16) for i in (0, 2, 4)]), float(tol or MATCH_TOL)))
    return out


def match_share(reg: np.ndarray, rgb: np.ndarray, tol: float) -> float:
    """Share of the region's pixels within tol (RGB Euclidean) of rgb."""
    d = reg.astype(np.int32) - rgb
    return float(((d * d).sum(axis=-1) <= tol * tol).mean())


def scroll_indicator(reg: np.ndarray, scale: float):
    """(y0, y1) in pt from the region's top if an iOS scroll indicator is in its right-edge strip, else None.
    Ink = luma differing from the strip row's median by > SCROLL_CONTRAST. An indicator is a group of adjacent
    columns SCROLL_WIDTH pt wide, ending SCROLL_GAP pt from the region's right edge, whose longest ink run is
    >= SCROLL_MIN_RUN pt and filled (>= 80 % ink across the group: a vertical bar, not a diagonal or an edge).
    Calibrated on simulator screenshots (iOS 26, 3x): 3 pt wide, 3 pt from the edge, luma 162 on 249 (light),
    140 on 26 (dark); never seen in the recordings' sheet edges, wallpaper or text."""
    w = int(round(SCROLL_STRIP * scale))
    y = reg[:, -w:].astype(np.float32) @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    ink = np.abs(y - np.median(y, axis=1, keepdims=True)) > SCROLL_CONTRAST
    runs = []   # per column: (length, start) of its longest ink run
    for col in ink.T:
        e = np.flatnonzero(np.diff(np.concatenate(([0], col.astype(np.int8), [0]))))
        k = int(np.argmax(e[1::2] - e[::2])) if len(e) else -1
        runs.append((int(e[2 * k + 1] - e[2 * k]), int(e[2 * k])) if k >= 0 else (0, 0))
    tall = [r >= SCROLL_MIN_RUN * scale for r, _ in runs] + [False]
    c = 0
    while c < w:
        if not tall[c]:
            c += 1
            continue
        c1 = c
        while tall[c1 + 1]:
            c1 += 1
        width, gap = (c1 - c + 1) / scale, (w - 1 - c1) / scale
        n, y0 = max(runs[c:c1 + 1])
        if (c > 0 and SCROLL_WIDTH[0] <= width <= SCROLL_WIDTH[1] and SCROLL_GAP[0] <= gap <= SCROLL_GAP[1]
                and ink[y0:y0 + n, c:c1 + 1].mean() >= 0.8):
            return round(y0 / scale, 1), round((y0 + n) / scale, 1)
        c = c1 + 1
    return None


def series(path: str, rect: str, args, t0: float, t1: float, matches=(), scroll=False) -> list[dict]:
    """Per frame: mean colour, luma, `change` (mean abs pixel difference from the previous frame, 0-255), the
    --match shares and the scroll indicator."""
    out, box, prev = [], None, None
    for t, f in decode(path, t0, t1):
        img = f.to_ndarray(format="rgb24")
        if box is None:
            scale = scale_for(img.shape[1], args)
            box = rect_px(rect, scale, img.shape[1], img.shape[0])
        reg = img[box[1]:box[3], box[0]:box[2]]
        m = reg.reshape(-1, 3).mean(axis=0)
        p = {"t": round(t, 4), "hex": "#{:02X}{:02X}{:02X}".format(*(int(round(c)) for c in m)),
             "luma": round(float(m @ [0.2126, 0.7152, 0.0722]), 2),
             "change": 0.0 if prev is None else round(float((np.maximum(reg, prev) - np.minimum(reg, prev)).mean()), 3)}
        prev = reg
        if matches:
            p["match"] = {name: round(match_share(reg, rgb, tol), 4) for name, rgb, tol in matches}
        if scroll:
            ys = scroll_indicator(reg, scale)
            p["scroll"] = None if ys is None else [round(ys[0] + box[1] / scale, 1), round(ys[1] + box[1] / scale, 1)]
        out.append(p)
    if not out:
        sys.exit("no frames in that time window")
    return out


def first_cross(y: list[float], lo: int, hi: int, level: float, up: bool):
    """First index in lo..hi whose luma is at or past level, else None."""
    return next((k for k in range(lo, hi + 1) if (y[k] >= level if up else y[k] <= level)), None)


def timing(t: list[float], y: list[float], lo: int, hi: int, la: float, lb: float) -> dict:
    """10 % and 90 % crossings of la -> lb searched in frames lo..hi; a crossing not found is null + reason."""
    up, res = lb > la, {"resolution_ms": []}
    for frac, key in ((0.1, "t10"), (0.9, "t90")):
        level = la + frac * (lb - la)
        k = first_cross(y, lo, hi, level, up)
        res[key] = None if k is None else t[k]
        res["resolution_ms"].append(None if k is None else round((t[k] - t[k - 1]) * 1000, 1))
        if k is None:
            res.setdefault("note", f"luma never reached {level:.1f} ({frac:.0%}) by {t[hi]:.3f}s")
    res["duration_ms"] = None if None in (res["t10"], res["t90"]) else round((res["t90"] - res["t10"]) * 1000, 1)
    return res


def transitions(s: list[dict], min_change: float) -> list[dict]:
    t, y = [p["t"] for p in s], [p["luma"] for p in s]
    plateaus, i = [], 0   # (first, last, level)
    while i < len(y):
        j = i
        while j + 1 < len(y) and max(y[i:j + 2]) - min(y[i:j + 2]) <= STABLE_TOL:
            j += 1
        held = (t[j + 1] if j + 1 < len(t) else float("inf")) - t[i]
        if held >= STABLE_HOLD:
            plateaus.append((i, j, sum(y[i:j + 1]) / (j - i + 1)))
        i = j + 1
    found = []
    for (_, a1, la), (_, b1, lb) in zip(plateaus, plateaus[1:]):
        if abs(lb - la) < min_change:
            continue
        # search up to the end of the next plateau: its first frames can sit up to STABLE_TOL short of its mean
        found.append({"from_luma": round(la, 1), "to_luma": round(lb, 1), "direction": "up" if lb > la else "down",
                      **timing(t, y, a1 + 1, b1, la, lb)})
    return found


def events(s: list[dict], threshold: float) -> list[dict]:
    """Runs of frames whose change > threshold (consecutive changed frames, or gaps < EVENT_GAP s, merge)."""
    t, y = [p["t"] for p in s], [p["luma"] for p in s]
    runs = []   # [first, last] changed frame
    for i, p in enumerate(s):
        if p["change"] <= threshold:
            continue
        if runs and (runs[-1][1] == i - 1 or t[i] - t[runs[-1][1]] < EVENT_GAP):
            runs[-1][1] = i
        else:
            runs.append([i, i])
    out = []
    for a, b in runs:
        before, after = s[a - 1], s[b]
        e = {"start": t[a], "start_resolution_ms": round((t[a] - t[a - 1]) * 1000, 1), "end": t[b],
             "duration_ms": round((t[b] - t[a]) * 1000, 1), "peak_change": max(p["change"] for p in s[a:b + 1]),
             "frames": b - a + 1, "before": {k: before[k] for k in ("hex", "luma")},
             "after": {k: after[k] for k in ("hex", "luma")}}
        if "match" in before:
            e["before"]["match"], e["after"]["match"] = before["match"], after["match"]
        la, lb, seg = before["luma"], after["luma"], y[a - 1:b + 1]
        steps = [v - u for u, v in zip(seg, seg[1:])]
        if abs(lb - la) < EVENT_MIN_LUMA:
            e["luma_timing"] = {"note": f"luma change {lb - la:+.1f} < {EVENT_MIN_LUMA:g}: not a luma transition"}
        elif any(d * (lb - la) < -max(MONO_TOL, MONO_REL * abs(lb - la)) * abs(lb - la) for d in steps):
            e["luma_timing"] = {"note": "luma not monotonic (step back > 5 % of the change: overshoot or several changes)"}
        else:
            e["luma_timing"] = timing(t, y, a, b, la, lb)
        out.append(e)
    return out


def track(args) -> dict:
    matches = parse_matches(args.match)
    s = series(args.mp4, args.rect, args, args.start, args.end, matches, args.scroll_indicator)
    found, evs = transitions(s, args.min_change), events(s, args.event_threshold)
    result = {"frames": s, "transitions": found, "events": evs}
    if args.json:
        print(json.dumps(result))
        return result
    names = [n for n, _, _ in matches]
    print("time      hex      luma   change" + "".join(f"  {n:>8}" for n in names) + ("  scroll (pt)" if args.scroll_indicator else ""))
    for p in s:
        sc = "" if not args.scroll_indicator else ("  no" if p["scroll"] is None else f"  yes {p['scroll'][0]:g}-{p['scroll'][1]:g}")
        print(f"{p['t']:8.3f}  {p['hex']}  {p['luma']:6.1f}  {p['change']:6.2f}"
              + "".join(f"  {p['match'][n]:8.1%}" for n in names) + sc)

    def span(x):
        if x.get("duration_ms") is None:
            return x["note"]
        return (f"10-90 % {x['t10']:.3f}s -> {x['t90']:.3f}s = {x['duration_ms']:.0f} ms "
                f"(±{x['resolution_ms'][0]:.0f} / ±{x['resolution_ms'][1]:.0f} ms)")
    print(f"\n{len(found)} transition(s) between stable levels (± = gap to the previous frame at each crossing)")
    for x in found:
        print(f"  {x['direction']:4} luma {x['from_luma']} -> {x['to_luma']}: {span(x)}")
    print(f"\n{len(evs)} event(s) (frames whose change > {args.event_threshold:g}, gaps < {EVENT_GAP:g} s merged)")
    for e in evs:
        b, a = e["before"], e["after"]
        print(f"  {e['start']:.3f}s -> {e['end']:.3f}s ({e['duration_ms']:.0f} ms, {e['frames']} frames, start "
              f"±{e['start_resolution_ms']:.0f} ms) peak {e['peak_change']:.2f}: {b['hex']} {b['luma']:.1f} -> "
              f"{a['hex']} {a['luma']:.1f}" + "".join(f", {n} {b['match'][n]:.1%} -> {a['match'][n]:.1%}" for n in names))
        print(f"      {span(e['luma_timing'])}")
    return result


# --- grid / strip ----------------------------------------------------------------------------------------

def label_font():
    return ImageFont.load_default(size=14)


def fit(im: Image.Image, w: int, h: int) -> Image.Image:
    k = min(w / im.width, h / im.height)
    return im.resize((max(1, round(im.width * k)), max(1, round(im.height * k))), Image.LANCZOS)


def grid(args) -> Path:
    cols, rows = args.cols.split(","), args.rows.split(",")
    heads = {c: c for c in cols} | dict(x.split("=", 1) for x in args.col_label or [])
    cells, missing = {}, []
    for r in rows:
        for c in cols:
            f = args.pattern.replace("{col}", c).replace("{row}", r)
            if not Path(f).is_file():
                missing.append(f)
                print(f"grid: missing {f}", file=sys.stderr)
                continue
            cells[r, c] = (rasterise(f, args.size or GRID_CAP) if f.lower().endswith(".svg") else Image.open(f)).convert("RGBA")
    if not cells:
        sys.exit(f"grid: no image matches {args.pattern}")
    first = next(iter(cells.values()))
    cap = args.size or GRID_CAP
    cw, ch = fit(first, cap, cap).size if args.size or max(first.size) > cap else first.size
    font, pad, head_h = label_font(), 12, 28
    label_w = int(max(font.getlength(r) for r in rows)) + 2 * pad
    slots = [max(cw, int(font.getlength(heads[c]))) for c in cols]   # a header never overlaps the next column
    xs = [label_w + sum(slots[:j]) + j * pad for j in range(len(cols))]
    bg = "#" + args.bg.lstrip("#")
    sheet = Image.new("RGB", (xs[-1] + slots[-1] + pad, head_h + len(rows) * (ch + pad) + pad), bg)
    draw = ImageDraw.Draw(sheet)
    ink = "#000000" if sum(sheet.getpixel((0, 0))) > 382 else "#FFFFFF"
    for j, c in enumerate(cols):
        draw.text((xs[j], 8), heads[c], fill=ink, font=font)
    for i, r in enumerate(rows):
        y = head_h + i * (ch + pad)
        draw.text((pad, y + ch // 2 - 8), r, fill=ink, font=font)
        for j, c in enumerate(cols):
            x = xs[j]
            if (r, c) not in cells:
                draw.rectangle((x, y, x + cw - 1, y + ch - 1), fill="#BBBBBB")
                draw.text((x + cw // 2, y + ch // 2), "missing", fill="#555555", font=font, anchor="mm")
                continue
            im = fit(cells[r, c], cw, ch)
            sheet.paste(im, (x + (cw - im.width) // 2, y + (ch - im.height) // 2), im)
    out = out_path(args.out, "grid.png")
    sheet.save(out)
    print(f"{out}  ({sheet.width}x{sheet.height}px, {len(cols)} cols x {len(rows)} rows, cell {cw}x{ch}px, "
          f"{len(missing)} missing)")
    return out


def strip(args) -> Path:
    if (args.every is None) == (args.at is None):
        sys.exit("strip: give --every S or --at t1,t2,...")
    todo = sorted(float(v) for v in args.at.split(",")) if args.at else []
    picks, next_t, box = [], args.start, None
    for t, f in decode(args.mp4, args.start, args.end):
        if args.every:
            if t < next_t:
                continue
            next_t += args.every * (1 + int((t - next_t) // args.every))
        else:
            if not todo:
                break
            if t < todo[0]:
                continue
            while todo and todo[0] <= t:
                todo.pop(0)
        im = f.to_image()
        if args.rect:
            box = box or rect_px(args.rect, scale_for(im.width, args), im.width, im.height)
            im = im.crop(box)
        picks.append((t, im.resize((max(1, round(im.width * args.height / im.height)), args.height), Image.LANCZOS)))
    if todo:
        print(f"strip: no frame at or after {', '.join(f'{v:g}' for v in todo)} s", file=sys.stderr)
    if not picks:
        sys.exit("strip: no frames in that time window")
    font, pad = label_font(), 8
    slots = [max(im.width, int(font.getlength(f"{t:.3f} s")) + 4) for t, im in picks]   # a label never overlaps
    sheet = Image.new("RGB", (sum(slots) + pad * (len(picks) + 1), args.height + 2 * pad + 22), "#FFFFFF")
    draw, x = ImageDraw.Draw(sheet), pad
    for (t, im), w in zip(picks, slots):
        sheet.paste(im, (x + (w - im.width) // 2, pad))
        draw.text((x + w // 2, pad + args.height + 4), f"{t:.3f} s", fill="#000000", font=font, anchor="mt")
        x += w + pad
    out = out_path(args.out, f"{Path(args.mp4).stem}-strip.png")
    sheet.save(out)
    print(f"{out}  ({sheet.width}x{sheet.height}px, {len(picks)} frames)")
    return out


# --- selftest --------------------------------------------------------------------------------------------

def write_video(path: str, times: list[float], frame) -> str:
    """Lossless VFR H.264 test clip: frame(t) -> RGB array at each time."""
    with av.open(path, "w") as c:
        st = c.add_stream("libx264", rate=1000, options={"crf": "0"})
        h, w = frame(0.0).shape[:2]
        st.width, st.height, st.pix_fmt, st.codec_context.time_base = w, h, "yuv444p", fractions.Fraction(1, 1000)
        for t in times:
            f = av.VideoFrame.from_ndarray(frame(t), format="rgb24")
            f.pts, f.time_base = round(t * 1000), st.codec_context.time_base
            c.mux(st.encode(f))
        c.mux(st.encode())
    return path


def selftest() -> int:
    global OUT
    checks = []
    with tempfile.TemporaryDirectory() as d:
        OUT = Path(d)
        ns = argparse.Namespace(px=False, scale=None, zoom=8, out=None, json=True, min_change=10.0, match=None,
                                start=0.0, end=float("inf"), every=None, svg_size=1024)
        img = np.zeros((300, 402, 3), np.uint8); img[10:20, 10:20] = 255
        Image.fromarray(img).save(f"{d}/s.png")
        c = Image.open(crop(argparse.Namespace(**{**vars(ns), "png": f"{d}/s.png", "rect": "5,5,25,25"})))
        checks.append(("crop 20pt x8 = 160px", c.size == (160, 160) and c.getpixel((80, 80)) == (255, 255, 255)))
        c = crop(argparse.Namespace(**{**vars(ns), "png": f"{d}/s.png", "rect": "5,5,25,25", "zoom": 2.5}))
        checks.append(("crop x2.5 = 50px, LANCZOS, name x2_5", Image.open(c).size == (50, 50) and "-x2_5" in c.name))
        if shutil.which("rsvg-convert"):
            Path(f"{d}/s.svg").write_text('<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">'
                                          '<rect width="100" height="100" fill="#fff"/><rect x="50" y="50" width="50" '
                                          'height="50" fill="#000"/></svg>')
            c = Image.open(crop(argparse.Namespace(**{**vars(ns), "png": f"{d}/s.svg", "rect": "520,520,540,540",
                                                      "zoom": 2.5})))
            checks.append(("crop SVG at 1024, coordinates in raster px", c.size == (50, 50) and c.getpixel((25, 25)) == (0, 0, 0)))
        m = Image.open(montage(argparse.Namespace(inputs=[f"{d}/s.png"], sizes="64,29", labels=None, apple=False,
                                                  mask=True, bg="FFFFFF", out=None, cols=None)))
        checks.append(("montage size", m.size == (150 + 64 + 16 + 256 + 29 + 16 + 116 + 48, 28 + 256 + 32)))
        m = Image.open(montage(argparse.Namespace(inputs=[f"{d}/s.png"] * 8, sizes="1024,58,29", labels=None,
                                                  apple=False, mask=False, bg="FFFFFF", out=None, cols=None)))
        checks.append((f"montage 8 x 1024: grid, {m.height / m.width:.2f}x as tall as wide (<= 1.5)", m.height <= 1.5 * m.width))
        cached = (ICON_CACHE / "icons.json").exists()   # the cache only, never the network; else stand-ins
        icons = fetch_icons() if cached else [(Image.new("RGBA", (512, 512), c), n) for c, n in
                                              [("#FF3B30", "A"), ("#34C759", "B"), ("#007AFF", "C")]]
        m = Image.open(montage(argparse.Namespace(inputs=[f"{d}/s.png"] * 3, sizes="1024,58,29", labels=None,
                                                  apple=True, apple_icons=icons, mask=True, bg="FFFFFF", out=None,
                                                  cols=None)))
        rows = (m.height - 28) / (256 + 32)            # row height: the 256 px stand-in for 1024 + 2 x pad
        checks.append((f"montage 3 + --apple ({len(icons)} {'cached' if cached else 'stand-in'} icons): {rows:g} rows",
                       rows == 3))
        # VFR synthetic video: 0.5 s hold (2 frames), linear 250 ms fade 20 -> 220 at 60 fps, 0.5 s hold.
        times = [0.0, 0.3] + [0.5 + k / 60 for k in range(16)] + [0.8, 1.3]
        mp4 = write_video(f"{d}/fade.mp4", times, lambda t: np.full((200, 402, 3), round(
            20 + 200 * min(1.0, max(0.0, (t - 0.5) / 0.25))), np.uint8))
        s = series(mp4, "100,50,300,150", ns, 0, float("inf"))
        checks.append(("decoded real timestamps", [round(p["t"], 3) for p in s] == [round(t, 3) for t in times]))
        tr = transitions(s, 10)
        # 10 % / 90 % of a linear 250 ms fade = 25 ms and 225 ms in -> 200 ms, within one frame (16.7 ms)
        checks.append(("one up transition", len(tr) == 1 and tr[0]["direction"] == "up"))
        checks.append(("fade 200 ms ± 1 frame", bool(tr) and abs(tr[0]["duration_ms"] - 200) <= 1000 / 60 + 0.5))
        fr = frames(argparse.Namespace(mp4=mp4, start=0.0, end=float("inf"), every=0.1, out=f"{d}/fr"))
        names = sorted(p.name for p in fr.glob("t*.png"))
        checks.append(("frames --every 0.1", names[:3] == ["t0000.000.png", "t0000.300.png", "t0000.500.png"]))
        # The old crash (StopIteration): the next plateau starts below 90 % of its own mean, so 90 % is only
        # reached inside it.
        y = [0.0] * 10 + [3.0, 9] + [12.0] * 8
        tr1 = transitions([{"t": k / 60, "luma": v} for k, v in enumerate(y)], 1)
        checks.append(("min-change 1, 90 % reached inside the next plateau: no crash, timed",
                       len(tr1) == 1 and tr1[0]["duration_ms"] is not None))
        # Never settles: luma oscillates for 1 s at 60 fps -> no plateau pair, one event, no timing, no crash.
        wave = write_video(f"{d}/wave.mp4", [k / 60 for k in range(61)], lambda t: np.full(
            (200, 402, 3), round(120 + 60 * np.sin(2 * np.pi * t / 0.4)), np.uint8))
        sw = series(wave, "0,0,402,200", ns, 0, float("inf"))
        tw, ew = transitions(sw, 1), events(sw, EVENT_THRESHOLD)
        checks.append((f"never-settling region: {len(tw)} transitions, {len(ew)} event, no crash",
                       len(ew) == 1 and ew[0]["luma_timing"].get("duration_ms") is None))
        # Two events: the background fades 20 -> 220 (250 ms), then a #FF2D55 40x40 square slides across it at
        # 1.5-1.8 s (mean luma constant: motion still counts); static frames between.
        def two(t):
            a = np.full((200, 402, 3), round(20 + 200 * min(1.0, max(0.0, (t - 0.5) / 0.25))), np.uint8)
            x = 20 + round(300 * min(1.0, max(0.0, (t - 1.5) / 0.3)))
            a[80:120, x:x + 40] = (255, 45, 85)
            return a
        times2 = [0.0, 0.3] + [0.5 + k / 60 for k in range(16)] + [1.0, 1.25] + [1.5 + k / 60 for k in range(19)] + [2.0, 2.3]
        ns2 = argparse.Namespace(**{**vars(ns), "mp4": write_video(f"{d}/two.mp4", times2, two), "rect": "0,0,402,200",
                                    "match": ["FF2D55"], "scroll_indicator": False, "event_threshold": EVENT_THRESHOLD})
        with contextlib.redirect_stdout(io.StringIO()):
            r2 = track(ns2)
        e2 = r2["events"]
        share = e2[1]["after"]["match"]["#FF2D55"] if len(e2) == 2 else -1
        checks.append((f"two events in one clip: {len(e2)} ({', '.join(f'{e['start']:.3f}-{e['end']:.3f}s' for e in e2)})",
                       len(e2) == 2 and abs(e2[0]["start"] - 0.5167) < 0.002 and e2[1]["start"] >= 1.5))
        checks.append(("event 1 timed 200 ms ± 1 frame, event 2 (constant luma) not timed",
                       len(e2) == 2 and abs((e2[0]["luma_timing"]["duration_ms"] or 0) - 200) <= 1000 / 60 + 0.5
                       and e2[1]["luma_timing"].get("duration_ms") is None))
        checks.append((f"--match share through the codec {share:.4f} (expected {1600 / 80400:.4f} ± 0.01)",
                       abs(share - 1600 / 80400) <= 0.01))
        px = np.zeros((100, 100, 3), np.uint8); px[:] = (255, 85, 85)      # 40 away from FF2D55: outside 24
        px[:30] = (255, 45, 85); px[30:42] = (255 - 10, 55, 95)            # 30 % exact + 12 % at 17.3 away
        checks.append(("--match share 42 % (exact 30 % + within-tolerance 12 %)",
                       abs(match_share(px, np.array([255, 45, 85]), MATCH_TOL) - 0.42) < 0.01))
        # Scroll indicator at 3x as calibrated (3 pt wide, 3 pt from the edge), light and dark; absent cases:
        # plain, a sheet edge flush with the screen edge, a diagonal line, a too-wide bar.
        def screen(bg, ink=None, kind="bar"):
            a = np.full((2622, 1206, 3), bg, np.uint8)
            if kind == "bar":
                a[435:1335, 1188:1197] = ink
            elif kind == "edge":
                a[:, 1203:] = ink
            elif kind == "diagonal":
                for k in range(900):
                    a[300 + k, 1170 + k // 30:1176 + k // 30] = ink
            elif kind == "wide":
                a[435:1335, 1182:1197] = ink
            return a
        found = [scroll_indicator(screen(249, 162), 3), scroll_indicator(screen(26, 140), 3)]
        absent = [scroll_indicator(screen(249, kind=None), 3)] + [scroll_indicator(screen(249, 162, k), 3) for k in ("edge", "diagonal", "wide")]
        checks.append((f"scroll indicator present light/dark: {found}", found == [(145.0, 445.0)] * 2))
        checks.append(("scroll indicator absent: plain, sheet edge, diagonal, too wide", absent == [None] * 4))
        # grid: 2 x 2 with one missing cell (grey, warned, not fatal); strip: frame count.
        for c in ("a", "b"):
            for r in ("x", "y"):
                if (c, r) != ("b", "y"):
                    Image.new("RGB", (80, 60), "#FF0000").save(f"{d}/{c}-{r}.png")
        with contextlib.redirect_stderr(io.StringIO()) as err:
            g = Image.open(grid(argparse.Namespace(pattern=f"{d}/{{col}}-{{row}}.png", cols="a,b", rows="x,y",
                                                   col_label=["a=variant A"], size=None, bg="FFFFFF", out=None)))
        label_w = int(label_font().getlength("x")) + 24
        cx, cy = label_w + 80 + 12 + 40, 28 + 60 + 12 + 30
        checks.append(("grid 2x2, one missing cell: grey + warning",
                       g.getpixel((cx, cy - 15)) == (187, 187, 187) and "missing" in err.getvalue()
                       and g.getpixel((label_w + 40, 28 + 30)) == (255, 0, 0)))
        for every, at, want in ((0.25, None, 5), (None, "0.3,0.51,9", 2)):
            with contextlib.redirect_stderr(io.StringIO()):
                st = Image.open(strip(argparse.Namespace(mp4=mp4, start=0.0, end=float("inf"), every=every, at=at,
                                                         rect=None, height=100, px=False, scale=None, out=None)))
            n = (st.width - 8) // (201 + 8)
            checks.append((f"strip {'--every 0.25' if every else '--at 0.3,0.51,9'}: {n} frames (expected {want})", n == want))
    for name, ok in checks:
        print(f"{'PASS' if ok else 'FAIL'}  {name}")
    if tr:
        print(f"measured fade: {tr[0]['duration_ms']} ms (expected 200, resolution {tr[0]['resolution_ms']} ms)")
    return 0 if all(ok for _, ok in checks) else 1


def main() -> int:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--scale", type=float, default=None, help="pixels per point")
    common.add_argument("--px", action="store_true", help="coordinates are pixels")
    window = argparse.ArgumentParser(add_help=False)
    window.add_argument("--from", dest="start", type=float, default=0.0, help="start time (s)")
    window.add_argument("--to", dest="end", type=float, default=float("inf"), help="end time (s)")
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--selftest", action="store_true")
    sub = parser.add_subparsers(dest="cmd")
    p = sub.add_parser("crop", parents=[common]); p.add_argument("png"); p.add_argument("rect")
    p.add_argument("--zoom", type=float, default=1, help="integer: nearest neighbour; fractional: LANCZOS")
    p.add_argument("--svg-size", type=int, default=1024, help="SVG raster size (coordinates are its pixels)")
    p.add_argument("--out")
    p = sub.add_parser("montage"); p.add_argument("inputs", nargs="+")
    p.add_argument("--sizes", default="1024,58,29"); p.add_argument("--labels")
    p.add_argument("--apple", action="store_true"); p.add_argument("--mask", action="store_true")
    p.add_argument("--cols", type=int, help="grid columns (default: keep the sheet <= 1.5x as tall as wide)")
    p.add_argument("--bg", default="FFFFFF"); p.add_argument("--out")
    p = sub.add_parser("frames", parents=[window]); p.add_argument("mp4")
    p.add_argument("--every", type=float); p.add_argument("--out")
    p = sub.add_parser("track", parents=[common, window]); p.add_argument("mp4"); p.add_argument("rect")
    p.add_argument("--min-change", type=float, default=10.0); p.add_argument("--json", action="store_true")
    p.add_argument("--event-threshold", type=float, default=EVENT_THRESHOLD,
                   help="per-frame change (mean abs pixel difference, 0-255) that counts as motion")
    p.add_argument("--match", action="append", metavar="HEX[:TOL]", help="share of pixels near this colour (repeatable)")
    p.add_argument("--scroll-indicator", action="store_true", help="detect an iOS scroll indicator at the right edge")
    p = sub.add_parser("grid"); p.add_argument("pattern", help="path with {col} and {row}, PNG or SVG")
    p.add_argument("--cols", required=True); p.add_argument("--rows", required=True)
    p.add_argument("--col-label", action="append", metavar="COL=TEXT", help="column header (repeatable)")
    p.add_argument("--size", type=int, help=f"cell long side in px (default: first image, capped at {GRID_CAP})")
    p.add_argument("--bg", default="FFFFFF"); p.add_argument("--out")
    p = sub.add_parser("strip", parents=[common, window]); p.add_argument("mp4"); p.add_argument("rect", nargs="?")
    p.add_argument("--every", type=float); p.add_argument("--at", help="t1,t2,...: first frame at or after each")
    p.add_argument("--height", type=int, default=400, help="frame height in the strip (px)"); p.add_argument("--out")
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    if not args.cmd:
        parser.error("give a subcommand or --selftest")
    for f in getattr(args, "inputs", None) or [getattr(args, "png", None) or getattr(args, "mp4", None)]:
        if f and not Path(f).is_file():
            sys.exit(f"no such file: {f}")
    {"crop": crop, "montage": montage, "frames": frames, "track": track, "grid": grid, "strip": strip}[args.cmd](args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
