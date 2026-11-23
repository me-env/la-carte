import APIClient
import DesignSystem
import Foundation
import SwiftUI
import Testing
import WidgetKit

@testable import DeckWidget

/// The real `DeckWidgetView` drawn to PNGs for every spec 024 scenario, for design reviews and the QA report (#16).
/// Off by default; `scripts/ios-test.sh --render -only-testing:ScreenColorTests/WidgetRenders` writes
/// `widget-<small|medium>-<id>-<light|dark|forest|accented>.png` (170 × 170 / 364 × 170 pt at 3×, as on the Home
/// Screen). Plain SwiftUI, so `ImageRenderer` draws it; `accented` stands in for a tinted Home Screen (`.primary`
/// inks, the system's tint isn't applied outside WidgetKit).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LA_CARTE_RENDER_DIR"] != nil), .serialized)
struct WidgetRenders {
  static let families: [(name: String, family: WidgetFamily)] = [("small", .systemSmall), ("medium", .systemMedium)]

  @Test func widgets() throws {
    let dir = try #require(ProcessInfo.processInfo.environment["LA_CARTE_RENDER_DIR"])
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let scenarios = DeckWidgetEntry.scenarios(calendar: DeckStats.calendar)
      + [("unavailable", DeckWidgetEntry(date: .now, content: .unavailable))]
    var count = 0
    for (name, family) in Self.families {
      for (id, entry) in scenarios {
        for theme in [AppTheme.light, .dark, .forest] {
          try write(DeckWidgetTile(entry: entry, family: family).widgetTheme(theme),
                    to: "\(dir)/widget-\(name)-\(id)-\(theme.rawValue).png")
          count += 1
        }
      }
      let nine = try #require(scenarios.first { $0.id == "nine" }?.entry)
      try write(DeckWidgetTile(entry: nine, family: family).widgetTheme(.dark)
                  .environment(\.widgetRenderingMode, .accented),
                to: "\(dir)/widget-\(name)-nine-accented.png")
      count += 1
    }
    print("WidgetRenders: \(count) PNGs in \(dir)")
  }

  private func write(_ view: some View, to path: String) throws {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 3
    let png = try #require(renderer.uiImage?.pngData())
    try png.write(to: URL(fileURLWithPath: path))
  }
}
