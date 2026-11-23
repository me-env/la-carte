import APIClient
import Foundation

/// The widget's 4 × 7 history (spec 024): 28 marks ending today, as days, then weeks, months and years going back far
/// enough to reach the current run's first day. Pure display maths over `/stats`; "today" is the history's last day.
struct StreakGrid: Equatable {
  enum Unit: Int, Comparable {
    case day, week, month, year

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  enum Status: Equatable {
    case run, older, missed, frozenRun, frozenOlder, todayPending, todayStudied
  }

  struct Mark: Equatable {
    var unit: Unit
    var status: Status
    /// The period's first and last local midnights.
    var period: ClosedRange<Date>
  }

  struct Counts: Equatable {
    var days: Int, weeks: Int, months: Int, years: Int
  }

  static let size = 28

  /// Oldest first: years, months, weeks, days; the last one is today.
  let marks: [Mark]
  let counts: Counts

  init(stats: DeckStats, calendar: Calendar) {
    let letters = Array(stats.history.isEmpty ? "p" : stats.history)
    let start = calendar.startOfDay(for: stats.historyStart)
    func date(_ index: Int) -> Date { calendar.date(byAdding: .day, value: index, to: start) ?? start }
    func index(_ date: Date) -> Int { calendar.dateComponents([.day], from: start, to: date).day ?? 0 }

    let today = letters.count - 1
    let runStart = stats.streakStart.map { index(calendar.startOfDay(for: $0)) }
    let counts = Self.counts(reaching: date(runStart ?? today), today: date(today), calendar: calendar)
    let history = History(letters: letters, runStart: runStart)

    // Each period's first day (a day index), oldest first; a period ends the day before the next one starts.
    let firstDay = today - counts.days + 1
    let firstWeek = firstDay - 7 * counts.weeks
    let monthAnchor = date(firstWeek)
    let firstMonth = index(calendar.date(byAdding: .month, value: -counts.months, to: monthAnchor) ?? monthAnchor)
    let yearAnchor = date(firstMonth)
    var starts: [(Unit, Int)] = (0..<counts.years).reversed().map { n in
      (.year, index(calendar.date(byAdding: .year, value: -(n + 1), to: yearAnchor) ?? yearAnchor))
    }
    starts += (0..<counts.months).reversed().map { n in
      (.month, index(calendar.date(byAdding: .month, value: -(n + 1), to: monthAnchor) ?? monthAnchor))
    }
    starts += (0..<counts.weeks).map { n in (.week, firstWeek + 7 * n) }
    starts += (firstDay...today).map { (.day, $0) }

    marks = starts.enumerated().map { i, start in
      let (unit, first) = start
      let last = i + 1 < starts.count ? starts[i + 1].1 - 1 : today
      let status = unit == .day ? history.dayStatus(first, isToday: first == today) : history.periodStatus(first...last)
      return Mark(unit: unit, status: status, period: date(first)...date(last))
    }
    self.counts = counts
  }

  /// The finest level (days; + weeks; + months; + years) whose 28 marks reach `runStart`, with at least a row of days;
  /// within it the most days, then weeks, then months (spec 024 "Choosing D, W, Mo, Y").
  private static func counts(reaching runStart: Date, today: Date, calendar: Calendar) -> Counts {
    func back(_ unit: Calendar.Component, _ n: Int, from date: Date) -> Date {
      calendar.date(byAdding: unit, value: -n, to: date) ?? date
    }
    for level in 0..<4 {
      for days in stride(from: size, through: 7, by: -1) {
        for weeks in level >= 1 ? Array((0...(size - days)).reversed()) : [0] {
          for months in level >= 2 ? Array((0...(size - days - weeks)).reversed()) : [0] {
            let years = size - days - weeks - months
            if years > 0 && level < 3 { continue }
            let firstDay = back(.day, days - 1, from: today)
            let firstYear = back(.year, years, from: back(.month, months, from: back(.day, 7 * weeks, from: firstDay)))
            if firstYear <= runStart {
              return Counts(days: days, weeks: weeks, months: months, years: years)
            }
          }
        }
      }
    }
    return Counts(days: 7, weeks: 0, months: 0, years: size - 7)
  }

  /// The history letters by day index (0 = `historyStart`); days before it read as missed, unknown letters too.
  private struct History {
    let letters: [Character]
    let runStart: Int?

    func isDone(_ index: Int) -> Bool {
      letters.indices.contains(index) && (letters[index] == "s" || letters[index] == "f")
    }

    func inRun(_ index: Int) -> Bool {
      runStart.map { index >= $0 } ?? false
    }

    func dayStatus(_ index: Int, isToday: Bool) -> Status {
      if isToday { return letters[index] == "s" ? .todayStudied : .todayPending }
      switch letters.indices.contains(index) ? letters[index] : "m" {
      case "s": return inRun(index) ? .run : .older
      case "f": return inRun(index) ? .frozenRun : .frozenOlder
      default: return .missed
      }
    }

    /// `run` if at least half its days are in the run, else `older` if at least half were studied or frozen.
    func periodStatus(_ days: ClosedRange<Int>) -> Status {
      if 2 * days.count(where: inRun) >= days.count { return .run }
      if 2 * days.count(where: isDone) >= days.count { return .older }
      return .missed
    }
  }
}
