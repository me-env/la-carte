import APIClient
import DesignSystem
import Foundation
import SwiftUI
import Testing
import WidgetKit

@testable import DeckWidget

/// Marketing frames (owner: marketing, `docs/marketing/app-demo.md`): the real `DeckWidgetTile` for an unbroken
/// streak of 1…800 days, studied today, so `marketing/build-demo.py` can animate the grid growing (days, then weeks,
/// months and the year star). Off by default:
///
///   LA_CARTE_RENDER_DIR=<dir> scripts/ios-test.sh -only-testing:ScreenColorTests/StreakGrowthRenders
///
/// writes `streak-<small|medium>-<light|dark>-<NNNN>.png` (2×, the README scale).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LA_CARTE_RENDER_DIR"] != nil), .serialized)
struct StreakGrowthRenders {
  static let days = 800

  @Test func streakGrowth() throws {
    let dir = try #require(ProcessInfo.processInfo.environment["LA_CARTE_RENDER_DIR"]) + "/streak"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let calendar = DeckStats.calendar
    let runStart = try #require(calendar.date(from: DateComponents(year: 2025, month: 1, day: 6)))
    for n in 1...Self.days {
      let today = try #require(calendar.date(byAdding: .day, value: n - 1, to: runStart))
      let stats = DeckStats(
        total: 42, due: 0, new: 0, reviewedToday: 5,
        nextDue: calendar.date(byAdding: .day, value: 1, to: today)  // tomorrow 09:00: "Next at 9:00 AM", DST or not
          .flatMap { calendar.date(bySettingHour: 9, minute: 0, second: 0, of: $0) },
        streak: n, history: String(repeating: "s", count: n), historyStart: runStart, streakStart: runStart
      )
      let entry = DeckWidgetEntry(date: today.addingTimeInterval(12 * 3600), content: .stats(stats))
      for (name, family) in WidgetRenders.families {
        for theme in [AppTheme.light, .dark] {
          let renderer = ImageRenderer(content: DeckWidgetTile(entry: entry, family: family).widgetTheme(theme))
          renderer.scale = 2
          let png = try #require(renderer.uiImage?.pngData())
          try png.write(to: URL(fileURLWithPath: String(format: "%@/streak-%@-%@-%04d.png", dir, name, theme.rawValue, n)))
        }
      }
    }
  }
}
