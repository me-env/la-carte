import APIClient
import DesignSystem
import SwiftUI
import WidgetKit

/// The widget's content (spec 024): the streak as a 4 × 7 history grid with its label, under the cards to review
/// (small) or beside them (medium). The background is drawn by the caller (`containerBackground` or a gallery tile).
struct DeckWidgetView: View {
  let entry: DeckWidgetEntry
  /// Passed in: `\.widgetFamily` can't be set outside WidgetKit, and the gallery and the renders draw both.
  let family: WidgetFamily
  @Environment(\.widgetRenderingMode) private var renderingMode
  @Environment(\.calendar) private var calendar
  @Environment(\.locale) private var locale

  var body: some View {
    Group {
      switch entry.content {
      case let .stats(stats):
        if family == .systemMedium {
          medium(stats)
        } else {
          small(stats)
        }
      case .unavailable:
        Text("Can't reach your deck")
          .font(.meta)
          .foregroundStyle(renderingMode.secondaryInk)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .minimumScaleFactor(0.6)
    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityText)
  }

  private func small(_ stats: DeckStats) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(DeckWidgetEntry.statusText(stats))
        .font(.body.weight(.medium))
        .foregroundStyle(renderingMode.ink)
        .lineLimit(1)
      Spacer(minLength: Theme.Spacing.s)
      streak(stats)
        .layoutPriority(1)  // else the spacer wins and the label shrinks to its minimum scale
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }

  /// 007's small widget on the left, the grid on the right, both on the label's baseline.
  private func medium(_ stats: DeckStats) -> some View {
    HStack(alignment: .lastTextBaseline, spacing: Theme.Spacing.m) {
      VStack(alignment: .leading, spacing: 0) {
        hero(stats)
        if let detail = detail(stats) {
          Text(detail)
            .font(.meta)
            .foregroundStyle(renderingMode.secondaryInk)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      streak(stats)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
  }

  private func streak(_ stats: DeckStats) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
      StreakGridView(grid: StreakGrid(stats: stats, calendar: DeckStats.calendar))
      Text(DeckWidgetEntry.streakText(stats.streak))
        .font(.meta.weight(stats.streak >= 1 ? .semibold : .regular))
        .foregroundStyle(stats.streak >= 1 ? renderingMode.ink : renderingMode.secondaryInk)
        .lineLimit(1)
    }
  }

  @ViewBuilder
  private func hero(_ stats: DeckStats) -> some View {
    if stats.total > 0, stats.toReview > 0 {
      Text(stats.toReview, format: .number)
        .font(.cardFace)
        .monospacedDigit()
        .foregroundStyle(renderingMode.ink)
    } else {
      Text(DeckWidgetEntry.statusText(stats))
        .font(.body.weight(.medium))
        .foregroundStyle(renderingMode.ink)
    }
  }

  private func detail(_ stats: DeckStats) -> String? {
    if stats.total == 0 { return "Ask your agent to add some" }
    if stats.toReview > 0 { return "to review" }
    return stats.nextDue.map { DeckWidgetEntry.nextDueText($0, now: entry.date, calendar: calendar, locale: locale) }
  }

  private var accessibilityText: String {
    guard case let .stats(stats) = entry.content else { return "Can't reach your deck" }
    return DeckWidgetEntry.accessibilityText(stats: stats)
  }
}

extension View {
  /// Applies the app's theme inside a widget, where there is no window to style: System follows the Home Screen,
  /// Light/Dark force the scheme, Forest forces dark with the forest palette. Place it outside `containerBackground`.
  func widgetTheme(_ theme: AppTheme) -> some View {
    environment(\.appTheme, theme)
      .transformEnvironment(\.colorScheme) { scheme in
        switch theme {
        case .system: break
        case .light: scheme = .light
        case .dark, .forest: scheme = .dark
        }
      }
  }
}

#Preview("small", traits: .fixedLayout(width: 170, height: 170)) {
  DeckWidgetTile(entry: DeckWidgetEntry.sample, family: .systemSmall)
}

#Preview("medium", traits: .fixedLayout(width: 364, height: 170)) {
  DeckWidgetTile(entry: DeckWidgetEntry.sample, family: .systemMedium)
}
