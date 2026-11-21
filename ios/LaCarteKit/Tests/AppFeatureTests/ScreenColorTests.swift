import APIClient
import ComposableArchitecture
import CoreGraphics
import SwiftUI
import Testing

@testable import CardEditorFeature
@testable import DeckFeature
@testable import DesignSystem
@testable import SettingsFeature
@testable import StudyFeature

/// Screens rendered with `ImageRenderer` per theme × scheme, checked against the colour tokens. These replace the
/// UI suite's per-appearance colour passes (tooling proposal P8 / P4).
///
/// `ImageRenderer` draws ScrollView content empty and a List or TextField as a placeholder, so what lives inside
/// them (card text, deck rows, Settings fields and theme picker, editor fields) and anything the device draws
/// (status bar, keyboard, sheets, refresh spinner, swipe actions) stays checked in the UI tests.
@MainActor
struct ScreenColorTests {
  /// Light, dark, System on a dark device, Forest.
  nonisolated static let looks: [Look] = [
    Look(theme: .light, scheme: .light, palette: .light),
    Look(theme: .dark, scheme: .dark, palette: .dark),
    Look(theme: .system, scheme: .dark, palette: .dark),
    Look(theme: .forest, scheme: .dark, palette: .forest),
  ]

  @Test(arguments: looks)
  func studyFront(_ look: Look) throws {
    var state = StudyFeature.State()
    state.cards = IdentifiedArray(uniqueElements: [Card].fixtures)
    state.phase = .studying
    let screen = try Screen(StudyView(store: Store(initialState: state) { EmptyReducer() }), look)

    screen.expectBackgroundEdges()
    // Top bar: `study.deck` and `study.add` circles, "3 to review" between them.
    screen.expect(at: CGPoint(x: 16 + 7, y: 22), screen.palette.surface, "study.deck circle fill")
    screen.expect(at: CGPoint(x: 402 - 16 - 7, y: 22), screen.palette.surface, "study.add circle fill")
    screen.expectText(in: CGRect(x: 100, y: 0, width: 202, height: 44), screen.palette.secondaryInk, "study.remaining")
    // "Show answer" at the bottom.
    screen.expectText(in: CGRect(x: 100, y: 874 - 16 - 44, width: 202, height: 44), screen.palette.ink, "study.reveal")
    screen.expectNoBlue()
  }

  @Test(arguments: looks)
  func studyRevealed(_ look: Look) throws {
    var state = StudyFeature.State()
    state.cards = IdentifiedArray(uniqueElements: [Card].fixtures)
    state.phase = .studying
    state.isRevealed = true
    let screen = try Screen(StudyView(store: Store(initialState: state) { EmptyReducer() }), look)

    screen.expectBackgroundEdges()
    // Spec 001: the four ratings are plain ink text, no fill, no blue tint.
    screen.expectText(in: CGRect(x: 16, y: 874 - 16 - 44, width: 370, height: 44), screen.palette.ink, "study.rate.*")
    screen.expect(at: CGPoint(x: 200, y: 874 - 16 - 22), screen.palette.background, "between the ratings (no fill)")
    screen.expectNoBlue()
  }

  @Test(arguments: looks)
  func deck(_ look: Look) throws {
    var state = DeckFeature.State()
    state.phase = .loaded  // "No cards yet": a scroll view, drawn empty, instead of the List placeholder
    let screen = try Screen(DeckView(store: Store(initialState: state) { EmptyReducer() }), look)

    screen.expectBackgroundEdges()
    // Header (24 pt from the top): "Cards", then the gear and add circles at the right.
    screen.expectText(in: CGRect(x: 16, y: 24, width: 140, height: 44), screen.palette.ink, "deck.title")
    screen.expect(at: CGPoint(x: 402 - 16 - 44 - 8 - 44 + 7, y: 46), screen.palette.surface, "deck.settings circle fill")
    screen.expect(at: CGPoint(x: 402 - 16 - 44 + 7, y: 46), screen.palette.surface, "deck.add circle fill")
    // Search field: a surface row under the header; the TextField itself is a placeholder, so sample its padding.
    screen.expect(at: CGPoint(x: 16 + 6, y: 103), screen.palette.surface, "deck.search fill, left")
    screen.expect(at: CGPoint(x: 402 - 16 - 6, y: 103), screen.palette.surface, "deck.search fill, right")
    screen.expectText(in: CGRect(x: 30, y: 88, width: 24, height: 30), screen.palette.secondaryInk, "magnifying glass")
    screen.expect(at: CGPoint(x: 8, y: 103), screen.palette.background, "left of the search field")
    screen.expectNoBlue()
  }

  @Test(arguments: looks)
  func settings(_ look: Look) throws {
    let screen = try Screen(SettingsView(store: Store(initialState: SettingsFeature.State()) { EmptyReducer() }), look)

    screen.expectBackgroundEdges()
    screen.expectText(in: CGRect(x: 24, y: 24, width: 160, height: 44), screen.palette.ink, "settings.title")
    screen.expect(at: CGPoint(x: 402 - 24 - 44 + 7, y: 46), screen.palette.surface, "settings.close circle fill")
    screen.expectNoBlue()
  }

  @Test(arguments: looks)
  func editor(_ look: Look) throws {
    let state = CardEditorFeature.State(card: [Card].fixtures[2])
    let screen = try Screen(CardEditorView(store: Store(initialState: state) { EmptyReducer() }), look)

    screen.expectBackgroundEdges()
    screen.expectText(in: CGRect(x: 24, y: 24, width: 160, height: 44), screen.palette.ink, "editor.title")
    screen.expect(at: CGPoint(x: 402 - 24 - 44 - 8 - 44 + 7, y: 46), screen.palette.surface, "editor.save circle fill")
    screen.expect(at: CGPoint(x: 402 - 24 - 44 + 7, y: 46), screen.palette.surface, "editor.close circle fill")
    screen.expect(at: CGPoint(x: 201, y: 46), screen.palette.background, "between title and buttons")
    screen.expectNoBlue()
  }

  /// Spec 000 #4: the gallery on the theme's background, with its circle buttons on `surface`.
  @Test(arguments: looks)
  func gallery(_ look: Look) throws {
    let screen = try Screen(DesignSystemGalleryContent().background(Theme.background), look, pointHeight: nil)

    screen.expect(at: CGPoint(x: 3, y: 3), screen.palette.background, "gallery background top-left")
    screen.expect(at: CGPoint(x: 3, y: screen.size.height - 3), screen.palette.background, "gallery background bottom")
    #expect(screen.share(of: screen.palette.background) > 0.5, "gallery mostly \(screen.palette.background)")
    #expect(screen.share(of: screen.palette.surface) > 0.01, "gallery has \(screen.palette.surface) circle buttons")
    screen.expectNoBlue()
  }
}

// MARK: - Helpers

/// A theme as the app applies it: `\.appTheme` plus the color scheme it resolves to, and the palette it must show.
struct Look: CustomTestStringConvertible, Sendable {
  let theme: AppTheme
  let scheme: ColorScheme
  let palette: Palette

  var testDescription: String { "\(theme.rawValue)/\(scheme == .dark ? "dark" : "light")" }
}

/// Token values (spec 004 #4, docs/design-system.md), as 0xRRGGBB. Same values as `Palette` in the UI tests.
struct Palette: Sendable {
  let background: UInt32, surface: UInt32, ink: UInt32, secondaryInk: UInt32
  static let light = Palette(background: 0xF9FAF5, surface: 0xFFFFFF, ink: 0x1C1C1C, secondaryInk: 0x9D9D9B)
  static let dark = Palette(background: 0x1A1A1A, surface: 0x252525, ink: 0xF2F2F0, secondaryInk: 0x8A8A88)
  static let forest = Palette(background: 0x0E1913, surface: 0x16241B, ink: 0xEEF2EC, secondaryInk: 0x83938A)
}

/// A view rendered at iPhone 17 Pro size (402 × 874 pt, no safe area) at 2×, sampled in points.
@MainActor
struct Screen {
  static let scale: CGFloat = 2
  let size: CGSize
  /// What the screen must show.
  let palette: Palette
  private let pixels: [UInt8]
  private let width: Int, height: Int

  /// `pointHeight: nil` lets the content pick its height (the gallery).
  init(_ view: some View, _ look: Look, pointHeight: CGFloat? = 874) throws {
    let renderer = ImageRenderer(
      content: view
        .frame(width: 402, height: pointHeight)
        .environment(\.appTheme, look.theme)
        .environment(\.colorScheme, look.scheme)
    )
    renderer.scale = Self.scale
    palette = look.palette
    let image = try #require(renderer.cgImage)
    width = image.width
    height = image.height
    size = CGSize(width: CGFloat(width) / Self.scale, height: CGFloat(height) / Self.scale)
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    let context = try #require(CGContext(
      data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    pixels = buffer
  }

  func color(at point: CGPoint) -> UInt32 {
    let x = min(max(Int(point.x * Self.scale), 0), width - 1)
    let y = min(max(Int(point.y * Self.scale), 0), height - 1)
    let i = (y * width + x) * 4
    return UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2])
  }

  /// Pixels (as r, g, b) that match `predicate`.
  private func count(where predicate: (Int, Int, Int) -> Bool) -> Int {
    pixels.withUnsafeBufferPointer { p in
      stride(from: 0, to: p.count, by: 4).reduce(0) { n, i in
        predicate(Int(p[i]), Int(p[i + 1]), Int(p[i + 2])) ? n + 1 : n
      }
    }
  }

  /// Fraction of pixels within ±4 per channel of `color`.
  func share(of color: UInt32) -> Double {
    let (r, g, b) = (Int(color >> 16), Int(color >> 8 & 0xFF), Int(color & 0xFF))
    let n = count { abs($0 - r) <= 4 && abs($1 - g) <= 4 && abs($2 - b) <= 4 }
    return Double(n) / Double(width * height)
  }

  func expect(at point: CGPoint, _ expected: UInt32, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let c = color(at: point)
    #expect(Self.isClose(c, expected), "\(what) at \(point) is \(Self.hex(c)), expected \(Self.hex(expected))",
            sourceLocation: sourceLocation)
  }

  /// The four edges (top-left, left middle, right at 35 %, bottom-left) are the background, like the UI tests sample.
  func expectBackgroundEdges(sourceLocation: SourceLocation = #_sourceLocation) {
    for (name, point) in [
      ("top-left", CGPoint(x: 3, y: 3)), ("left edge", CGPoint(x: 3, y: size.height / 2)),
      ("right edge", CGPoint(x: size.width - 3, y: size.height * 0.35)), ("bottom-left", CGPoint(x: 8, y: size.height - 8)),
    ] {
      expect(at: point, palette.background, "background \(name)", sourceLocation: sourceLocation)
    }
  }

  /// Text is anti-aliased: the pixel furthest from the background in `rect` should be the token (± 8), as in the
  /// UI tests' `assertTextColor`.
  func expectText(in rect: CGRect, _ expected: UInt32, _ what: String,
                  sourceLocation: SourceLocation = #_sourceLocation) {
    let background = palette.background
    var best = background, bestDistance = -1
    for y in stride(from: rect.minY, to: rect.maxY, by: 0.5) {
      for x in stride(from: rect.minX, to: rect.maxX, by: 0.5) {
        let c = color(at: CGPoint(x: x, y: y))
        if Self.distance(c, background) > bestDistance { bestDistance = Self.distance(c, background); best = c }
      }
    }
    #expect(Self.isClose(best, expected, tolerance: 8), "\(what) text is \(Self.hex(best)), expected \(Self.hex(expected))",
            sourceLocation: sourceLocation)
  }

  /// Design system "no default blue tint": no saturated blue pixel anywhere (same rule as the UI tests).
  func expectNoBlue(sourceLocation: SourceLocation = #_sourceLocation) {
    let blue = count { r, g, b in b > r + 60 && b > g + 30 }
    #expect(blue == 0, "\(blue) blue pixels", sourceLocation: sourceLocation)
  }

  static func isClose(_ a: UInt32, _ b: UInt32, tolerance: Int = 4) -> Bool {
    distances(a, b).allSatisfy { $0 <= tolerance }
  }

  static func distance(_ a: UInt32, _ b: UInt32) -> Int { distances(a, b).reduce(0, +) }

  private static func distances(_ a: UInt32, _ b: UInt32) -> [Int] {
    [16, 8, 0].map { abs(Int(a >> $0 & 0xFF) - Int(b >> $0 & 0xFF)) }
  }

  static func hex(_ c: UInt32) -> String { String(format: "#%06X", c) }
}
