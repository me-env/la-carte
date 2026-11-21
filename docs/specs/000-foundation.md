# 000: Foundation: walking skeleton + design system

Status: done
Owners: ios-engineer / api-engineer (built during setup)
Design reference: docs/design/reference/02-editor-light.jpg, 01-editor-dark.jpg, 04-list-dark.jpg

## Goal
Prove the app ↔ API wiring and lock the design system before features are built on top of it.

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | Launching with the mock deck (`LA_CARTE_API=mock`, 3 fixture cards, all due) shows `app.title` "la carte" centered and `app.summary` "3 to review" | UI, light + dark |
| 2 | Against a live API seeded with N due cards, `app.summary` reads "N to review" | UI (`_liveAPI`, scripts/e2e.sh) |
| 3 | If the API is unreachable, `app.summary` reads "Can't reach your deck" | UI (point `LA_CARTE_API_URL` at a closed port) |
| 4 | The design-system gallery (`LA_CARTE_SCREEN=design-system`) shows every color token, the 4 type styles, and 4 circle buttons, in both appearances | UI, light + dark |
| 5 | Tapping each gallery circle button (`gallery.button.<symbol>`) updates `gallery.lastTapped` to "Last tapped: <symbol>" (the hit area works) | UI interaction |
| 6 | Gallery and home stay readable at Dynamic Type accessibility XL (no clipped or overlapping text) | UI, launch argument `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXL` |
| 7 | Visuals match `docs/design-system.md`: warm off-white / charcoal backgrounds edge to edge, no default blue tint, circle buttons 44pt with a soft shadow in light and a hairline in dark | Screenshot review |

## Screens & states (screenshots, light + dark unless noted)
`home`, `home-offline` (light), `home-live` (light), `design-system`, `design-system-tapped` (light),
`design-system-xl`, `home-xl` (light)

## Accessibility identifiers
`app.title`, `app.summary`, `gallery.button.list.bullet`, `gallery.button.plus`, `gallery.button.xmark`,
`gallery.button.arrow.uturn.backward`, `gallery.lastTapped`

## Out of scope
Study flow, deck list, settings (see backlog).
