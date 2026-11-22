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
| `Theme.hairline` | black 8% | white 8% | white 8% | dark/forest button border |
| `Theme.accent` | `#B8325A` | `#ED6E8C` | `#ED6E8C` | pink, very small amounts only (rule below) |
| `Theme.accentOnInk` | `#ED6E8C` | `#B8325A` | `#B8325A` | the logo's word on the ink card |

Themes (spec 004): System, Light, Dark, Forest. Forest forces the dark color scheme. Tokens are
`ThemeColor` `ShapeStyle`s that resolve from the environment (`\.appTheme` + `colorScheme`); the root
applies the user's choice with `.appTheme(_:)`, which sets the window's `overrideUserInterfaceStyle`
(not `preferredColorScheme`, which leaves open sheets stuck when switching back to System). It's stored under the `theme` key with `@Shared(.appStorage)`
and picked in Settings → Appearance. QA can force a theme with the `-theme forest` launch argument.

Always use tokens, never literal colors.

**Accent: pink, in very small amounts**. `Theme.accent` = `#B8325A` light /
`#ED6E8C` dark and forest (text on `background`: 5.50 / 5.98 / 6.18:1, AA). `Theme.accentOnInk` = the reverse pair
(`#ED6E8C` light / `#B8325A` dark and forest), only for the logo's word on the ink card (5.85 / 5.14 / 5.09:1).
It may appear **only** in these places:
1. The logo's word line (`LaCarteLogo`, launch/loading marks, app icon, brand files).
2. The text cursor and selection in text fields (`.tint(Theme.accent)` on the field itself, not the screen): editor, Settings, deck search (spec 009), Study inline edit (spec 010). While a field is focused on Study, the counter (rule 4) is hidden, so only one pink element shows.
3. The widget's streak number when the streak is ≥ 1 (spec 007).
4. Study's "N to review" count in the counter text (`study.remaining`), just the number (spec 009).

Never: backgrounds, fills bigger than the logo's word, card text, body text, buttons/icons/toolbars, the rating row,
error or empty states. Swipe-delete stays the **system red** (hue 3°, vs the pink's 346°), so the pink never means
"destructive". At most one accent element visible at a time on a screen.

| Type | Font | Use |
|---|---|---|
| `.cardFace` | `.largeTitle` medium (34 at default size) | the card question, ≤ 24 chars (spec 017) |
| `.cardFaceMedium` | `.title` medium (28) | the card question, 25–60 chars |
| `.cardFaceSmall` | `.title2` medium (22) | the card question, > 60 chars or a line break (minimum; leading-aligned) |
| `.cardAnswer` | `.title2` (22) | a short answer (≤ 24 chars) under a question that isn't long; else `.body` |
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
- Settings rows (spec 003): text field on a `surface` row, radius 12, 44pt min height, like the deck search field.

## Liquid Glass (iOS 26; audit `docs/design/glass-audit-2026-11-22.md`)
Uniform by **layer**, not by material: glass where Apple's own apps put it, nowhere else.
- **Controls layer = glass**, from the system: toolbars and `ToolbarItem` buttons, `.searchable`, `Menu`,
  `.pickerStyle(.menu)`, `.contextMenu`, `.alert`, `.confirmationDialog`, sheets at a *partial* detent. Never
  `.presentationBackground(...)` on a partial-detent sheet, and no opaque row fills on it (rows sit on the glass,
  `.listRowBackground(Color.clear)`). Custom glass only where there is no system bar: `CircleIconButton`
  (`.glassEffect(.regular.interactive(), in: .circle)`), Study's top bar only.
- **Content layer = opaque tokens**: the card face, "Show answer" and the rating row (quiet text, not glass),
  messages and their actions ("Open Settings", "Try again": quiet text), deck rows, form rows (`Theme.surface`), full-height sheets (`Theme.background`; the system makes large
  detents opaque anyway). Never `.glassEffect` or materials on content.
- Widget: keep the removable `containerBackground(for: .widget)` so the system can apply its own glass on
  clear/tinted Home Screens.
- Reduce Transparency / Increase Contrast: system glass handles them; custom glass (only `CircleIconButton`) uses
  `.glassEffect`, which does too. Don't add your own fallback.

## Motion (`Theme.Motion`)
`standard` ease-in-out 0.25 s (fades, reveals) · `logoDrawIn` 0.9 s · `loadingPulse` 0.8 s. Every animation has a
Reduce Motion variant (a fade or nothing). Full motion principles: `docs/design/brand.md`.

## Logo (`DesignSystem/LaCarteLogo.swift`)
Two portrait cards fanned like playing cards; the front one has a word (pink line) and its answer (grey line).
Built from shapes in tokens (`ink` front, `secondaryInk` next card and answer, `accentOnInk` word). `LaCarteLogo(progress:)` is animatable (0 → 1 draw-in) and can be used with
`matchedGeometryEffect`. `LaCarteLaunchMark()` draws in once; `LaCarteLoadingMark()` loops. Both honor Reduce Motion.
Sources, SVG/PNG exports and the app icon: `docs/design/brand/` (regenerate with `render.sh`). Usage rules for
everyone, marketing included: `docs/design/brand.md`. Native-feel audit: `docs/design/native-audit.md`.

## Widget (`DeckWidget`, spec 007)
systemSmall only, system content margins, leading-aligned, no borders or icons, `Theme.background` via
`containerBackground(for: .widget)`:
```
┌───────────────────┐
│ 8                 │   hero      .cardFace ink, monospaced digits ("All caught up" / "No cards yet": .body medium)
│ to review         │   detail    .meta secondaryInk ("Next at 18:40", "Next on 24 Nov", "Ask your agent to add some")
│                   │
│ 12-day streak     │   streak    .meta ink, the number in Theme.accent ("No streak yet" in secondaryInk)
└───────────────────┘
```
Unavailable: only "Can't reach your deck" (`.meta`, `secondaryInk`). The theme comes from the App Group: System
follows the Home Screen, Light/Dark force it, Forest = forest palette + dark. Tinted/clear Home Screens
(`widgetRenderingMode != .fullColor`): the hero and the streak number are `.widgetAccentable()` and the ink tokens
become `.primary`/`.secondary`. Gallery (`LA_CARTE_SCREEN=widget`): 170 × 170 pt tiles (a systemSmall widget on
iPhone 17 Pro), `Theme.background`, radius 22, 16 pt padding, on a `Theme.surface` screen so the tiles stand out.

## Screen patterns from the reference
| Vyst | la-carte |
|---|---|
| Editor: single word centered, icons in corners (01, 02) | **Study**: card front centered; tap reveals back below in `secondaryInk`; "Show answer" then a quiet "Forgot / Got it" text row at the bottom (specs 001, 011); dragging the revealed card shows a ring of ink dots around the finger, scattered (forgot, left) to ordered (easy, right), no color (spec 011) |
| Notes list in dark (04) | **Deck**: list of cards, add + settings in the title row, search field below (spec 002) |
| Detail sheet with title + word count + round actions (03) | **Card editor** and **Settings** sheets: title top-left, round `checkmark`/`xmark` top-right (specs 002, 003) |
| Theme (05) | Settings → Appearance: System / Light / Dark / Forest (spec 004) |
| Editor, one centered message (01, 02) | **Setup/error message** ("Connect your deck", "Token rejected"): `.body` ink message, `.meta` `secondaryInk` detail, quiet text button ("Open Settings"), centered (spec 008) |

## QA visual checklist
- Background is `Theme.background` edge to edge, light **and** dark.
- Nothing competes with the centered text; no default iOS blue tint (button tint = ink). Pink appears only in the 4 accent places.
- Buttons are the circle style, 44pt hit area, aligned to the same top margin.
- Card text never truncates. Size and alignment follow its length (`CardText`, spec 017): a word or a short question is big and centred, a paragraph is smaller and leading-aligned, and the answer is always one tier below the question. Anything longer scrolls.
- Dynamic Type at XL doesn't break layout.
