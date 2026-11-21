# la-carte brand kit

Owner: design-lead. **Marketing uses these files as they are: don't redraw, recolor or re-space the logo.**
Questions the kit doesn't answer go to design-lead.

## Logo
**Two portrait cards fanned like playing cards; the front one carries a word (pink) and its answer (grey).**
That's the app: one card on screen, and the next one comes back. (Chosen by the user from `brand/explorations/`.)

| File | Use |
|---|---|
| `brand/logo-light.svg` · `-dark` · `-forest` | Full-color mark on the matching background (see palette) |
| `brand/logo-mono.svg` | One color (`currentColor`, next card at 45%, lines cut out) for watermarks and embossing |
| `brand/png/logo-<theme>-{64,256,1024}.png` | Transparent PNG exports |
| `brand/app-icon/app-icon-{light,dark,tinted}.{svg,png}` | 1024 app icon sources (also installed in `AppIcon.appiconset`), plus `-58.png` (29 pt @2x) to check legibility |
| `brand/explorations/` | History: the three concepts shown to the user (`c-fan` was picked). **Not for use** |
| `scripts/brandkit.py` | New logo rounds (round 8 on): each `explorations/roundN/render.py` imports it (blue noise, hex lattice, matching, marks, SVG/PNG, contact sheet; usage in its docstring) instead of copying an older `render.py` |
| `brand/render.sh` | Regenerates every file above (`rsvg-convert`). The geometry lives in the script and in `LaCarteLogo.swift` |

In the app, use `LaCarteLogo(progress:)`, `LaCarteLaunchMark()` or `LaCarteLoadingMark()` from `DesignSystem`.
Never use a bitmap.

- **Geometry** (100×100 box): two cards 46×64 at (24, 17), radius 8, turned about (47, 81): the next card +12°,
  the front card −6°, with a transparent 2-unit gap around the front card. On the front card (in its own frame):
  the word, a 26×6 capsule at (32, 39) in `accentOnInk`, and the answer, a 16×6 capsule at (32, 51) in
  `secondaryInk`. Both lines are cut out in the mono and tinted versions.
- **Clear space:** at least 16% of the mark's box on every side (the card's corner radius × 2).
- **Minimum size:** 20 pt / 40 px box (the word must stay visible). It's designed to read at 29 pt.
- **Wordmark:** "la carte", always lowercase, SF Pro Text/Display medium, `ink`. It goes right of the mark,
  cap height ≈ 30% of the mark box. There is no custom wordmark font.
- **Don't:** recolor outside the palette · add outlines, shadows, gradients or glass · rotate or skew the
  cards or change the fan angle · make the word any color but the accent pair · add pink anywhere else in the mark · put the light mark on a dark background (use `logo-dark`) · animate it
  any other way than below.

## Palette (tokens from `Theme.swift`)
| Token | Light | Dark | Forest | Role |
|---|---|---|---|---|
| background | `#F9FAF5` | `#1A1A1A` | `#0E1913` | Every backdrop: video, README images, social cards |
| surface | `#FFFFFF` | `#252525` | `#16241B` | Raised elements only |
| ink | `#1C1C1C` | `#F2F2F0` | `#EEF2EC` | Text, the front card |
| secondaryInk | `#9D9D9B` | `#8A8A88` | `#83938A` | Captions' secondary line, the next card |
| accent | `#B8325A` | `#ED6E8C` | `#ED6E8C` | Pink, very small amounts (below) |
| accentOnInk | `#ED6E8C` | `#B8325A` | `#B8325A` | The logo's word only |

The accent pink is `#ED6E8C`; its darker text
shade `#B8325A`. **Very small amounts:** in the app it's limited to the logo's word, the text cursor/selection, the
widget's streak number and Study's count (`docs/design-system.md`). In marketing: the logo's word, and at most one
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
| Logo draw-in | ease-in-out 0.9 s (`logoDrawIn`): the front card fades and settles (0–35%), the next card fans out from behind it (30–70%), the word then the answer are written left to right (60–100%) | 0.25 s fade-in of the finished mark |
| Loading | word and answer write/erase, ease-in-out 0.8 s each way (`loadingPulse`) | Opacity pulse 100% ↔ 40% |
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
