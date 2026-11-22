# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow", "imageio-ffmpeg"]
# ///
"""Builds the app demo video and the README images from the MarketingUITests frames.

    LACARTE_AGENT=marketing UI_WORKERS=1 scripts/ios-ui-test.sh marketing \
        -only-testing:LaCarteUITests/MarketingUITests
    uv run marketing/build-demo.py [frames_dir] [out_dir]

frames_dir defaults to qa/screenshots/marketing, out_dir to $LA_CARTE_MARKETING_OUT (default: build/marketing)
(big media: never committed). ffmpeg comes from the imageio-ffmpeg wheel (no Homebrew).
Writes: out/app-demo.mp4, out/frames/NN.png (composed 1920x1080 shots), out/readme/*.png.
Shot list and captions: docs/marketing/app-demo.md (keep both in sync).
"""

import subprocess
import os
import sys
from pathlib import Path

import imageio_ffmpeg
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
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
    (3.0, "widget", ["widget-due-light", "widget-due-dark"], "Your deck on the Home Screen"),
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


def readme() -> None:
    """Three phones side by side, light and dark, plus the cleaned single screens."""
    out = OUT / "readme"
    out.mkdir(parents=True, exist_ok=True)
    names = ["readme-1-front", "readme-2-reveal", "readme-3-person", "readme-4-deck"]
    for scheme in ("light", "dark"):
        ps = [phone(f"{n}-{scheme}", 1000, scheme) for n in names[1:]]
        gap = 70
        sheet = Image.new("RGB", (sum(p.width for p in ps) + gap * 4, 1000 + 2 * gap), BG[scheme])
        x = gap
        for p in ps:
            sheet.paste(p, (x, gap), p)
            x += p.width + gap
        sheet.save(out / f"readme-hero-{scheme}.png", optimize=True)
        for n in names:
            screen(f"{n}-{scheme}").save(out / f"{n}-{scheme}.png", optimize=True)


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


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    video()
    readme()
