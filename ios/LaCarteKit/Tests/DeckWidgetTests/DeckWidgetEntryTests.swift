import APIClient
import Foundation
import Testing

@testable import DeckWidget

/// Spec 007 #16-#21: what the widget shows and when it refreshes, with a fixed clock, zone and locale.
struct DeckWidgetEntryTests {
  struct Offline: Error {}

  let stats = DeckStats(total: 42, due: 8, new: 3, reviewedToday: 5, nextDue: nil, streak: 12)
  let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    return calendar
  }()
  let locale = Locale(identifier: "en_GB")
  /// 2026-11-21 10:00 in Paris.
  let now = Date(timeIntervalSince1970: 1_795_251_600)

  // MARK: Content (#20)

  @Test func aSuccessfulFetchShowsItsStats() {
    let cached = DeckStats(total: 1, due: 0, new: 0, reviewedToday: 0, nextDue: nil)
    #expect(DeckWidgetEntry.Content.make(result: .success(stats), cached: cached) == .stats(stats))
  }

  @Test func aFailedFetchShowsTheCachedStatsUnchanged() {
    #expect(DeckWidgetEntry.Content.make(result: .failure(Offline()), cached: stats) == .stats(stats))
  }

  @Test func aFailedFetchWithoutCacheIsUnavailable() {
    #expect(DeckWidgetEntry.Content.make(result: .failure(Offline()), cached: nil) == .unavailable)
  }

  // MARK: Refresh (#21)

  @Test func refreshesWithinHalfAnHourWhenCardsAreDue() {
    #expect(DeckWidgetEntry.nextRefresh(stats: stats, now: now, calendar: calendar) == now + 30 * 60)
  }

  @Test func refreshesAtLocalMidnightWhenItComesFirst() {
    let lateEvening = now + 13 * 3600 + 45 * 60  // 23:45 Paris
    let midnight = now + 14 * 3600  // 00:00 Paris, the 22nd
    #expect(DeckWidgetEntry.nextRefresh(stats: stats, now: lateEvening, calendar: calendar) == midnight)
  }

  @Test func refreshesWhenTheNextCardComesDueIfNothingIsDue() {
    var caughtUp = stats
    caughtUp.due = 0
    caughtUp.nextDue = now + 600
    #expect(DeckWidgetEntry.nextRefresh(stats: caughtUp, now: now, calendar: calendar) == now + 600)

    caughtUp.nextDue = now + 3 * 3600
    #expect(DeckWidgetEntry.nextRefresh(stats: caughtUp, now: now, calendar: calendar) == now + 30 * 60)
  }

  @Test func nextDueIsIgnoredWhileCardsAreDueOrWhenUnavailable() {
    var due = stats
    due.nextDue = now + 600
    #expect(DeckWidgetEntry.nextRefresh(stats: due, now: now, calendar: calendar) == now + 30 * 60)
    #expect(DeckWidgetEntry.nextRefresh(stats: nil, now: now, calendar: calendar) == now + 30 * 60)
  }

  // MARK: Text (#17, #19)

  @Test func streakText() {
    #expect(DeckWidgetEntry.streakText(12) == "12-day streak")
    #expect(DeckWidgetEntry.streakText(1) == "1-day streak")
    #expect(DeckWidgetEntry.streakText(0) == "Start a streak today")
  }

  /// Spec 024 #18.
  @Test func accessibilityText() throws {
    let scenarios = Dictionary(uniqueKeysWithValues: DeckWidgetEntry.scenarios(calendar: calendar).map {
      ($0.id, $0.entry.content)
    })
    func text(_ id: String) throws -> String {
      guard case let .stats(stats) = scenarios[id] else { throw Offline() }
      return DeckWidgetEntry.accessibilityText(stats: stats)
    }
    #expect(try text("zero") == "Start a streak today, no cards yet")
    #expect(try text("nine") == "9-day streak, today still to do, 8 to review")
    #expect(try text("three") == "3-day streak, studied today, all caught up")
    #expect(try text("eightHundred") == "800-day streak, today still to do, 5 to review")
  }

  @Test func statusTextUsesStudysCount() {
    var stats = stats
    #expect(DeckWidgetEntry.statusText(stats) == "8 to review")
    stats.dueNew = 8
    stats.newToday = 14
    #expect(DeckWidgetEntry.statusText(stats) == "1 to review")
    stats.due = 0
    stats.dueNew = 0
    #expect(DeckWidgetEntry.statusText(stats) == "All caught up")
    stats.total = 0
    #expect(DeckWidgetEntry.statusText(stats) == "No cards yet")
  }

  @Test func nextDueWithinADayShowsTheTime() {
    let evening = now + 8 * 3600 + 40 * 60  // 18:40 Paris
    #expect(DeckWidgetEntry.nextDueText(evening, now: now, calendar: calendar, locale: locale) == "Next at 18:40")
  }

  @Test func nextDueLaterShowsTheDay() {
    let later = now + 3 * 86_400
    #expect(DeckWidgetEntry.nextDueText(later, now: now, calendar: calendar, locale: locale) == "Next on 24 Nov")
  }
}
