import APIClient
import DesignSystem
import SwiftUI

/// Every widget state in systemSmall-sized tiles, under the app's theme, for QA screenshots (spec 007 #23).
/// Widgets aren't reachable from XCUITest; launch the app with `LA_CARTE_SCREEN=widget` (debug builds).
#if DEBUG
public struct DeckWidgetGallery: View {
  public init() {}

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.l) {
        Text("Widget")
          .font(.screenTitle)
          .foregroundStyle(Theme.ink)
          .accessibilityIdentifier("widgetGallery.title")

        LazyVGrid(columns: Array(repeating: GridItem(.fixed(170), spacing: Theme.Spacing.m), count: 2)) {
          ForEach(DeckWidgetEntry.gallery, id: \.state) { tile in
            VStack(spacing: Theme.Spacing.s) {
              DeckWidgetView(entry: tile.entry)
                .padding(Theme.Spacing.m)
                .frame(width: 170, height: 170)
                .background(Theme.background, in: .rect(cornerRadius: 22))
                .accessibilityIdentifier("widgetGallery.tile.\(tile.state)")
              Text(tile.name)
                .font(.meta)
                .foregroundStyle(Theme.secondaryInk)
            }
            .padding(.bottom, Theme.Spacing.s)
          }
        }
      }
      .padding(.horizontal, Theme.Spacing.m)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Theme.surface)  // the "wallpaper", so the background-colored tiles stand out
  }
}
#endif

extension DeckWidgetEntry {
  /// Fixed entries, one per state (gallery and widget previews); "today" times use the current day so "Next at 18:40" reads naturally.
  static var gallery: [(state: String, name: String, entry: DeckWidgetEntry)] {
    let now = Date.now
    let calendar = Calendar.current
    let evening = calendar.date(bySettingHour: 18, minute: 40, second: 0, of: now) ?? now
    func stats(total: Int = 42, due: Int, nextDue: Date? = nil, streak: Int) -> Content {
      .stats(DeckStats(total: total, due: due, new: 0, reviewedToday: 0, nextDue: nextDue, streak: streak))
    }
    return [
      ("due", "due", .init(date: now, content: stats(due: 8, streak: 12))),
      ("caughtUp", "caught up", .init(date: now, content: stats(due: 0, nextDue: evening, streak: 3))),
      (
        "caughtUpLater", "caught up later",
        .init(date: now, content: stats(due: 0, nextDue: now.addingTimeInterval(3 * 86_400), streak: 0))
      ),
      ("empty", "empty deck", .init(date: now, content: stats(total: 0, due: 0, streak: 0))),
      ("unavailable", "unavailable", .init(date: now, content: .unavailable)),
      ("long", "long", .init(date: now, content: stats(total: 1_200, due: 999, streak: 365))),
    ]
  }
}
