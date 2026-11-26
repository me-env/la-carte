# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow", "imageio-ffmpeg"]
# ///
"""Builds the app demo video, the README images and the README motion (--clips, --streak; docs/marketing/app-demo.md).

    LACARTE_AGENT=marketing UI_WORKERS=1 scripts/ios-ui-test.sh marketing \
        -only-testing:LaCarteUITests/MarketingUITests
    uv run marketing/build-demo.py [--readme] [frames_dir] [out_dir]

frames_dir defaults to qa/screenshots/marketing, out_dir to $LA_CARTE_MARKETING_OUT (default: build/marketing)
(big media: never committed). ffmpeg comes from the imageio-ffmpeg wheel (no Homebrew).
Writes: out/app-demo.mp4, out/frames/NN.png (composed 1920x1080 shots), and the README images in
marketing/readme/ (committed). --readme: only the README images.
Shot list and captions: docs/marketing/app-demo.md (keep both in sync).
"""

import subprocess
import os
import sys
from pathlib import Path

import imageio_ffmpeg
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
FLAGS = {a for a in sys.argv[1:] if a.startswith("--")}
README_ONLY = "--readme" in FLAGS
sys.argv = [a for a in sys.argv if not a.startswith("--")]
FRAMES = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "qa/screenshots/marketing"
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(os.environ.get("LA_CARTE_MARKETING_OUT", "build/marketing"))

W, H = 1920, 1080
BG = {"light": (249, 250, 245), "dark": (26, 26, 26)}  # brand palette `background`
INK = {"light": (28, 28, 28), "dark": (242, 242, 240)}
SECONDARY = {"light": (157, 157, 155), "dark": (138, 138, 136)}
HAIRLINE = {"light": (226, 227, 222), "dark": (52, 52, 52)}
FONT = "/System/Library/Fonts/SFNS.ttf"
STATUS_BAR = 165  # px @3x: the time / battery band, painted over (no simctl status-bar override)
FADE = 0.4  # s, crossfade between shots
FPS = 30

# (duration s, kind, sources, caption). Identical consecutive captions read as one shot whose phone changes.
SHOTS = [
    (3.0, "title", [], ""),
    (3.0, "phone", ["v01-front-light"], "One deck. One card at a time"),
    (3.0, "phone", ["v02-reveal-light"], "Tap to see the answer"),
    (2.2, "phone", ["v03-ring-forgot-light"], "Forgot or got it: tap, or drag"),
    (2.2, "phone", ["v03-ring-easy-light"], "Forgot or got it: tap, or drag"),
    (3.0, "phone", ["v04-edit-light"], "Double-tap to fix a card in place"),
    (2.0, "phone", ["v05-edited-light"], "Double-tap to fix a card in place"),
    (2.6, "phone", ["v06-person-front-light"], "Remember people: a face"),
    (2.6, "phone", ["v07-person-back-light"], "a name, and who they are"),
    (2.6, "phone", ["v08-menu-light"], "Double-tap the card for more"),
    (2.6, "phone", ["v09-copied-light"], "Ask an AI about it"),
    (2.4, "phone", ["v10-report-menu-light"], "Something wrong? Report it"),
    (2.4, "phone", ["v11-reported-light"], "Your agent fixes it over MCP"),
    (3.0, "widget", ["widget-small-nine-light", "widget-small-nine-dark"], "Your deck on the Home Screen"),
    (3.0, "phones", ["theme-light-light", "theme-dark-light", "theme-forest-light"], "Light, dark or forest"),
    (3.2, "end", [], ""),
]


def font(size: int, weight: str = "Medium") -> ImageFont.FreeTypeFont:
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_name(weight)
    return f


def screen(name: str) -> Image.Image:
    """A simulator screenshot with its status bar painted in the color just below it."""
    im = Image.open(FRAMES / f"{name}.png").convert("RGB")
    fill = im.getpixel((8, STATUS_BAR + 4))
    ImageDraw.Draw(im).rectangle([0, 0, im.width, STATUS_BAR], fill=fill)
    return im


def phone(name: str, height: int, scheme: str = "light") -> Image.Image:
    """The screen scaled to `height`, rounded like the device, with a hairline edge (no shadow, no frame)."""
    im = screen(name)
    w = round(im.width * height / im.height)
    im = im.resize((w, height), Image.LANCZOS)
    radius = round(height * 0.068)
    mask = Image.new("L", (w * 4, height * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, w * 4 - 1, height * 4 - 1], radius * 4, fill=255)
    mask = mask.resize((w, height), Image.LANCZOS)
    out = Image.new("RGBA", (w + 4, height + 4), (0, 0, 0, 0))
    edge = Image.new("L", ((w + 4) * 4, (height + 4) * 4), 0)
    ImageDraw.Draw(edge).rounded_rectangle([0, 0, (w + 4) * 4 - 1, (height + 4) * 4 - 1], (radius + 2) * 4, fill=255)
    out.paste(HAIRLINE[scheme], (0, 0), edge.resize((w + 4, height + 4), Image.LANCZOS))
    out.paste(im, (2, 2), mask)
    return out


def centered(draw: ImageDraw.ImageDraw, y: int, text: str, f, fill) -> None:
    w = draw.textlength(text, font=f)
    draw.text(((W - w) / 2, y), text, font=f, fill=fill)


def compose(kind: str, sources: list[str], caption: str) -> Image.Image:
    canvas = Image.new("RGB", (W, H), BG["light"])
    draw = ImageDraw.Draw(canvas)
    if kind == "title":
        centered(draw, 400, "la carte", font(120), INK["light"])
        centered(draw, 575, "One flashcard deck. Spaced repetition.", font(44, "Regular"), SECONDARY["light"])
    elif kind == "end":
        centered(draw, 360, "Open source. No account.", font(76), INK["light"])
        centered(draw, 480, "Any agent can add cards over MCP", font(44, "Regular"), SECONDARY["light"])
        centered(draw, 640, "github.com/me-env/la-carte", font(40), INK["light"])
    elif kind == "phone":
        p = phone(sources[0], 880)
        canvas.paste(p, ((W - p.width) // 2, 36), p)
    elif kind == "phones":
        ps = [phone(s, 820) for s in sources]
        gap = 80
        x = (W - sum(p.width for p in ps) - gap * (len(ps) - 1)) // 2
        for p in ps:
            canvas.paste(p, (x, 60), p)
            x += p.width + gap
    elif kind == "widget":
        tiles = [Image.open(FRAMES / f"{s}.png").convert("RGB").resize((420, 418), Image.LANCZOS) for s in sources]
        gap = 120
        x = (W - 420 * len(tiles) - gap * (len(tiles) - 1)) // 2
        for t in tiles:
            mask = Image.new("L", (420 * 4, 418 * 4), 0)
            ImageDraw.Draw(mask).rounded_rectangle([0, 0, 420 * 4 - 1, 418 * 4 - 1], 88 * 4, fill=255)
            edge = Image.new("L", (424 * 4, 422 * 4), 0)
            ImageDraw.Draw(edge).rounded_rectangle([0, 0, 424 * 4 - 1, 422 * 4 - 1], 90 * 4, fill=255)
            canvas.paste(HAIRLINE["light"], (x - 2, 258), edge.resize((424, 422), Image.LANCZOS))
            canvas.paste(t, (x, 260), mask.resize((420, 418), Image.LANCZOS))
            x += 420 + gap
    if caption:
        centered(draw, 960, caption, font(46), INK["light"])
    return canvas


def sheet(names: list[str], scheme: str, height: int = 1000, gap: int = 70) -> Image.Image:
    """Phones side by side on the brand background."""
    ps = [phone(n, height, scheme) for n in names]
    out = Image.new("RGB", (sum(p.width for p in ps) + gap * (len(ps) + 1), height + 2 * gap), BG[scheme])
    x = gap
    for p in ps:
        out.paste(p, (x, gap), p)
        x += p.width + gap
    return out


def widgets(names: list[str], size: int = 420, gap: int = 70) -> Image.Image:
    """Widget tiles (light, dark) side by side on the light background, rounded with a hairline edge."""
    out = Image.new("RGB", (size * len(names) + gap * (len(names) + 1), size + 2 * gap), BG["light"])
    r = round(size * 0.21)
    for i, n in enumerate(names):
        t = Image.open(FRAMES / f"{n}.png").convert("RGB").resize((size, size), Image.LANCZOS)
        mask = Image.new("L", (size * 4, size * 4), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, size * 4 - 1, size * 4 - 1], r * 4, fill=255)
        edge = Image.new("L", ((size + 4) * 4, (size + 4) * 4), 0)
        ImageDraw.Draw(edge).rounded_rectangle([0, 0, (size + 4) * 4 - 1, (size + 4) * 4 - 1], (r + 2) * 4, fill=255)
        x = gap + i * (size + gap)
        out.paste(HAIRLINE["light"], (x - 2, gap - 2), edge.resize((size + 4, size + 4), Image.LANCZOS))
        out.paste(t, (x, gap), mask.resize((size, size), Image.LANCZOS))
    return out


def readme() -> None:
    """The README images (committed, small PNGs): marketing/readme/."""
    out = ROOT / "marketing/readme"
    out.mkdir(parents=True, exist_ok=True)
    for scheme in ("light", "dark"):
        names = [f"readme-1-front-{scheme}", f"readme-2-reveal-{scheme}", f"readme-3-person-{scheme}"]
        sheet(names, scheme).save(out / f"study-{scheme}.png", optimize=True)
    sheet(["v03-ring-easy-light", "v08-menu-light", "theme-forest-light"], "light").save(
        out / "more-light.png", optimize=True)
    widgets(["widget-small-nine-light", "widget-small-nine-dark"]).save(out / "widget.png", optimize=True)


def video() -> None:
    frames = OUT / "frames"
    frames.mkdir(parents=True, exist_ok=True)
    args = [imageio_ffmpeg.get_ffmpeg_exe(), "-y", "-loglevel", "error"]
    for i, (dur, kind, sources, caption) in enumerate(SHOTS):
        path = frames / f"{i:02d}.png"
        compose(kind, sources, caption).save(path)
        args += ["-loop", "1", "-framerate", str(FPS), "-t", f"{dur + FADE:.2f}", "-i", str(path)]
    # Chain xfades: shot i+1 starts fading in FADE s before shot i ends.
    chain, last, offset = [], "0:v", 0.0
    for i in range(1, len(SHOTS)):
        offset += SHOTS[i - 1][0]
        tag = f"x{i}"
        chain.append(f"[{last}][{i}:v]xfade=transition=fade:duration={FADE}:offset={offset:.2f}[{tag}]")
        last = tag
    chain.append(f"[{last}]format=yuv420p[out]")
    args += ["-filter_complex", ";".join(chain), "-map", "[out]", "-r", str(FPS),
             "-c:v", "libx264", "-preset", "slow", "-crf", "20", "-movflags", "+faststart", "-an",
             str(OUT / "app-demo.mp4")]
    subprocess.run(args, check=True)
    total = sum(s[0] for s in SHOTS) + FADE
    print(f"{OUT / 'app-demo.mp4'}: {len(SHOTS)} shots, about {total:.1f} s")


# MARK: - README motion: the widget streak growing (real DeckWidgetTile renders) and the app clips (UI-test recordings)

STREAK_RENDERS = Path(os.environ.get("LA_CARTE_STREAK_RENDERS", ROOT / "build/renders/streak"))
RECORDINGS = ROOT / "qa/screenshots/marketing/recordings"
MOTION_FPS = 30
# (to day, travel s, hold s, linear): the streak runs from day 1; linear segments step one day at a time.
STREAK = [(1, 0.0, 1.2, True), (7, 2.4, 1.1, True), (14, 1.5, 0.9, False), (30, 1.5, 0.9, False),
          (91, 1.8, 1.0, False), (365, 2.4, 1.1, False), (730, 2.4, 2.0, False)]
DAY_FADE = 0.25  # s, crossfade between two days (brand: standard motion)
WIDGET_SCALE = 2  # the renders' scale; the README shows them at 1x points
# The 4 x 7 grids in a streak frame (px; tiles at x 80 and 468, y 80): measured on the 2x renders.
GRID_BOXES = [(80 + 24, 80 + 100, 80 + 310, 80 + 256), (468 + 420, 80 + 100, 468 + 704, 80 + 256)]


def time_label(day: int) -> str:
    """Day 1…13, Week 2…4, Month 1…11, Year 1, 2."""
    if day < 14:
        return f"Day {day}"
    if day < 30:
        return f"Week {day // 7}"
    if day < 365:
        return f"Month {min(11, max(1, round(day / 30.44)))}"
    return f"Year {day // 365}"


def ease(u: float) -> float:
    return 4 * u ** 3 if u < 0.5 else 1 - (-2 * u + 2) ** 3 / 2


def streak_timeline() -> list[tuple[int, float, float]]:
    """Per frame: (day, alpha towards day + 1, days per second)."""
    frames: list[tuple[int, float, float]] = []
    day = 1.0
    for to, travel, hold, linear in STREAK:
        n = round(travel * MOTION_FPS)
        rate = (to - day) / travel if travel else 0
        for i in range(n):
            u = (i + 1) / n
            frames.append((day + (to - day) * (u if linear else ease(u)), rate))
        day = float(to)
        frames += [(day, 0.0)] * round(hold * MOTION_FPS)
    out = []
    for d, rate in frames:
        base, frac = int(d), d - int(d)
        k = min(1.0, DAY_FADE * rate) if rate else 1.0  # slow: hold each day, fade over DAY_FADE; fast: blend
        alpha = min(1.0, max(0.0, (frac - (1 - k)) / k)) if k else 0.0
        out.append((base, ease(alpha) if k < 1 else alpha, rate))
    return out


def streak_frame(day: int, scheme: str, cache: dict) -> Image.Image:
    """Small and medium tiles side by side, hairline-edged on the theme's background, the time label below."""
    if (day, scheme) in cache:
        return cache[(day, scheme)]
    pad, gap, label_gap = 80, 48, 56
    tiles = [Image.open(STREAK_RENDERS / f"streak-{f}-{scheme}-{day:04d}.png").convert("RGBA") for f in ("small", "medium")]
    h = tiles[0].height
    w = sum(t.width for t in tiles) + gap + 2 * pad
    canvas = Image.new("RGB", (w, pad + h + label_gap + 52 + pad - 16), BG[scheme])
    x = pad
    r = 22 * WIDGET_SCALE
    for t in tiles:
        edge = Image.new("L", ((t.width + 4) * 4, (h + 4) * 4), 0)
        ImageDraw.Draw(edge).rounded_rectangle([0, 0, (t.width + 4) * 4 - 1, (h + 4) * 4 - 1], (r + 2) * 4, fill=255)
        canvas.paste(HAIRLINE[scheme], (x - 2, pad - 2), edge.resize((t.width + 4, h + 4), Image.LANCZOS))
        canvas.paste(t, (x, pad), t)
        x += t.width + gap
    draw = ImageDraw.Draw(canvas)
    text = time_label(day)
    f = font(44)
    draw.text(((w - draw.textlength(text, font=f)) / 2, pad + h + label_gap), text, font=f, fill=INK[scheme])
    cache[(day, scheme)] = canvas
    return canvas


def seam(last: Image.Image, first: Image.Image, blank: Image.Image) -> list[Image.Image]:
    """Loop seam: `last` fades to `blank`, then `first` fades in (SEAM s each), so two screens never overlap."""
    n = round(SEAM * MOTION_FPS)
    return ([Image.blend(last, blank, ease((i + 1) / n)) for i in range(n)]
            + [Image.blend(blank, first, ease((i + 1) / n)) for i in range(n - 1)])


def save_webp(frames: list[Image.Image], path: Path, fps: int = MOTION_FPS, lossless: bool = False,
              quality: int = 82) -> None:
    """Looping animated WebP (GitHub renders it inline). Identical neighbours merge into one longer frame."""
    merged: list[Image.Image] = []
    durations: list[int] = []
    step = 1000 / fps
    for i, im in enumerate(frames):
        if merged and im is merged[-1]:
            durations[-1] += step
        else:
            merged.append(im)
            durations.append(step)
    ms = [round(sum(durations[:i + 1])) - round(sum(durations[:i])) for i in range(len(durations))]
    merged[0].save(path, save_all=True, append_images=merged[1:], duration=ms, loop=0, lossless=lossless,
                   quality=quality, method=6, minimize_size=True)
    print(f"{path.relative_to(ROOT)}: {len(frames) / fps:.1f} s, {path.stat().st_size / 1e6:.2f} MB")


def streak_webp() -> None:
    """marketing/readme/streak-<light|dark>.webp: the streak grid growing from day 1 to year 2."""
    timeline = streak_timeline()
    for scheme in ("light", "dark"):
        cache: dict = {}
        frames = []
        for day, alpha, _ in timeline:
            a = streak_frame(day, scheme, cache)
            if alpha <= 0.001:
                frames.append(a)
                continue
            # Only the dot grids blend; text (labels, the streak count) switches on the nearer day, never ghosts.
            b = streak_frame(day + 1, scheme, cache)
            frame = (b if alpha >= 0.5 else a).copy()
            for box in GRID_BOXES:
                frame.paste(Image.blend(a.crop(box), b.crop(box), alpha), box[:2])
            frames.append(frame)
        frames += seam(frames[-1], frames[0], Image.new("RGB", frames[0].size, BG[scheme]))
        save_webp(frames, ROOT / f"marketing/readme/streak-{scheme}.webp")


# (clip, recording): the MarketingUITests motion tests, cut between their clip-<name>-start/end screenshots.
CLIPS = [("reveal", "testMotion_1_reveal"), ("tap", "testMotion_2_tap"), ("drag", "testMotion_3_drag"),
         ("finish", "testMotion_4_finish")]
CLIP_W, CLIP_H = 600, 1304  # 2x of the README's 300 pt wide phones (device 1206 x 2622)
LEAD_IN, TAIL, SEAM = 1.6, {"finish": 3.0}, 0.15  # s: still before the first move, after the last (default 1.8)
# SEAM: the loop fades the last frame out to the bare background, then the first frame in, SEAM s each (no double exposure)


def recording_frames(path: Path) -> list[Image.Image]:
    """The recording (variable frame rate) resampled to MOTION_FPS at clip size, via the imageio-ffmpeg binary."""
    cmd = [imageio_ffmpeg.get_ffmpeg_exe(), "-loglevel", "error", "-i", str(path),
           "-vf", f"fps={MOTION_FPS},scale={CLIP_W}:{CLIP_H}:flags=lanczos", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    raw = subprocess.run(cmd, check=True, capture_output=True).stdout
    size = CLIP_W * CLIP_H * 3
    return [Image.frombytes("RGB", (CLIP_W, CLIP_H), raw[i:i + size]) for i in range(0, len(raw) - size + 1, size)]


def matches(a: Image.Image, b: Image.Image) -> bool:
    """Same screen: under 0.1% of pixels differ visibly, ignoring the status bar (its clock differs)."""
    bar = round(STATUS_BAR * CLIP_H / 2622) + 4
    small = lambda im: im.crop((0, bar, CLIP_W, CLIP_H)).convert("L").resize((200, 400)).tobytes()
    x, y = small(a), small(b)
    return sum(abs(p - q) > 48 for p, q in zip(x, y)) < len(x) / 1000


def still_run(frames: list[Image.Image], shot: Image.Image, after: int = 0) -> tuple[int, int]:
    """First run of frames (from `after`) that match `shot`: (first, last) index."""
    first = next(i for i in range(after, len(frames)) if matches(frames[i], shot))
    last = first
    while last + 1 < len(frames) and matches(frames[last + 1], shot):
        last += 1
    return first, last


def framed(im: Image.Image) -> Image.Image:
    """The whole screen, status bar painted over, rounded like the device with a hairline edge, transparent outside."""
    im = im.copy()
    bar = round(STATUS_BAR * CLIP_H / 2622)
    ImageDraw.Draw(im).rectangle([0, 0, CLIP_W, bar], fill=im.getpixel((4, bar + 3)))
    if "mask" not in framed.__dict__:
        r = round(CLIP_W * 0.12)
        big = lambda w, h, rad: Image.new("L", (w * 4, h * 4), 0)
        m = big(CLIP_W, CLIP_H, r)
        ImageDraw.Draw(m).rounded_rectangle([8, 8, CLIP_W * 4 - 9, CLIP_H * 4 - 9], r * 4 - 8, fill=255)
        e = big(CLIP_W, CLIP_H, r)
        ImageDraw.Draw(e).rounded_rectangle([0, 0, CLIP_W * 4 - 1, CLIP_H * 4 - 1], r * 4, fill=255)
        framed.mask, framed.edge = m.resize((CLIP_W, CLIP_H), Image.LANCZOS), e.resize((CLIP_W, CLIP_H), Image.LANCZOS)
    out = Image.new("RGBA", (CLIP_W, CLIP_H), HAIRLINE["light"] + (0,))
    out.putalpha(framed.edge)
    out.paste(im, (0, 0), framed.mask)
    return out


def clips_webp() -> None:
    """marketing/readme/clip-<name>.webp from the --record run `marketing-motion` (light, whole screen)."""
    shots = ROOT / "qa/screenshots/marketing-motion"
    for name, test in CLIPS:
        frames = recording_frames(shots / "recordings" / f"{test}.mp4")
        load = lambda what: Image.open(shots / f"clip-{name}-{what}.png").convert("RGB").resize((CLIP_W, CLIP_H), Image.LANCZOS)
        s0, s1 = still_run(frames, load("start"))
        e0, e1 = still_run(frames, load("end"), after=s1)
        start = max(s0, s1 - round(LEAD_IN * MOTION_FPS))
        end = min(e1, e0 + round(TAIL.get(name, 1.8) * MOTION_FPS))
        cut = [framed(f) for f in frames[start:end + 1]]
        cut += seam(cut[-1], cut[0], framed(Image.new("RGB", (CLIP_W, CLIP_H), BG["light"])))
        save_webp(cut, ROOT / f"marketing/readme/clip-{name}.webp", quality=80)


if __name__ == "__main__":
    if "--clips" in FLAGS:
        clips_webp()
        sys.exit()
    if "--streak" in FLAGS:
        streak_webp()
        sys.exit()
    if not README_ONLY:
        OUT.mkdir(parents=True, exist_ok=True)
        video()
    readme()
