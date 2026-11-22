# la-carte brand kit

Owner: design-lead. **Marketing uses these files as they are: don't redraw, recolor or re-space the logo.**
Questions the kit doesn't answer go to design-lead.

## Logo
**A portrait card crossed by the forgetting curve, drawn as one thick line.** The curve falls (you forget), jumps
back up at a review, and falls again more slowly. The reset sits on the card's left edge, half in, half out. Inside
the card the line is cut out of it; outside the card it's pink. (Chosen by the user on 2026-11-22: round 11, accent
option 1 on mark 131; history in `brand/explorations/ideation-gen/README.md`.)

| File | Use |
|---|---|
| `brand/logo-light.svg` | Default: `ink` card, `#B8325A` line, on light grounds |
| `brand/logo-dark.svg` | On dark grounds: light card, `#ED6E8C` line |
| `brand/logo-mono.svg` | One colour (`currentColor`, the line is the same colour outside the card): watermarks, embossing, one-colour print |
| `brand/logo-tinted.svg` | White card, grey line: the tinted icon's mark, for system-tinted contexts only |
| `brand/png/logo-{light,dark}-{64,256,1024}.png`, `png/logo-mono-1024.png` | Transparent PNG exports |
| `brand/app-icon/app-icon-{light,dark,tinted}.{svg,png}` | 1024 app icon masters (installed in `AppIcon.appiconset`), plus `-58.png` / `-29.png` to check small sizes |
| `brand/render.py` | Regenerates every file above **and** `LaCarteLogoGeometry.swift`: `uv run docs/design/brand/render.py` (needs `rsvg-convert`) |
| `brand/explorations/` | History of every round. **Not for use** |

In the app, use `LaCarteLogo(progress:)`, `LaCarteLaunchMark()` or `LaCarteLoadingMark()` from `DesignSystem`.
Never a bitmap.

- **Geometry** (100×100 box, the mark fills it, centred on its bounding box): the card is 66.7×100 with radius 10,
  its left edge at x 32.6. The line is 10.5 wide with round caps. The reset is a bar 1.9 lines wide centred on the
  card's left edge. Exact numbers: the generated `LaCarteLogoGeometry.swift`. The source of truth is
  `explorations/ideation-gen/accent131.py` (`parts_131`); `render.py` freezes it and fails if they drift.
- **App icon:** the same mark, 800 px tall on the 1024 tile, shifted half-way from bbox-centred to centroid-centred
  (the card weighs the right side). Ground `#F4F1EA` (paper). Tinted: white card and grey `#8E8E8E` line on black,
  iOS tints it by luminance.
- **The icon is white-background in all appearances, per the user (2026-11-22):** the dark variant is rendered
  identical to the light one (not omitted: without it iOS generates its own darkened icon).
- **Clear space:** at least the card's corner radius × 2 (20% of the mark's height) on every side.
- **Minimum size:** 20 pt / 40 px tall. It's designed to read at 29 pt (the icon's smallest size).
- **Wordmark:** "la carte", always lowercase, SF Pro Text/Display medium, `ink`. It goes right of the mark,
  cap height ≈ 30% of the mark's height. There is no custom wordmark font.
- **Don't:** recolour outside the palette · put pink inside the card · add a second accent, outlines, shadows,
  gradients or glass · rotate, skew or mirror it · change the line's weight · put the light logo on a dark ground
  (use `logo-dark`) · animate it any other way than below.

## Palette (tokens from `Theme.swift`)
| Token | Light | Dark | Forest | Role |
|---|---|---|---|---|
| background | `#F9FAF5` | `#1A1A1A` | `#0E1913` | Every backdrop: video, README images, social cards |
| surface | `#FFFFFF` | `#252525` | `#16241B` | Raised elements only |
| ink | `#1C1C1C` | `#F2F2F0` | `#EEF2EC` | Text, the front card |
| secondaryInk | `#9D9D9B` | `#8A8A88` | `#83938A` | Captions' secondary line, the next card |
| accent | `#B8325A` | `#ED6E8C` | `#ED6E8C` | Pink: the logo's line, then very small amounts (below) |

**Brand colour rule (user, 2026-11-22):** la-carte's standout colour is the pink accent, nothing else. The default
icon and every hero/marketing visual is ink + pink on light; the dark variant is light ink + pink on dark. Forest is
an app theme only: it may have its own themed render (the icon's forest variant, a forest screenshot), but it is
never the hero, the default, or a brand colour next to the pink.

The accent pink is `#ED6E8C`; its darker shade `#B8325A` (on light grounds). **The logo's line is the one larger
pink use** (the user chose this treatment, 2026-11-22): the part of the line outside the card, in the logo, the app
icon and the launch/loading marks. Everywhere else, **very small amounts:** in the app the text cursor/selection,
the widget's streak number and Study's count (`docs/design-system.md`). In marketing: the logo, and at most one
highlighted word per caption or headline (`#B8325A` on light, `#ED6E8C` on dark). Never as a background, a fill,
a button, a full sentence or a device-frame color. Use no other colors. The system destructive red only appears
inside the app's own UI and is never replaced by the pink.

## Type
SF Pro (the system font). Text styles: card face = Large Title medium, titles = Title bold, body = Body,
meta = Footnote. One strong weight per frame. Captions are SF Pro Text medium, sentence case, no period on
single lines.

## Motion
| Motion | Spec | Reduce Motion |
|---|---|---|
| Standard (fades, reveals) | ease-in-out 0.25 s (`Theme.Motion.standard`) | Same fade, or none |
| Logo draw-in | ease-in-out 0.9 s (`logoDrawIn`): the card fades and settles from 94% (0–5%, about 135 ms), then the curve is drawn from its first peak: decay 1 in pink, the reset bar rises from its foot, decay 2 is cut into the card (30–100%) | Static: 0.25 s fade-in of the finished mark |
| Launch mark tilt | with the draw-in, the whole mark (card and line, one plane) arrives turned 40° in 3D about its bottom-left → top-right diagonal (perspective 0.6) and lays itself flat over 1.0 s (`logoTilt`, bezier 0.4, 0, 0.2, 1: gentle start, long ease-out, no overshoot); the curve starts drawing while it's still turning. Launch mark only, the loading mark stays flat | No tilt (the static fade-in above) |
| Loading | the curve draws and erases over the card, ease-in-out 0.8 s each way (`loadingPulse`) | Opacity pulse 100% ↔ 40% |
| Transitions | Logo as the shared element (`matchedGeometryEffect`), e.g. launch mark → home | Crossfade |

Nothing bounces, springs or overshoots. No parallax, no zoom-punches.

## Video & README
- **Backgrounds:** flat `background` of the theme being shown (light first, dark second). No gradients, no
  photos. Forest only for a "themes" moment.
- **Device:** the real UI, centered. Use an iPhone 17 Pro frame in Space Black, or no frame with the screen
  rounded at 12% of its width and a soft shadow (light: black 6%, blur 8%). Same choice for the whole video.
- **Open/close:** the logo draw-in (0.9 s) on `background`, centered, about 18% of the frame height. The
  wordmark fades in after it (0.25 s). Close on the static logo + "la carte" + one line.
- **Captions:** at most one line of 6 words, SF Pro Text medium, `ink` on `background` in the frame's lower
  third (not over the device). Fade 0.25 s, hold ≥ 1.5 s. One idea per shot.
- **Cuts:** straight cuts or 0.25 s crossfades only.
- **README hero:** `png/logo-light-256.png` (or a `<picture>` with `logo-dark` for dark mode), then the
  one-line pitch, then the demo video/GIF.
