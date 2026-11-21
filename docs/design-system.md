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
| `Theme.shadow` | black 6% | none | none | light-mode circle button lift |
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
| `.cardFace` | `.largeTitle` medium (34 at default size) | the card text in the middle |
| `.screenTitle` | `.title` bold (28) | list screen titles ("Cards") |
| `.body` | `.body` (17) | list row text, card back |
| `.meta` | `.footnote` (13) | dates, counts, status lines |

All styles are text styles, so they scale with Dynamic Type; the sizes are the defaults.
Layouts must reflow at accessibility sizes (`dynamicTypeSize.isAccessibilitySize`) rather than clip.
Study caps the card text, the `study.remaining` counter and the rating row at `.accessibility2` so they fit one
screen; longer card text scrolls (its scroll indicators flash on reveal).

Spacing `Theme.Spacing.s/m/l/xl` = 8/16/24/40. Row radius 12. Screen side margin 16–24.

## Components
- `CircleIconButton(systemImage, accessibilityLabel:)` — 44pt, surface fill, soft shadow (light) /
  hairline (dark). SF Symbols at regular weight: `list.bullet`, `plus`, `xmark`, `checkmark`, `gearshape`,
  `arrow.uturn.backward`, `arrow.clockwise`. The icon is a fixed 15pt so the 44pt circle never grows with Dynamic Type; instead the
  button supports the large content viewer (long-press shows the icon and its label large), the system
  fallback for fixed-size chrome.
- List row (deck, spec 002): surface fill, radius 12, meta line on top (due left, state right), front and back
  one line each.
- Swipe-to-delete: `Button("Delete", role: .destructive)`, the system destructive red. It is the one sanctioned
  non-token color; keep `.tint(Theme.ink)` off the `List` so it doesn't turn the action ink.
- Settings rows (spec 003): text field on a `surface` row, radius 12, 44pt min height, like the deck search field.

## Motion (`Theme.Motion`)
`standard` ease-in-out 0.25 s (fades, reveals) · `logoDrawIn` 0.9 s · `loadingPulse` 0.8 s. Every animation has a
Reduce Motion variant (a fade or nothing). Full motion principles: `docs/design/brand.md`.

## Logo (`DesignSystem/LaCarteLogo.swift`)
Two portrait cards fanned like playing cards; the front one has a word (pink line) and its answer (grey line).
Built from shapes in tokens (`ink` front, `secondaryInk` next card and answer, `accentOnInk` word). `LaCarteLogo(progress:)` is animatable (0 → 1 draw-in) and can be used with
`matchedGeometryEffect`. `LaCarteLaunchMark()` draws in once; `LaCarteLoadingMark()` loops. Both honor Reduce Motion.
Sources, SVG/PNG exports and the app icon: `docs/design/brand/` (regenerate with `render.sh`). Usage rules for
everyone, marketing included: `docs/design/brand.md`. Native-feel audit: `docs/design/native-audit.md`.

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
- Text doesn't truncate in the main area; long card text wraps and stays centered.
- Dynamic Type at XL doesn't break layout.
