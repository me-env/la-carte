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
    uv run scripts/image-ops.py track   <mp4> x0,y0,x1,y1 [--from S] [--to S] [--min-change L] [--json]
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
  `--apple`: extra entries with Apple's own app icons (cache shared with design-review.py). SVG needs rsvg-convert.
- frames: PNG per decoded frame named by its real timestamp (t0001.234.png) + frames.tsv (index, time, file).
  `--every S`: the first frame at or after each multiple of S. Recordings are variable frame rate.
- track: per frame the region's mean colour and luma (Rec. 709, 0-255); then each transition between two
  stable levels (held >= 0.1 s, within 3 luma) that differ by >= `--min-change` (default 10): the time luma
  crosses 10 % and 90 % of the change, duration, direction. A crossing is stamped at the first frame past the
  threshold; its resolution is the gap to the previous frame (the change happened inside that gap).
"""

import argparse
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
    sizes = [int(s) for s in args.sizes.split(",")]
    labels = args.labels.split(",") if args.labels else [Path(p).stem for p in args.inputs]
    if len(labels) != len(args.inputs):
        sys.exit(f"--labels has {len(labels)} names for {len(args.inputs)} inputs")
    rows = [(load_icon(p), l) for p, l in zip(args.inputs, labels)] + (fetch_icons() if args.apple else [])
    bg = "#" + args.bg.lstrip("#")
    font = ImageFont.load_default(size=14)
    pad, label_w = 16, 150
    cols = [s + (pad + 4 * s if s < 100 else 0) for s in sizes]
    row_h = max(max(sizes), 4 * max([s for s in sizes if s < 100], default=0)) + 2 * pad
    row_w = label_w + sum(cols) + pad * (len(cols) + 1)
    n = len(rows)                      # grid: the fewest columns that keep the sheet <= 1.5x as tall as wide
    ncol = args.cols or next(c for c in range(1, n + 1) if -(-n // c) * row_h + 28 <= 1.5 * c * row_w or c == n)
    if ncol < 1:
        sys.exit("--cols must be >= 1")
    sheet = Image.new("RGB", (row_w * ncol, 28 + row_h * -(-n // ncol)), bg)
    draw = ImageDraw.Draw(sheet)
    ink = "#000000" if sum(sheet.getpixel((0, 0))) > 382 else "#FFFFFF"
    for g in range(ncol):
        x = g * row_w + label_w + pad
        for s, w in zip(sizes, cols):
            draw.text((x, 6), f"{s}px" + (" + 4x" if s < 100 else ""), fill=ink, font=font)
            x += w + pad
    for r, (src, label) in enumerate(rows):
        x0, y = (r % ncol) * row_w, 28 + (r // ncol) * row_h
        draw.text((x0 + pad, y + row_h // 2 - 8), label[:18], fill=ink, font=font)
        x = x0 + label_w + pad
        for s, w in zip(sizes, cols):
            icon = src.resize((s, s), Image.LANCZOS)
            if args.mask:
                icon.putalpha(Image.fromarray(np.minimum(np.asarray(icon.getchannel("A")),
                                                         np.asarray(squircle(s)))))
            sheet.paste(icon, (x, y + pad), icon)
            if s < 100:
                big = sheet.crop((x, y + pad, x + s, y + pad + s)).resize((4 * s, 4 * s), Image.NEAREST)
                sheet.paste(big, (x + s + pad, y + pad))
            x += w + pad
    out = out_path(args.out, "montage.png")
    sheet.save(out)
    print(f"{out}  ({sheet.width}x{sheet.height}px, {len(rows)} entries in {ncol} column(s) x {len(sizes)} sizes)")
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


def series(path: str, rect: str, args, t0: float, t1: float) -> list[dict]:
    out, box = [], None
    for t, f in decode(path, t0, t1):
        img = f.to_ndarray(format="rgb24")
        if box is None:
            box = rect_px(rect, scale_for(img.shape[1], args), img.shape[1], img.shape[0])
        m = img[box[1]:box[3], box[0]:box[2]].reshape(-1, 3).mean(axis=0)
        out.append({"t": round(t, 4), "hex": "#{:02X}{:02X}{:02X}".format(*(int(round(c)) for c in m)),
                    "luma": round(float(m @ [0.2126, 0.7152, 0.0722]), 2)})
    if not out:
        sys.exit("no frames in that time window")
    return out


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
    for (_, a1, la), (b0, _, lb) in zip(plateaus, plateaus[1:]):
        if abs(lb - la) < min_change:
            continue
        up = lb > la
        def cross(frac):
            level = la + frac * (lb - la)
            k = next(k for k in range(a1 + 1, b0 + 1) if (y[k] >= level if up else y[k] <= level))
            return t[k], t[k] - t[k - 1]
        (s10, r10), (s90, r90) = cross(0.1), cross(0.9)
        found.append({"from_luma": round(la, 1), "to_luma": round(lb, 1), "direction": "up" if up else "down",
                      "t10": s10, "t90": s90, "duration_ms": round((s90 - s10) * 1000, 1),
                      "resolution_ms": [round(r10 * 1000, 1), round(r90 * 1000, 1)]})
    return found


def track(args) -> dict:
    s = series(args.mp4, args.rect, args, args.start, args.end)
    found = transitions(s, args.min_change)
    result = {"frames": s, "transitions": found}
    if args.json:
        print(json.dumps(result))
        return result
    print("time      hex      luma")
    for p in s:
        print(f"{p['t']:8.3f}  {p['hex']}  {p['luma']:6.1f}")
    print(f"\n{len(found)} transition(s) (10 %-90 % of the change; ± = gap to the previous frame at each crossing)")
    for x in found:
        print(f"  {x['direction']:4} luma {x['from_luma']} -> {x['to_luma']}: {x['t10']:.3f}s -> {x['t90']:.3f}s "
              f"= {x['duration_ms']:.0f} ms (±{x['resolution_ms'][0]:.0f} / ±{x['resolution_ms'][1]:.0f} ms)")
    return result


# --- selftest --------------------------------------------------------------------------------------------

def selftest() -> int:
    global OUT
    checks = []
    with tempfile.TemporaryDirectory() as d:
        OUT = Path(d)
        ns = argparse.Namespace(px=False, scale=None, zoom=8, out=None, json=True, min_change=10.0,
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
        # VFR synthetic video: 0.5 s hold (2 frames), linear 250 ms fade 20 -> 220 at 60 fps, 0.5 s hold.
        mp4, times = f"{d}/fade.mp4", [0.0, 0.3] + [0.5 + k / 60 for k in range(16)] + [0.8, 1.3]
        with av.open(mp4, "w") as c:
            st = c.add_stream("libx264", rate=1000, options={"crf": "0"})
            st.width, st.height, st.pix_fmt, st.codec_context.time_base = 402, 200, "yuv444p", fractions.Fraction(1, 1000)
            for t in times:
                v = 20 + 200 * min(1.0, max(0.0, (t - 0.5) / 0.25))
                f = av.VideoFrame.from_ndarray(np.full((200, 402, 3), round(v), np.uint8), format="rgb24")
                f.pts, f.time_base = round(t * 1000), st.codec_context.time_base
                c.mux(st.encode(f))
            c.mux(st.encode())
        s = series(mp4, "100,50,300,150", ns, 0, float("inf"))
        checks.append(("decoded real timestamps", [round(p["t"], 3) for p in s] == [round(t, 3) for t in times]))
        tr = transitions(s, 10)
        # 10 % / 90 % of a linear 250 ms fade = 25 ms and 225 ms in -> 200 ms, within one frame (16.7 ms)
        checks.append(("one up transition", len(tr) == 1 and tr[0]["direction"] == "up"))
        checks.append(("fade 200 ms ± 1 frame", bool(tr) and abs(tr[0]["duration_ms"] - 200) <= 1000 / 60 + 0.5))
        fr = frames(argparse.Namespace(mp4=mp4, start=0.0, end=float("inf"), every=0.1, out=f"{d}/fr"))
        names = sorted(p.name for p in fr.glob("t*.png"))
        checks.append(("frames --every 0.1", names[:3] == ["t0000.000.png", "t0000.300.png", "t0000.500.png"]))
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
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    if not args.cmd:
        parser.error("give a subcommand or --selftest")
    for f in getattr(args, "inputs", None) or [getattr(args, "png", None) or args.mp4]:
        if not Path(f).is_file():
            sys.exit(f"no such file: {f}")
    {"crop": crop, "montage": montage, "frames": frames, "track": track}[args.cmd](args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
