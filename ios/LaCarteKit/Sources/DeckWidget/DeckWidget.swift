import APIClient
import DesignSystem
import SwiftUI
import WidgetKit

/// The Home Screen widget: the streak as a history grid and the cards to review (specs 007, 024). Tapping it opens the
/// app on Study.
public struct DeckWidget: Widget {
  public init() {}

  public var body: some WidgetConfiguration {
    StaticConfiguration(kind: "DeckWidget", provider: DeckWidgetProvider()) { entry in
      FamilyView(entry: entry)
        .containerBackground(Theme.background, for: .widget)
        .widgetTheme(storedTheme)
    }
    .configurationDisplayName("la carte")
    .description("Your streak and cards to review.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }

  /// Read on every render; the app reloads timelines when it goes to the background, so theme changes show up.
  private var storedTheme: AppTheme {
    AppGroup.defaults.string(forKey: AppTheme.storageKey).flatMap(AppTheme.init(rawValue:)) ?? .system
  }

  /// Hands WidgetKit's family to `DeckWidgetView`, which takes it as a parameter.
  private struct FamilyView: View {
    let entry: DeckWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
      DeckWidgetView(entry: entry, family: family)
    }
  }
}

#Preview("small", as: .systemSmall) {
  DeckWidget()
} timeline: {
  for scenario in DeckWidgetEntry.scenarios(calendar: DeckStats.calendar) {
    scenario.entry
  }
  DeckWidgetEntry(date: .now, content: .unavailable)
}

#Preview("medium", as: .systemMedium) {
  DeckWidget()
} timeline: {
  for scenario in DeckWidgetEntry.scenarios(calendar: DeckStats.calendar) {
    scenario.entry
  }
}
