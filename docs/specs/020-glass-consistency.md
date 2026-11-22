# 020 — Glass consistency: the report / ask sheet uses the system glass; Retry is a quiet text button

Status: ready
Owners: ios-engineer → qa-validator
Depends on: 015b (report sheet), 016 (Ask about this card)
Design reference: `docs/design/glass-audit-2026-11-22.md` (surface #5), rule in `docs/design-system.md` → Liquid Glass.
Current state: `qa/screenshots/design-glass/study-report-menu-{light,dark,forest-light}.png`.

## Goal
On iOS 26 Liquid Glass belongs to the controls layer that floats above content. Every floating surface in the app
already gets it from the system (toolbars, menus, context menus, alerts, dialogs) or from `CircleIconButton`,
except the report / ask sheet: it is a partial-height sheet acting as a menu, but
`.presentationBackground(Theme.background)` paints over the system glass and its rows are opaque `Theme.surface`
slabs. It reads as a different app from the "App" menu picker in Settings or the Deck context menu. Second, the
offline Retry is a glass circle inside a content message, next to the quiet text "Open Settings".
User feedback 2026-11-22: "maybe we have a mix of Liquid Glass and not".

## User story
- As the user, double-tapping a revealed card opens the same kind of floating glass panel as every other menu in
  iOS 26, with the card's answer still visible above it.

## Acceptance criteria

| # | Criterion | Test |
|---|---|---|
| 1 | The report / ask sheet has no custom presentation background: at its content-sized detent it shows the system Liquid Glass sheet (floating, inset from the screen edges), in light, dark and forest | UI screenshots (light, dark, forest): the colour sampled on an empty strip of the sheet (below the last row) differs from `Theme.background` (ΔE > 2) and differs between light and forest. Code review: no `.presentationBackground` on the sheet |
| 2 | Its rows have no opaque fill: they sit directly on the glass, like the system "App" menu in Settings. The two groups stay clearly apart: "Ask about this card" alone, then the five reasons, with a gap of at least 16 pt and no separator in it | UI screenshots: the centre of "I don't want this card"'s row (outside the text) vs the sheet margin left of it, ΔE < 2; the gap between the "Ask" row and "This is wrong" row is ≥ 16 pt with no separator line |
| 3 | Row text stays `Theme.ink` (`.body`) and legible: contrast between the row text and the sheet right behind it ≥ 4.5:1 in light, dark and forest | UI screenshots, measured on "This is wrong" in each theme |
| 4 | Nothing else changes: same rows, order, labels and identifiers (`study.report.*`), 44 pt rows, sheet sized to its rows so the revealed answer stays visible above it, the screen dims behind it, "Other…" still opens the "What's wrong?" alert on top | existing ReportUITests stay green; UI screenshot: the answer's bottom edge is above the sheet's top edge |
| 5 | Offline on Study and on Deck, Retry is a quiet text button "Try again" (`.body`, `Theme.ink`, ≥ 44 pt tall, no glass, no fill), like "Open Settings". Identifiers unchanged (`study.retry`, `deck.retry`); VoiceOver label "Try again" | UI screenshots (light, dark) of both offline states; existing retry tests stay green (by identifier) |

## Implementation notes (design)
- In `StudyView.reportMenu`: remove `.presentationBackground(Theme.background)`; in `menuItem`, replace the
  `Theme.surface` row background with `.listRowBackground(Color.clear)`. Keep `.scrollContentBackground(.hidden)`
  (otherwise the grouped list background covers the glass). No `.glassEffect`, no material: the glass is the
  sheet's own, which is the point.
- Reduce Transparency / Increase Contrast: the system sheet already falls back to an opaque, higher-contrast
  material. Nothing to build; QA captures one Reduce Transparency screenshot of the sheet to confirm.
- Keep the List's section spacing at least 16 pt between the two groups (`.listSectionSpacing(.compact)` may be
  smaller once fills are gone: use `.listSectionSpacing(Theme.Spacing.m)` if needed).
- Retry (`StudyView` offline, `DeckView.unavailable`): replace `CircleIconButton("arrow.clockwise", …)` with
  the same quiet text button as "Open Settings" (`Button("Try again")`, `.font(.body)`, `Theme.ink`,
  `minHeight: 44`). `CircleIconButton` stays for the Study top bar only.
- If AC 3 fails in one theme (unlikely: the system glass adapts its tint to what's behind it), report it to
  design-lead rather than painting a fill back in.
- Out of scope: changing the gesture (a long-press `.contextMenu` on the card would also be glass and native, but
  that is a product decision for spec 015); glass on the rating row or cards (content layer, see the audit).
