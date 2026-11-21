import APIClient
import DesignSystem
import SwiftUI
import WidgetKit

/// The small widget's content: one strong line (due count or a short message), a quiet detail, the streak at the
/// bottom (spec 007). The background is drawn by the caller (`containerBackground` or a gallery tile).
public struct DeckWidgetView: View {
  let entry: DeckWidgetEntry
  @Environment(\.widgetRenderingMode) private var renderingMode
  @Environment(\.calendar) private var calendar
  @Environment(\.locale) private var locale

  public init(entry: DeckWidgetEntry) {
    self.entry = entry
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      switch entry.content {
      case let .stats(stats):
        hero(stats)
          .widgetAccentable()
        if let detail = detail(stats) {
          Text(detail)
            .font(.meta)
            .foregroundStyle(secondaryInk)
        }
        Spacer(minLength: Theme.Spacing.s)
        streak(stats.streak)
      case .unavailable:
        Text("Can't reach your deck")
          .font(.meta)
          .foregroundStyle(secondaryInk)
        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityText)
  }

  @ViewBuilder
  private func hero(_ stats: DeckStats) -> some View {
    if stats.total == 0 {
      message("No cards yet")
    } else if stats.due > 0 {
      Text(stats.due, format: .number)
        .font(.cardFace)
        .monospacedDigit()
        .foregroundStyle(ink)
    } else {
      message("All caught up")
    }
  }

  private func message(_ text: LocalizedStringKey) -> some View {
    Text(text)
      .font(.body.weight(.medium))
      .foregroundStyle(ink)
  }

  private func detail(_ stats: DeckStats) -> String? {
    if stats.total == 0 { return "Ask your agent to add some" }
    if stats.due > 0 { return "to review" }
    return stats.nextDue.map { DeckWidgetEntry.nextDueText($0, now: entry.date, calendar: calendar, locale: locale) }
  }

  /// Only the number is pink (the accent's widget slot); in tinted/clear Home Screens it is accentable instead.
  @ViewBuilder
  private func streak(_ streak: Int) -> some View {
    if streak < 1 {
      Text(DeckWidgetEntry.streakText(streak))
        .font(.meta)
        .foregroundStyle(secondaryInk)
    } else if isFullColor {
      Text("\(Text(streak, format: .number).foregroundStyle(Theme.accent))-day streak")
        .font(.meta)
        .foregroundStyle(ink)
    } else {
      HStack(spacing: 0) {
        Text(streak, format: .number).widgetAccentable()
        Text("-day streak")
      }
      .font(.meta)
    }
  }

  private var accessibilityText: String {
    guard case let .stats(stats) = entry.content else { return "Can't reach your deck" }
    var parts = [stats.total == 0 ? "No cards yet" : stats.due > 0 ? "\(stats.due) cards to review" : "All caught up"]
    if stats.total > 0, stats.due == 0, let detail = detail(stats) {
      parts.append(detail.localizedLowercase)
    }
    parts.append(DeckWidgetEntry.streakText(stats.streak))
    return parts.joined(separator: ", ")
  }

  /// Tinted and clear Home Screens re-color the widget; plain hierarchical styles stay readable there.
  private var isFullColor: Bool { renderingMode == .fullColor }
  private var ink: AnyShapeStyle { isFullColor ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(.primary) }
  private var secondaryInk: AnyShapeStyle {
    isFullColor ? AnyShapeStyle(Theme.secondaryInk) : AnyShapeStyle(.secondary)
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
