import APIClient
import DesignSystem
import SwiftUI
import WidgetKit

/// The Home Screen widget: cards due now and the study streak (spec 007). Tapping it opens the app on Study.
public struct DeckWidget: Widget {
  public init() {}

  public var body: some WidgetConfiguration {
    StaticConfiguration(kind: "DeckWidget", provider: DeckWidgetProvider()) { entry in
      DeckWidgetView(entry: entry)
        .containerBackground(Theme.background, for: .widget)
        .widgetTheme(storedTheme)
    }
    .configurationDisplayName("la carte")
    .description("Cards to review and your streak.")
    .supportedFamilies([.systemSmall])
  }

  /// Read on every render; the app reloads timelines when it goes to the background, so theme changes show up.
  private var storedTheme: AppTheme {
    AppGroup.defaults.string(forKey: AppTheme.storageKey).flatMap(AppTheme.init(rawValue:)) ?? .system
  }
}

#Preview("due", as: .systemSmall) {
  DeckWidget()
} timeline: {
  DeckWidgetEntry.sample
}

#Preview("caught up", as: .systemSmall) {
  DeckWidget()
} timeline: {
  DeckWidgetEntry.gallery[1].entry
  DeckWidgetEntry.gallery[2].entry
}

#Preview("empty, unavailable, long", as: .systemSmall) {
  DeckWidget()
} timeline: {
  DeckWidgetEntry.gallery[3].entry
  DeckWidgetEntry.gallery[4].entry
  DeckWidgetEntry.gallery[5].entry
}
