import APIClient
import Foundation
import WidgetKit

/// What the widget shows at `date`: the deck's stats, or that the deck can't be reached (spec 007).
struct DeckWidgetEntry: TimelineEntry, Equatable, Sendable {
  var date: Date
  var content: Content

  enum Content: Equatable, Sendable {
    case stats(DeckStats)
    case unavailable

    /// A failed fetch falls back to the last stats the widget saw, so a flaky network doesn't blank it.
    static func make(result: Result<DeckStats, any Error>, cached: DeckStats?) -> Self {
      switch result {
      case let .success(stats): .stats(stats)
      case .failure: cached.map(Self.stats) ?? .unavailable
      }
    }
  }

  /// Placeholder and widget-gallery preview: no network.
  static let sample = DeckWidgetEntry(
    date: .now,
    content: .stats(DeckStats(total: 42, due: 8, new: 3, reviewedToday: 5, nextDue: nil, streak: 12))
  )

  /// When WidgetKit should fetch again: in 30 min at most, at the next local midnight (the streak may end), and when
  /// the next card comes due if nothing is due now.
  static func nextRefresh(stats: DeckStats?, now: Date, calendar: Calendar) -> Date {
    var dates = [now.addingTimeInterval(30 * 60)]
    if let midnight = calendar.nextDate(
      after: now, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime
    ) {
      dates.append(midnight)
    }
    if let stats, stats.due == 0, let nextDue = stats.nextDue, nextDue > now {
      dates.append(nextDue)
    }
    return dates.min() ?? now
  }

  /// "12-day streak" / "No streak yet".
  static func streakText(_ streak: Int) -> String {
    streak >= 1 ? "\(streak)-day streak" : "No streak yet"
  }

  /// "Next at 18:40" within 24 h, else "Next on 24 Nov" (localized).
  static func nextDueText(_ nextDue: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
    if nextDue.timeIntervalSince(now) < 24 * 60 * 60 {
      let time = Date.FormatStyle(
        date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone
      )
      return "Next at \(nextDue.formatted(time))"
    }
    let day = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
      .day().month(.abbreviated)
    return "Next on \(nextDue.formatted(day))"
  }
}
