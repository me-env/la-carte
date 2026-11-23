import APIClient
import Foundation
import Testing

@testable import DeckWidget

/// Spec 024 #10-#13: which periods the grid shows and how each mark reads, in Paris.
struct StreakGridTests {
  let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    return calendar
  }()

  func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day))!
  }

  func add(_ days: Int, to date: Date) -> Date {
    calendar.date(byAdding: .day, value: days, to: date)!
  }

  /// Stats whose history ends on `today`; the run starts at `streakStart`.
  func stats(_ history: String, today: Date, streakStart: Date?) -> DeckStats {
    DeckStats(
      total: 1, due: 0, new: 0, reviewedToday: 0, nextDue: nil, history: history,
      historyStart: add(-(history.count - 1), to: today), streakStart: streakStart
    )
  }

  /// A run of `days` days studied, today included.
  func run(_ days: Int, today: Date) -> StreakGrid {
    StreakGrid(stats: stats(String(repeating: "s", count: days), today: today, streakStart: add(-(days - 1), to: today)),
               calendar: calendar)
  }

  /// The spec's notation: `W`/`M`/`Y` prefix, then `#` run, `+` older, `.` missed, `o` frozen in the run, `x` frozen
  /// before it, `T` today studied, `P` today pending; rows of 7 separated by ` / `.
  static func notation(_ grid: StreakGrid) -> String {
    let marks = grid.marks.map { mark in
      let unit = ["", "W", "M", "Y"][mark.unit.rawValue]
      let status = switch mark.status {
      case .run: "#"
      case .older: "+"
      case .missed: "."
      case .frozenRun: "o"
      case .frozenOlder: "x"
      case .todayPending: "P"
      case .todayStudied: "T"
      }
      return unit + status
    }
    return stride(from: 0, to: marks.count, by: 7).map { marks[$0..<min($0 + 7, marks.count)].joined(separator: " ") }
      .joined(separator: " / ")
  }

  // MARK: Scenarios (#10)

  static let expected: [String: (counts: StreakGrid.Counts, grid: String)] = [
    "zero": (.init(days: 28, weeks: 0, months: 0, years: 0),
             ". . . . . . . / . . . . . . . / . . . . . . . / . . . . . . P"),
    "three": (.init(days: 28, weeks: 0, months: 0, years: 0),
              ". . . . . . . / . . . . . . . / . . . . . . . / . . . . # # T"),
    "nine": (.init(days: 28, weeks: 0, months: 0, years: 0),
             ". . . . . . . / . . . . . . . / . . . . # # # / # # # # # # P"),
    "freezes": (.init(days: 28, weeks: 0, months: 0, years: 0),
                "+ . . # # # # / # # # o # # # / # # # # # # # / o # # # # # T"),
    "broken": (.init(days: 28, weeks: 0, months: 0, years: 0),
               ". . . . . . . / . . . . . . + / + + + + + + + / + + . . # # T"),
    "lone": (.init(days: 28, weeks: 0, months: 0, years: 0),
             ". . . . + + + / + + + + + + + / + + + + + + . / . + . . # # T"),
    "sixty": (.init(days: 22, weeks: 6, months: 0, years: 0),
              "W+ W# W# W# W# W# # / # # # # # # # / # # # # # # # / # # # # # # T"),
    "sixtyFrozen": (.init(days: 22, weeks: 6, months: 0, years: 0),
                    "W+ W# W# W# W# W# # / # # # # # # # / # # # # # # # / # # # # o # T"),
    "twoHundred": (.init(days: 22, weeks: 0, months: 6, years: 0),
                   "M# M# M# M# M# M# # / # # # # # # # / # # # # # # # / # # # # # # P"),
    "eightHundred": (.init(days: 25, weeks: 0, months: 0, years: 3),
                     "Y. Y# Y# # # # # / # # # # # # # / # # # # # # # / # # # # # # P"),
  ]

  @Test(arguments: expected.keys.sorted())
  func scenario(_ id: String) throws {
    let expected = try #require(Self.expected[id])
    let grid = try self.grid(id)
    #expect(grid.counts == expected.counts)
    #expect(Self.notation(grid) == expected.grid)
  }

  struct NoStats: Error { let id: String }

  /// The grid of the scenario fixture `id`.
  func grid(_ id: String) throws -> StreakGrid {
    let content = DeckWidgetEntry.scenarios(calendar: calendar).first { $0.id == id }?.entry.content
    guard case let .stats(stats) = content else { throw NoStats(id: id) }
    return StreakGrid(stats: stats, calendar: calendar)
  }

  @Test func scenarioPeriods() throws {
    #expect(try grid("sixty").marks[0].period == day(2026, 9, 20)...day(2026, 9, 26))
    #expect(try grid("twoHundred").marks[0].period == day(2026, 5, 1)...day(2026, 5, 31))
    #expect(try grid("eightHundred").marks[0].period == day(2023, 10, 29)...day(2024, 10, 28))
  }

  // MARK: Levels and calendar maths (#11)

  @Test func levelThresholds() {
    let today = day(2026, 11, 22)
    #expect(run(28, today: today).counts == .init(days: 28, weeks: 0, months: 0, years: 0))
    #expect(run(29, today: today).counts == .init(days: 27, weeks: 1, months: 0, years: 0))
    #expect(run(154, today: today).counts == .init(days: 7, weeks: 21, months: 0, years: 0))
    #expect(run(155, today: today).counts.months > 0)
    #expect(run(155, today: today).counts.years == 0)

    let monthsEdge = calendar.date(byAdding: .month, value: -21, to: add(-6, to: today))!
    let days = calendar.dateComponents([.day], from: monthsEdge, to: today).day! + 1
    #expect(run(days, today: today).counts == .init(days: 7, weeks: 0, months: 21, years: 0))
    #expect(run(days + 1, today: today).counts.years > 0)
  }

  /// Month blocks count back from the first week (here the first day, 2028-03-31) with Foundation's clamping: across
  /// Feb 29 2028 and the 30-day months.
  @Test func monthsCountBackAcrossMonthEnds() {
    let today = day(2028, 4, 6)
    let start = day(2026, 6, 30)
    let days = calendar.dateComponents([.day], from: start, to: today).day! + 1
    let grid = run(days, today: today)
    #expect(grid.counts == .init(days: 7, weeks: 0, months: 21, years: 0))
    #expect(grid.marks[20].period == day(2028, 2, 29)...day(2028, 3, 30))
    #expect(grid.marks[19].period == day(2028, 1, 31)...day(2028, 2, 28))
    #expect(grid.marks[17].period == day(2027, 11, 30)...day(2027, 12, 30))
    #expect(grid.marks[0].period.lowerBound == start)
    #expect(grid.marks[21].period == day(2028, 3, 31)...day(2028, 3, 31))
  }

  /// Paris leaves summer time on 2026-10-25: the 25-hour day is still one day mark, and weeks stay 7 days.
  @Test func daysAndWeeksAcrossTheDSTChange() {
    let grid = run(40, today: day(2026, 11, 5))
    #expect(grid.counts == .init(days: 26, weeks: 2, months: 0, years: 0))
    expectContiguous(grid)
    #expect(grid.marks.contains { $0.unit == .day && $0.period.lowerBound == day(2026, 10, 25) })
    #expect(grid.marks[0].period == day(2026, 9, 27)...day(2026, 10, 3))
  }

  // MARK: Invariants (#12)

  @Test func invariantsOverRandomHistories() {
    var random = SplitMix64(seed: 24)
    var levels = Set<Int>()
    for _ in 0..<60 {
      var history = ""
      let length = Int.random(in: 1...1_500, using: &random)
      while history.count < length - 1 {
        let studied = Int.random(in: 1...400, using: &random)
        history += String(repeating: "s", count: studied)
        history += Bool.random(using: &random) ? "f" : String(repeating: "m", count: Int.random(in: 1...6, using: &random))
      }
      history = String(history.prefix(length - 1)) + (Bool.random(using: &random) ? "s" : "p")
      let letters = Array(history)
      var first = letters.count - (letters.last == "s" ? 1 : 2)
      while first >= 0, letters[first] == "s" || letters[first] == "f" { first -= 1 }
      let runLength = letters.count - (letters.last == "s" ? 0 : 1) - (first + 1)
      let today = day(2026, 11, 22)
      let streakStart = runLength > 0 ? add(first + 1 - (letters.count - 1), to: today) : nil
      let grid = StreakGrid(stats: stats(history, today: today, streakStart: streakStart), calendar: calendar)

      #expect(grid.marks.count == 28)
      #expect(zip(grid.marks, grid.marks.dropFirst()).allSatisfy { $0.unit >= $1.unit })
      #expect(grid.counts.days >= 7)
      #expect(grid.counts.days + grid.counts.weeks + grid.counts.months + grid.counts.years == 28)
      #expect(grid.marks.count { $0.unit == .day } == grid.counts.days)
      #expect(grid.marks.last?.period == today...today)
      #expect([StreakGrid.Status.todayStudied, .todayPending].contains(grid.marks[27].status))
      #expect(grid.marks[0].period.lowerBound <= streakStart ?? today)
      expectContiguous(grid)
      levels.insert(grid.counts.years > 0 ? 3 : grid.counts.months > 0 ? 2 : grid.counts.weeks > 0 ? 1 : 0)
    }
    #expect(levels == [0, 1, 2, 3], "the histories cover every level")
  }

  func expectContiguous(_ grid: StreakGrid, sourceLocation: SourceLocation = #_sourceLocation) {
    for (older, newer) in zip(grid.marks, grid.marks.dropFirst()) {
      #expect(newer.period.lowerBound == add(1, to: older.period.upperBound), sourceLocation: sourceLocation)
    }
    for mark in grid.marks {
      #expect(calendar.component(.hour, from: mark.period.lowerBound) == 0, sourceLocation: sourceLocation)
    }
  }

  // MARK: Today and history letters (#13, #8)

  /// No clock goes in: a cached `/stats` shows the grid of the day it was fetched, today being its last letter.
  @Test func todayIsTheHistorysLastDay() {
    let grid = StreakGrid(stats: stats("ssp", today: day(2026, 11, 22), streakStart: day(2026, 11, 20)),
                          calendar: calendar)
    #expect(grid.marks.last == .init(unit: .day, status: .todayPending, period: day(2026, 11, 22)...day(2026, 11, 22)))
    #expect(Self.notation(grid).hasSuffix("# # P"))
  }

  @Test func unknownLettersReadAsMissed() {
    let grid = StreakGrid(stats: stats("sxs", today: day(2026, 11, 22), streakStart: day(2026, 11, 22)),
                          calendar: calendar)
    #expect(Self.notation(grid).hasSuffix(". . + . T"))
  }
}

/// A seeded generator, so the random histories are the same on every run.
struct SplitMix64: RandomNumberGenerator {
  var state: UInt64
  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
