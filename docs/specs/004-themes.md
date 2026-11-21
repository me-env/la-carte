# 004 — Themes (system / light / dark / forest)

Status: done
Owners: ios-engineer
Depends on: 003 (picker lives in Settings). The DesignSystem part (step 1) can start any time.
Design reference: docs/design/reference/05-theme-forest.jpg (forest), 01/02 (dark/light)

## Goal
The user picks how the app looks: follow the system, always light, always dark, or "forest" (deep green
dark theme from Vyst). The choice persists across launches. Covers backlog item 7.

## User stories
- As the user, I open Settings → Appearance and pick System, Light, Dark or Forest; the whole app
  (study, deck, editor, settings) changes immediately and stays that way next launch.

## Acceptance criteria
| # | Criterion (observable) | Validated by |
|---|---|---|
| 1 | Settings shows an "Appearance" section with four options `settings.theme.system/light/dark/forest`; the current one has the selected trait; default is System | unit + UI |
| 2 | Tapping an option stores it in `@Shared(.appStorage("theme"))` and the whole app re-renders immediately, including the open sheets | unit + UI |
| 3 | System follows the device appearance; Light and Dark force it regardless of the device; Forest forces a dark color scheme (status bar, keyboard) with the forest palette | UI (device dark + Light chosen; device light + Forest chosen) |
| 4 | Forest palette: background `#0E1913`, surface `#16241B`, ink `#EEF2EC`, secondaryInk `#83938A`, hairline white 8%. Light/dark values unchanged | screenshot review |
| 5 | The choice survives relaunch | UI |
| 6 | Launch argument `-theme forest` (UserDefaults argument domain) starts the app in forest, so QA can screenshot any screen in forest without tapping through Settings | UI |
| 7 | `DesignSystem` still has no TCA/Sharing import; feature code keeps using `Theme.background` etc. with no call-site changes beyond what the compiler requires | review |

## Design: how tokens become theme-aware
Simplest approach with no globals and no UIKit traits: tokens become a `ShapeStyle` that resolves itself
from the SwiftUI environment.

In `DesignSystem` (plain SwiftUI):
```swift
public enum AppTheme: String, CaseIterable, Sendable { case system, light, dark, forest }

public struct ThemeColor: ShapeStyle {          // replaces the Color(light:dark:) tokens
  let light: Color, dark: Color, forest: Color
  public func resolve(in environment: EnvironmentValues) -> Color {
    if environment.appTheme == .forest { return forest }
    return environment.colorScheme == .dark ? dark : light
  }
}
extension EnvironmentValues { @Entry public var appTheme: AppTheme = .system }

extension View {
  /// Applies the theme: sets `\.appTheme` and the window's `overrideUserInterfaceStyle`
  /// (.unspecified / .light / .dark / .dark).
  public func appTheme(_ theme: AppTheme) -> some View
}
```
`Theme.background/surface/ink/secondaryInk/hairline` become `ThemeColor` values. They work everywhere a
`ShapeStyle` is accepted (`foregroundStyle`, `background`, `fill`, `strokeBorder`, `tint`,
`presentationBackground`). Where a `Color` is strictly required, use `Rectangle().fill(token)` or similar.

Apply `.appTheme(theme)` once, at the root (`RootView`, including the design-system gallery). Don't re-apply it
on sheets.

*As built (QA round 1 fix):* `preferredColorScheme` left open sheets stuck on the old scheme when switching
back to System. Setting the window's `overrideUserInterfaceStyle` fixes it, because every presented sheet
inherits the window's traits. Follow-up (review, not needed today): reset the override in
`willMove(toWindow:)` if `.appTheme` is ever used below the root.

## Screens & states
Settings gains section caption "Appearance" (`.meta`) and one row of four equal-width text buttons
("System", "Light", "Dark", "Forest", `.body`). Selected = `ink` fill with `background`-colored text;
others = `surface` fill with `ink` text; radius 12.

Screenshots (light device unless noted): `settings-appearance` (light + dark), `study-forest`,
`study-revealed-forest`, `deck-forest`, `editor-forest`, `settings-forest`, `design-system-forest`,
`study-forced-light` (device dark, theme Light), `study-forced-dark` (device light, theme Dark).

## TCA shape (iOS)
- Shared key, declared once in `SettingsFeature`:
  `extension SharedKey where Self == AppStorageKey<AppTheme>.Default { static var theme: Self { Self[.appStorage("theme"), default: .system] } }`
- `SettingsFeature.State`: `@Shared(.theme) var theme`; action `themeTapped(AppTheme)` → `state.$theme.withLock { $0 = theme }`.
- `AppFeature.State`: `@Shared(.theme) var theme` (read-only); `AppView`/`RootView` apply `.appTheme(store.theme)`.
  `AppFeature` imports `SettingsFeature` for the key (parent → descendant, allowed).
- No new actions in App; `@Shared` observation re-renders the view.
- Gallery: uses the same root modifier so `-theme forest` affects it.

## API / MCP changes
None.

## Accessibility identifiers
`settings.theme.system`, `settings.theme.light`, `settings.theme.dark`, `settings.theme.forest`.

## Notes for QA
While `-theme <value>` is passed, the argument domain wins over what Settings writes, so don't combine it
with tests that tap the picker.

## Out of scope
- Per-theme fonts, app icon variants, more themes, scheduled (time-of-day) themes.
