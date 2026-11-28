# Design system

Reference: **Vyst** (App Store id 6760647645). Screenshots in `docs/design/reference/`
(re-download with `scripts/fetch-design-refs.sh`). We borrow its *feel*, not its screens.

## Principles
1. **One thing on screen.** The card's text, centered, large. Everything else is quiet.
2. **Paper, not UI.** Flat warm background, no cards-within-cards, no gradients, no borders unless needed.
3. **Chrome is small and round.** Actions are 44pt circular icon buttons tucked into the corners.
4. **Calm motion.** Short ease-in-out fades/slides (0.25–0.35s). Nothing bounces.
5. **Quiet text hierarchy.** One strong weight per screen; metadata is small and grey.

## Tokens (`DesignSystem/Theme.swift`)

| Token | Light | Dark | Forest | Use |
|---|---|---|---|---|
| `Theme.background` | `#F9FAF5` | `#1A1A1A` | `#0E1913` | every screen |
| `Theme.surface` | `#FFFFFF` | `#252525` | `#16241B` | circle buttons, list rows |
| `Theme.ink` | `#1C1C1C` | `#F2F2F0` | `#EEF2EC` | primary text, icons |
| `Theme.secondaryInk` | `#9D9D9B` | `#8A8A88` | `#83938A` | metadata, hints |
| `Theme.recededInk` | `#6F6F6D` | `#8A8A88` | `#83938A` | text that steps back but must stay readable: every question once its answer shows (spec 017 #16, #17). AA on `background`: 4.8 / 5.0 / 5.6:1 |
| `Theme.hairline` | black 8% | white 8% | white 8% | dark/forest button border |
| `Theme.accent` | `#B8325A` | `#ED6E8C` | `#ED6E8C` | pink: the logo's line, then very small amounts only (rule below) |

Themes (spec 004): System, Light, Dark, Forest. Forest forces the dark color scheme. Tokens are
`ThemeColor` `ShapeStyle`s that resolve from the environment (`\.appTheme` + `colorScheme`); the root
applies the user's choice with `.appTheme(_:)`, which sets the window's `overrideUserInterfaceStyle`
(not `preferredColorScheme`, which leaves open sheets stuck when switching back to System). It's stored under the `theme` key with `@Shared(.appStorage)`
and picked in Settings → Appearance. QA can force a theme with the `-theme forest` launch argument.

Always use tokens, never literal colors.

**Accent: pink, in very small amounts**. `Theme.accent` = `#B8325A` light /
`#ED6E8C` dark and forest (text on `background`: 5.50 / 5.98 / 6.18:1, AA).
It may appear **only** in these places:
1. The logo's line outside the card (`LaCarteLogo`, launch/loading marks, app icon, brand files): the one larger
   pink use, by the user's choice of logo.
2. The text cursor and selection in text fields (`.tint(Theme.accent)` on the field itself, not the screen): editor, Settings, deck search (spec 009), Study inline edit (spec 010). While a field is focused on Study, the counter (rule 4) is hidden, so only one pink element shows.
3. The widget's today mark only: the ring while today is pending, the solid mark once studied (spec 024).
4. The number in Study's counter (`study.remaining`), whatever the unit ("8 to review", "1 at risk", "15 new"):
   the number only, never the unit, the milestones popover, its bars and checkmarks, or the "… done" notices (specs 009, 021).
5. A fifth of the `RatingDial`'s dots while a drag is held toward Forgot (spec 019 §3, user request 2026-11-22):
   the one colour cue that tells Forgot from Hard. It grows in with the scatter and is gone on release; the only
   moment two pink elements share the screen (with rule 4), and it is transient.

Never: backgrounds, fills bigger than the logo's line, card text, body text, buttons/icons/toolbars, the rating row,
error or empty states. Swipe-delete stays the **system red** (hue 3°, vs the pink's 346°), so the pink never means
"destructive". At most one accent element visible at a time on a screen.

| Type | Font | Use |
|---|---|---|
| `.cardFace` | `.largeTitle` medium (34 at default size) | the card question, ≤ 24 chars (spec 017) |
| `.cardFaceMedium` | `.title` medium (28) | the card question, 25–60 chars |
| `.cardFaceSmall` | `.title2` medium (22) | the card question, > 60 chars or a line break (minimum; leading-aligned); also a short answer (≤ 24 chars) under such a question (spec 017 #16) |
| `.cardAnswer` | `.title2` (22) | a short answer (≤ 24 chars) under a question that isn't long; a longer answer is `.body` |
| `.screenTitle` | `.title` bold (28) | list screen titles ("Cards") |
| `.body` | `.body` (17) | list row text, card back |
| `.meta` | `.footnote` (13) | dates, counts, status lines |

All styles are text styles, so they scale with Dynamic Type; the sizes are the defaults.
Layouts must reflow at accessibility sizes (`dynamicTypeSize.isAccessibilitySize`) rather than clip.
Study caps the card text, the `study.remaining` counter and the rating row at `.accessibility2` so they fit one
screen; longer card text scrolls (its scroll indicators flash on reveal).

Spacing `Theme.Spacing.xs/s/m/l/xl` = 4/8/16/24/40 (`xs` only for a caption tight under its sample). Radius `Theme.Radius.row` 12, `Theme.Radius.photo` 20 (card-face photo, continuous). Photo sizes `Theme.Photo.thumbnail/preview/card/cardCompact` = 44/88/240/160 pt (card is a width, 4:5 portrait; compact at accessibility sizes; spec 014). Screen side margin 16–24.

## Components
- `CircleIconButton(systemImage, accessibilityLabel:)` — 44pt Liquid Glass circle, like the system toolbar buttons on
  Deck, Settings and the editor. SF Symbols at regular weight: `list.bullet`, `plus`, `xmark`, `checkmark`, `gearshape`,
  `arrow.uturn.backward`. Chrome only (Study top bar), never inside content (spec 020). The icon is a fixed 17pt (the toolbar glyph size) so the 44pt circle never grows with Dynamic Type; instead the
  button supports the large content viewer (long-press shows the icon and its label large), the system
  fallback for fixed-size chrome.
- List row (deck, spec 002): surface fill, radius 12, meta line on top (due left, state right), front and back
  one line each.
- Swipe-to-delete: `Button("Delete", role: .destructive)`, the system destructive red. It is the one sanctioned
  non-token color; keep `.tint(Theme.ink)` off the `List` so it doesn't turn the action ink.
- `CardPhoto(url:style:)` (spec 014) — a person's photo from a URL (`AsyncImage`) in a fixed frame: `.thumbnail`/`.preview` circles (deck row, editor), `.card` 4:5 rounded rect (Study). Loading = `hairline` fill, failure/none = `person.fill` in `secondaryInk`, 1 pt `hairline` stroke, label "Photo". Never logs the URL.
- Multi-select rows (note directions, spec 014c): checkmark rows (ink `checkmark`, `.isSelected` trait), not `Toggle` switches, so no green or low-contrast track.
- `ContinueWithGoogleButton(isLoading:action:)` (spec 030c) — Google's "Continue with Google" pill to their
  branding guidelines: Google Sans Medium (bundled subset), the unaltered standard-colour "G" (`Brand.xcassets`),
  Google's Light theme in light and Dark theme in dark/forest, 50 pt, full width. Google's colours are the one
  third-party literal palette, kept inside this file. Never tint, glass or restyle it; a future Sign in with Apple
  button gets the same size.
- Settings rows (spec 003): text field on a `surface` row, radius 12, 44pt min height, like the deck search field.

## Liquid Glass (iOS 26; audit `docs/design/glass-audit-2026-11-22.md`)
Uniform by **layer**, not by material: glass where Apple's own apps put it, nowhere else.
- **Controls layer = glass**, from the system: toolbars and `ToolbarItem` buttons, `.searchable`, `Menu`,
  `.pickerStyle(.menu)`, `.contextMenu`, `.alert`, `.confirmationDialog`, sheets at a *partial* detent. Never
  `.presentationBackground(...)` on a partial-detent sheet, and no opaque row fills on it (rows sit on the glass,
  `.listRowBackground(Color.clear)`). Custom glass only where there is no system bar: `CircleIconButton`
  (`.glassEffect(.regular.interactive(), in: .circle)`) and its peer, Study's milestone counter (`study.remaining`,
  `.buttonStyle(.glass)`: the system glass capsule, 44 pt tall, `.meta` secondary ink with only the number pink),
  Study's top bar only. The milestones popover (`study.milestones`) is system glass: `.popover` +
  `.presentationCompactAdaptation(.popover)`, no `.presentationBackground`, no fills; rows only (no title, buttons or
  sentences): done = `.body` secondary ink + `checkmark`, current = `.body` ink + "done/total" + an ink `ProgressView`.
  Step notices ("At risk done", "Reviews done", "15 new done") are plain notice-slot text like "Reported": secondary
  ink, no accent (spec 021).
- **Content layer = opaque tokens**: the card face, "Show answer" and the rating row (quiet text, not glass),
  messages and their actions ("Open Settings", "Try again": quiet text), deck rows, form rows (`Theme.surface`), full-height sheets (`Theme.background`; the system makes large
  detents opaque anyway). Never `.glassEffect` or materials on content.
- Widget: keep the removable `containerBackground(for: .widget)` so the system can apply its own glass on
  clear/tinted Home Screens.
- Reduce Transparency / Increase Contrast: system glass handles them; custom glass (only `CircleIconButton`) uses
  `.glassEffect`, which does too. Don't add your own fallback.

## Motion (`Theme.Motion`)
`standard` ease-in-out 0.25 s (fades, reveals) · `logoDrawIn` 0.9 s · `logoTilt` 1.0 s (the launch mark's card laying flat from a 3D tilt) · `loadingPulse` 0.8 s. Every animation has a
Reduce Motion variant (a fade or nothing). Full motion principles: `docs/design/brand.md`.

## Logo (`DesignSystem/LaCarteLogo.swift`)
A portrait card crossed by the forgetting curve as one thick line: cut out of the card inside it, pink outside it.
Built from shapes in tokens (`ink` card, `accent` line; the cut-out shows what's behind). Geometry constants are
generated into `LaCarteLogoGeometry.swift` by `docs/design/brand/render.py` (don't edit by hand).
`LaCarteLogo(progress:)` is animatable (0 → 1: the card settles, then the curve is drawn) and can be used with
`matchedGeometryEffect`. `LaCarteLaunchMark()` draws in once while its card lays itself flat from a 3D tilt (frames: `RenderTests/launchMark`), 64 pt above Study's "All caught up" (`study.logo`); never at app launch, so nothing delays the first card; `LaCarteLoadingMark()` draws and erases the curve.
Both honor Reduce Motion (static mark / opacity pulse). The line's first stroke-width grows from zero width, so
nothing pops in or out at the start of a draw or the end of an erase (a round cap alone is a full dot).
Sources, SVG/PNG exports and the app icon: `docs/design/brand/` (regenerate with `uv run docs/design/brand/render.py`). Usage rules for
everyone, marketing included: `docs/design/brand.md`. Native-feel audit: `docs/design/native-audit.md`.

## Widget (`DeckWidget`, specs 007, 024)
systemSmall and systemMedium, one kind. System content margins, leading-aligned, no borders or icons,
`Theme.background` via `containerBackground(for: .widget)`:
```
small                        medium: left = 007's block, right = small's grid + label, both bottom-aligned
┌───────────────────┐        ┌──────────────────────────────────────┐
│ 8 to review       │ .body  │ 8                ■ ■ ■ ■ ■ ■ ●       │ hero .cardFace ink, monospaced digits
│ ■ ■ ■ ■ ■ ■ ●     │ medium │ to review        ● ● ● ● ● ● ●       │ ("All caught up" / "No cards yet": .body
│ ● ● ● ● ● ● ●     │ ink    │                  ● ● ● ● ● ● ●       │  medium, detail .meta secondaryInk)
│ ● ● ● ● ○ ● ◎     │        │                  ● ● ● ● ○ ● ◎       │
│ 60-day streak     │ .meta semibold ink ("Start a streak today": .meta secondaryInk)
└───────────────────┘        └──────────────────────────────────────┘
```
**Grid** (`StreakGrid` maths, `StreakGridView` draws): 4 × 7, always full, oldest top-left, today last, 19 pt pitch
(133 × 76 pt). Older periods coarsen by unit; every shape has the same ink area (~64 pt²):

| Unit | Mark |
|---|---|
| day | circle Ø 9 |
| week | rounded square 8.5, radius 2 |
| month | rounded pentagon, point up, circumradius 5.5, corner 1.2 (0.25 pt low) |
| year | rounded 5-point star, radii 7.4 / 3.7, corner 1.2 (0.5 pt low) |

| Status | Look (all themes) |
|---|---|
| run | `ink`, solid |
| older | `secondaryInk` 60 %, solid |
| missed | `secondaryInk` 35 %, solid |
| frozen (day only) | hollow circle, 1.5 pt inside stroke: `ink` in the run, `secondaryInk` 60 % before it |
| today, pending | 2 pt `accent` ring over a `secondaryInk` 35 % fill |
| today, studied | `accent`, solid |

Unavailable: only "Can't reach your deck" (`.meta`, `secondaryInk`). The theme comes from the App Group: System
follows the Home Screen, Light/Dark force it, Forest = forest palette + dark. Tinted/clear Home Screens
(`widgetRenderingMode != .fullColor`): `ink` → `.primary`, `secondaryInk` → `.secondary` (the 35 % and 60 % opacities
kept), and only today's mark is `.widgetAccentable()`; frozen and today stay distinct by stroke. Gallery
(`LA_CARTE_SCREEN=widget`) and renders (`ScreenColorTests/WidgetRenders`): 170 × 170 / 364 × 170 pt tiles,
`Theme.background`, radius 22.

## Screen patterns from the reference
| Vyst | la-carte |
|---|---|
| Editor: single word centered, icons in corners (01, 02) | **Study**: card front centered; tap reveals back below in `ink` as the question recedes to `recededInk`; "Show answer" then a quiet "Forgot / Got it" text row at the bottom (specs 001, 011); dragging the revealed card shows a 96-dot `RatingDial` around the finger whose order is the grade: the dots settle into 3 evenly spaced rings (29 / 32 / 35 dots), one size, toward Got it / Easy (up, right) and scatter with varied sizes toward Hard / Forgot (down, left); Easy links each ring's dots into three full chains with thin lines (grown in only past 60 % of the way from Got it, so Got it never shows a line), Forgot turns a fifth of the dots pink; the row echoes the grade (specs 011, 019) |
| Notes list in dark (04) | **Deck**: list of cards, add + settings in the title row, search field below (spec 002) |
| Detail sheet with title + word count + round actions (03) | **Card editor** and **Settings** sheets: title top-left, round `checkmark`/`xmark` top-right (specs 002, 003) |
| Theme (05) | Settings → Appearance: System / Light / Dark / Forest (spec 004) |
| Editor, one centered message (01, 02) | **Setup/error message** ("Connect your deck", "Token rejected"): `.body` ink message, `.meta` `secondaryInk` detail, quiet text button ("Open Settings"), centered (spec 008) |

## QA visual checklist
Screen visuals are judged on real-view renders (`scripts/ios-test.sh --render`) or UI-test screenshots, never hand-built mocks. Glass is judged only on UI-test screenshots.
Study screen catalogue: `scripts/ios-test.sh --render -only-testing:ScreenColorTests/StudyRenders` writes
`screen-study-<state>-<theme>-<scheme>.png`; the states are listed in
`ios/LaCarteKit/Tests/ScreenColorTests/StudyRenders.swift` (docs/testing.md).

- Background is `Theme.background` edge to edge, light **and** dark.
- Nothing competes with the centered text; no default iOS blue tint (button tint = ink). Pink appears only in the 5 accent places.
- Buttons are the circle style, 44pt hit area, aligned to the same top margin.
- Card text never truncates. Size and alignment follow its length (`CardText`, spec 017): a word or a short question is big and centred, a paragraph is smaller and leading-aligned, and the answer is always one tier below the question. One axis per card (spec 017 #16, user 2026-11-28): a question of 3+ rendered lines is leading at the column's 16 pt edge and its answer, whatever its length, shares that edge; a question of 1-2 lines is centred and its answer centres at 1-2 lines, leads at 3+. Weight transfer on every card (spec 017 #17): the answer is drawn in `ink` and on reveal the question (a person card's name or description prompt too, never the photo) crossfades to `recededInk` (`Motion.standard`, kept under Reduce Motion). Anything longer scrolls.
- Dynamic Type at XL doesn't break layout.
