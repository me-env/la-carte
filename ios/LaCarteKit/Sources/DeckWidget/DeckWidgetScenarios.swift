import APIClient
import Foundation

extension DeckWidgetEntry {
  /// Spec 024's scenarios, today = Sun 2026-11-22: the one fixture set for the gallery, the renders and the tests.
  /// Days are `yyyy-MM-dd` strings, so ranges read as in the spec's table; every day not listed is missed.
  static func scenarios(calendar: Calendar) -> [(id: String, entry: DeckWidgetEntry)] {
    func day(_ string: String, hour: Int = 0, minute: Int = 0) -> Date {
      let parts = string.split(separator: "-").compactMap { Int($0) }
      return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour, minute: minute))!
    }
    let today = "2026-11-22"
    let now = day(today, hour: 12)
    let evening = day(today, hour: 18, minute: 40)

    func entry(
      _ studied: [ClosedRange<String>],
      frozen: [String] = [],
      streak: Int,
      streakStart: String?,
      total: Int = 42,
      due: Int = 0,
      dueNew: Int = 0,
      newToday: Int = 0,
      nextDue: Date? = nil
    ) -> DeckWidgetEntry {
      let historyStart = studied.first.map { day($0.lowerBound) } ?? day(today)
      var history = ""
      var date = historyStart
      while true {
        let key = Self.dayString(date, calendar: calendar)
        history.append(
          frozen.contains(key) ? "f" : studied.contains { $0.contains(key) } ? "s" : key == today ? "p" : "m"
        )
        if key == today { break }
        date = calendar.date(byAdding: .day, value: 1, to: date)!
      }
      let stats = DeckStats(
        total: total, due: due, new: dueNew, reviewedToday: history.last == "s" ? 5 : 0, nextDue: nextDue,
        streak: streak, newToday: newToday, dueNew: dueNew, history: history, historyStart: historyStart,
        streakStart: streakStart.map { day($0) }
      )
      return DeckWidgetEntry(date: now, content: .stats(stats))
    }

    return [
      ("zero", entry([], streak: 0, streakStart: nil, total: 0)),
      ("three", entry(["2026-11-20"..."2026-11-22"], streak: 3, streakStart: "2026-11-20", nextDue: evening)),
      ("nine", entry(["2026-11-13"..."2026-11-21"], streak: 9, streakStart: "2026-11-13", due: 8)),
      (
        "freezes",
        entry(
          ["2026-10-26"..."2026-10-26", "2026-10-29"..."2026-11-22"], frozen: ["2026-11-05", "2026-11-16"],
          streak: 25, streakStart: "2026-10-29", nextDue: day("2026-11-24", hour: 9)
        )
      ),
      (
        "broken",
        entry(
          ["2026-11-08"..."2026-11-17", "2026-11-20"..."2026-11-22"], streak: 3, streakStart: "2026-11-20",
          nextDue: evening
        )
      ),
      (
        "lone",
        entry(
          ["2026-10-30"..."2026-11-14", "2026-11-17"..."2026-11-17", "2026-11-20"..."2026-11-22"], streak: 3,
          streakStart: "2026-11-20", nextDue: evening
        )
      ),
      ("sixty", entry(["2026-09-01"..."2026-09-21", "2026-09-24"..."2026-11-22"], streak: 60, streakStart: "2026-09-24", due: 3)),
      (
        "sixtyFrozen",
        entry(
          ["2026-09-01"..."2026-09-21", "2026-09-24"..."2026-11-22"], frozen: ["2026-11-20"], streak: 60,
          streakStart: "2026-09-24", due: 3
        )
      ),
      (
        "twoHundred",
        entry(["2026-03-01"..."2026-05-03", "2026-05-06"..."2026-11-21"], streak: 200, streakStart: "2026-05-06", due: 12)
      ),
      (
        "eightHundred",
        // 4 reviews + min(60 new, 1 left in today's batch of 15) = 5, as Study counts (decision 9).
        entry(
          ["2024-06-01"..."2024-09-10", "2024-09-13"..."2026-11-21"], streak: 800, streakStart: "2024-09-13",
          due: 64, dueNew: 60, newToday: 14
        )
      ),
    ]
  }

  private static func dayString(_ date: Date, calendar: Calendar) -> String {
    let day = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", day.year!, day.month!, day.day!)
  }
}
