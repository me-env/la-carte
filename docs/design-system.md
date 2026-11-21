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

Themes (spec 004): System, Light, Dark, Forest. Forest forces the dark color scheme. Tokens are
`ThemeColor` `ShapeStyle`s that resolve from the environment (`\.appTheme` + `colorScheme`); the root
applies the user's choice with `.appTheme(_:)`, which sets the window's `overrideUserInterfaceStyle`
(not `preferredColorScheme`, which leaves open sheets stuck when switching back to System). It's stored under the `theme` key with `@Shared(.appStorage)`
and picked in Settings → Appearance. QA can force a theme with the `-theme forest` launch argument.

Always use tokens, never literal colors.

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

## Screen patterns from the reference
| Vyst | la-carte |
|---|---|
| Editor: single word centered, icons in corners (01, 02) | **Study**: card front centered; tap reveals back below in `secondaryInk`; "Show answer" then a quiet Again/Hard/Good/Easy text row at the bottom (spec 001) |
| Notes list in dark (04) | **Deck**: list of cards, add + settings in the title row, search field below (spec 002) |
| Detail sheet with title + word count + round actions (03) | **Card editor** and **Settings** sheets: title top-left, round `checkmark`/`xmark` top-right (specs 002, 003) |
| Theme (05) | Settings → Appearance: System / Light / Dark / Forest (spec 004) |

## QA visual checklist
- Background is `Theme.background` edge to edge, light **and** dark.
- Nothing competes with the centered text; no default iOS blue tint (accent = ink).
- Buttons are the circle style, 44pt hit area, aligned to the same top margin.
- Text doesn't truncate in the main area; long card text wraps and stays centered.
- Dynamic Type at XL doesn't break layout.
