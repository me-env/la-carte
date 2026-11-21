# Native-feel audit

Date: 2026-11-21 · by design-lead · scope: `ios/LaCarteKit/Sources/**`, `docs/design-system.md`, specs 001–008.
Reference: Vyst (`docs/design/reference/`, fetch with `scripts/fetch-design-refs.sh`).

**Bar:** it should feel like Apple made a calm, minimal flashcard app. On iOS 26+ that means the system's own
chrome (Liquid Glass toolbars, search, sheets, empty states, haptics), with the Vyst feel (paper background,
one thing centered, quiet type) on top. Today the app re-draws most chrome by hand. It looks right in screenshots,
but it misses system behavior: glass, press states, discard protection, search affordances, haptics.

Items marked **→ 009** are proposed in [`specs/009-native-polish.md`](../specs/009-native-polish.md).
Specs 006 (refresh, in review), 007 (widget) and 008 (setup) are in flight. 009 does not overlap them, and lands
after 006 and 008.

## Hand-rolled where a system component does better

| P | Where | Today | Native API | Why |
|---|---|---|---|---|
| **P0** | App target | **No app icon at all**: there is no `AppIcon.appiconset` and no `ASSETCATALOG_COMPILER_APPICON_NAME` | Asset-catalog `AppIcon` (1024, light/dark/tinted), now in `ios/LaCarte/Assets.xcassets/AppIcon.appiconset` | The Home Screen shows a blank placeholder. Needs the one build setting **→ 009 #1** |
| **P1** | Card editor, Settings (sheet headers) | Custom `HStack` title + `CircleIconButton` ✓/✕ | `NavigationStack` + `.navigationTitle` + `.toolbar { ToolbarItem(placement: .confirmationAction) { Button(role: .confirm) }; ToolbarItem(placement: .cancellationAction) { Button(role: .close) } }` | iOS 26 draws these as the round glass buttons we imitate, with press states, the large content viewer and the right VoiceOver order for free **→ 009** |
| **P1** | Deck sheet header | Custom title row + gear/plus circles | Same: `NavigationStack`, large `.navigationTitle("Cards")`, `.toolbar` items | Large title that collapses on scroll, glass buttons, no manual top padding **→ 009** |
| **P1** | Deck search | `TextField` + magnifying glass on a surface row | `.searchable(text:placement: .navigationBarDrawer(displayMode: .always))` + `ContentUnavailableView.search(text:)` for "No matches" | Clear button, Cancel, keyboard Search key, scroll-to-hide, standard no-results screen **→ 009** |
| **P1** | Study/Deck messages: "Can't reach your deck", "No cards yet", 008's "Connect your deck" / "Token rejected" | `Text` (+ circle retry button) centered in a scroll view | `ContentUnavailableView { Label(_, systemImage:) } description: { Text } actions: { Button }`, still inside the `pullable` scroll view (006) | Standard empty-state layout, Dynamic Type and VoiceOver grouping. One pattern instead of four hand-made ones **→ 009** (008 annotated) |
| **P1** | Card editor dismissal | Swiping down discards typed text silently | `.interactiveDismissDisabled(hasChanges)` + `.confirmationDialog("Discard changes?")` on close | The standard iOS editor behavior. Data loss today **→ 009** |
| **P1** | Haptics | None | `.sensoryFeedback(.selection, trigger: isRevealed)`, `.sensoryFeedback(.success, trigger: reviewedCount)` on rating, `.impact(weight: .light)` on delete, `.error` on failures | Feels physical and native, costs one modifier each **→ 009** |
| **P2** | Settings screen | `VStack` of surface rows, hand-made 4-button theme selector, `onTapGesture` to focus | `Form` with `Section("Server")` (`TextField`, `SecureField`, `Button`, `LabeledContent` status) and `Section("Appearance") { Picker(selection:) { … }.pickerStyle(.segmented) }` | Settings is a utility screen, and users expect a Form there. We drop the `SurfaceRow` modifier and the selection logic. Tint and backgrounds stay tokens (`.scrollContentBackground(.hidden)`) **→ 009** |
| **P2** | Study "N to review" counter | Plain text swap | `.contentTransition(.numericText(countsDown: true))` | The number ticks down as you rate. Calm, native **→ 009** |
| **P2** | Study loading | `Color.clear` | `LaCarteLoadingMark` (new, `DesignSystem`) after 0.5 s | A blank screen looks broken on slow networks. Custom is justified here because it is the brand mark **→ 009** |
| **P2** | Launch | Generated blank launch screen (white flash in dark mode) | `UILaunchScreen` → `UIColorName` = new `LaunchBackground` colorset (Theme.background light/dark) | No white flash. Forest can't be known before launch, so it shows dark **→ 009** |
| **P2** | Deck rows | Tap opens editor; swipe deletes | Add `.contextMenu { Button("Edit"); Button("Delete", role: .destructive) }` | Long-press is how iOS users look for actions **→ 009** |
| **P3** | Deck due line | `RelativeDateTimeFormatter` + `"Due " +` concatenation; `card.state.rawValue` shown raw | `Text("Due \(card.due, format: .relative(presentation: .numeric))")` and a localized state label | Localizes properly. Small. Leave for a later copy pass |
| **P3** | Study → Deck | Plain sheet | `.navigationTransition(.zoom(sourceID:in:))` from `study.deck` | Nice, but zoom from a 44 pt button into a sheet is a stretch. Revisit after 009 |

## Custom where custom is justified (keep)

| Where | Why it stays custom |
|---|---|
| Study card face (front centered, back fades in, quiet rating row) | This is the product and the Vyst feel. No system component fits. Rating buttons stay plain text, ≥ 44 pt |
| Study top bar (deck + add circles) | Study has no title, so a navigation bar would add chrome. Keep `CircleIconButton`, but **→ 009** renders it with `.buttonStyle(.glass)` + `.buttonBorderShape(.circle)` so it matches toolbar buttons elsewhere |
| Deck list rows on `surface` with radius 12 | The reference's note list. Still a native `List` with `.swipeActions` and `.refreshable` (good) |
| `WindowStyle` (`overrideUserInterfaceStyle`) | Documented reason: `preferredColorScheme(nil)` leaves open sheets stuck |
| Logo (`LaCarteLogo`) | It's the brand, so we draw it ourselves |

## Already native (good)
`List` + `.swipeActions` with system destructive red · `.refreshable` (006) · `.sheet` presentation · text styles
for Dynamic Type, capped where layout demands · large content viewer on fixed-size chrome · `AccentColor` = ink
(no iOS blue) · `ViewThatFits` reflow at accessibility sizes · `.scrollDismissesKeyboard`.

## Notes for in-flight specs
- **006 (refresh):** no change. Any 009 migration keeps `.refreshable` on the same content.
- **007 (widget):** on iOS 26 the Home Screen can be tinted or clear, and widgets then render in `.accented` mode.
  Mark the hero number `.widgetAccentable()`. Read `@Environment(\.widgetRenderingMode)` and drop `secondaryInk`
  to `.secondary` opacity there, so the tokens don't turn muddy. Annotated in 007.
- **008 (setup):** its new states are exactly what `ContentUnavailableView` is for. If 008 hasn't started its views,
  build them that way (same ids on the inner texts and button). If it has, keep 008 as written and 009 converts
  them. Annotated in 008.
