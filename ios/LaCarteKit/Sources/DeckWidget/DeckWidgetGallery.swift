import APIClient
import DesignSystem
import SwiftUI
import WidgetKit

/// Every widget scenario in both families, under the app's theme, for QA screenshots (specs 007 #23, 024 #17).
/// Widgets aren't reachable from XCUITest; launch the app with `LA_CARTE_SCREEN=widget` (debug builds).
#if DEBUG
public struct DeckWidgetGallery: View {
  public init() {}

  private let scenarios = DeckWidgetEntry.scenarios(calendar: DeckStats.calendar)

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.l) {
        Text("Widget")
          .font(.screenTitle)
          .foregroundStyle(Theme.ink)
          .accessibilityIdentifier("widgetGallery.title")

        LazyVGrid(columns: Array(repeating: GridItem(.fixed(170), spacing: Theme.Spacing.m), count: 2)) {
          ForEach(scenarios, id: \.id) { scenario in
            tile(scenario.id, scenario.entry, .systemSmall, id: "small.\(scenario.id)")
          }
          tile("unavailable", DeckWidgetEntry(date: .now, content: .unavailable), .systemSmall, id: "unavailable")
        }
        ForEach(scenarios, id: \.id) { scenario in
          tile(scenario.id, scenario.entry, .systemMedium, id: "medium.\(scenario.id)")
        }
      }
      .padding(.horizontal, Theme.Spacing.m)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Theme.surface)  // the "wallpaper", so the background-colored tiles stand out
  }

  private func tile(_ name: String, _ entry: DeckWidgetEntry, _ family: WidgetFamily, id: String) -> some View {
    VStack(spacing: Theme.Spacing.s) {
      DeckWidgetTile(entry: entry, family: family)
        .accessibilityIdentifier("widgetGallery.tile.\(id)")
      Text(name)
        .font(.meta)
        .foregroundStyle(Theme.secondaryInk)
    }
    .padding(.bottom, Theme.Spacing.s)
  }
}
#endif

/// A widget as the Home Screen draws it, for the gallery, previews and renders: 16 pt content margins, `background`,
/// radius 22, at the iPhone 17 Pro's systemSmall (170 × 170) or systemMedium (364 × 170) size.
struct DeckWidgetTile: View {
  let entry: DeckWidgetEntry
  let family: WidgetFamily

  var body: some View {
    DeckWidgetView(entry: entry, family: family)
      .padding(Theme.Spacing.m)
      .frame(width: family == .systemMedium ? 364 : 170, height: 170)
      .background(Theme.background, in: .rect(cornerRadius: 22))
  }
}
