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
  static var sample: DeckWidgetEntry {
    scenarios(calendar: DeckStats.calendar)[2].entry  // "nine": 8 to review, today still to do
  }

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

  /// "12-day streak" / "Start a streak today".
  static func streakText(_ streak: Int) -> String {
    streak >= 1 ? "\(streak)-day streak" : "Start a streak today"
  }

  /// "N to review" / "All caught up" / "No cards yet", with Study's count (spec 024 decision 9).
  static func statusText(_ stats: DeckStats) -> String {
    if stats.total == 0 { return "No cards yet" }
    return stats.toReview > 0 ? "\(stats.toReview) to review" : "All caught up"
  }

  /// The widget is one VoiceOver element and the marks are decorative (spec 024): "9-day streak, today still to do,
  /// 8 to review".
  static func accessibilityText(stats: DeckStats) -> String {
    var parts = [streakText(stats.streak)]
    if stats.streak >= 1 {
      parts.append(stats.history.last == "s" ? "studied today" : "today still to do")
    }
    parts.append(statusText(stats).localizedLowercase)
    return parts.joined(separator: ", ")
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
