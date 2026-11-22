import APIClient
import ComposableArchitecture
import CoreGraphics
import SwiftUI
import Testing
import UIKit

@testable import DeckFeature
@testable import DesignSystem
@testable import NoteEditorFeature
@testable import SettingsFeature
@testable import StudyFeature

/// Screens rendered in a window per theme × scheme, checked against the colour tokens. These replace the UI suite's
/// per-appearance colour passes (tooling proposal P8 / P4).
///
/// Checks sample bands of the screen (top bar, centre, bottom) and colour shares rather than fixed points, so a layout
/// change doesn't break them. Anything the device draws (status bar, keyboard, sheets, Liquid Glass, swipe actions)
/// stays checked in the UI tests. `scripts/ios-test.sh --render` also writes each render as a PNG.
@MainActor
@Suite(.serialized)
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

    screen.expectBackground()
    // Top bar: "3 to review" between the glass circles (glass is checked in the UI tests); the number is the accent
    // (design-system rule 4), the words secondary ink.
    screen.expectText(in: screen.band(0, 0.2, x: 0.3, 0.7), screen.palette.accent, "study.remaining number")
    screen.expectText(in: screen.band(0, 0.2, x: 0.46, 0.7), screen.palette.secondaryInk, "study.remaining words")
    screen.expectText(in: screen.band(0.4, 0.6), screen.palette.ink, "study.front")
    screen.expectText(in: screen.band(0.85, 1), screen.palette.ink, "study.reveal")
    screen.expectNoBlue()
  }

  @Test(arguments: looks)
  func studyRevealed(_ look: Look) throws {
    var state = StudyFeature.State()
    state.cards = IdentifiedArray(uniqueElements: [Card].fixtures)
    state.phase = .studying
    state.isRevealed = true
    let screen = try Screen(StudyView(store: Store(initialState: state) { EmptyReducer() }), look)

    screen.expectBackground()
    // Spec 001: the four ratings are plain ink text, no fill, no blue tint.
    let ratings = screen.band(0.85, 1)
    screen.expectText(in: ratings, screen.palette.ink, "study.rate.*")
    #expect(screen.share(of: screen.palette.background, in: ratings) > 0.9, "ratings on the background (no fill)")
    screen.expectNoBlue()
  }

  /// Native screens (spec 009a/b): system navigation title and glass buttons, so only our fills are checked.
  @Test(arguments: looks)
  func deck(_ look: Look) throws {
    var state = DeckFeature.State()
    state.notes = IdentifiedArray(uniqueElements: [Note].fixtures)
    state.phase = .loaded
    let screen = try Screen(DeckView(store: Store(initialState: state) { EmptyReducer() }), look)

    screen.expectBackground()
    #expect(screen.share(of: screen.palette.surface) > 0.05, "deck rows on \(Screen.hex(screen.palette.surface))")
    screen.expectNoBlue()
  }

  @Test(arguments: looks)
  func settings(_ look: Look) throws {
    let screen = try Screen(SettingsView(store: Store(initialState: SettingsFeature.State()) { EmptyReducer() }), look)

    screen.expectBackground()
    #expect(screen.share(of: screen.palette.surface) > 0.05, "settings rows on \(Screen.hex(screen.palette.surface))")
    screen.expectNoBlue()
  }

  @Test(arguments: looks)
  func editor(_ look: Look) throws {
    let state = NoteEditorFeature.State(note: [Note].fixtures.first { $0.type == .basic })
    let screen = try Screen(NoteEditorView(store: Store(initialState: state) { EmptyReducer() }), look)

    screen.expectBackground()
    #expect(screen.share(of: screen.palette.surface) > 0.02, "editor fields on \(Screen.hex(screen.palette.surface))")
    screen.expectNoBlue()
  }

  /// Spec 000 #4: the gallery on the theme's background, with its circle buttons on `surface`.
  @Test(arguments: looks)
  func gallery(_ look: Look) throws {
    let screen = try Screen(DesignSystemGalleryContent().background(Theme.background), look, pointHeight: nil)

    screen.expect(at: CGPoint(x: 3, y: 3), screen.palette.background, "gallery background top-left")
    screen.expect(at: CGPoint(x: 3, y: screen.size.height - 3), screen.palette.background, "gallery background bottom")
    #expect(screen.share(of: screen.palette.background) > 0.5, "gallery mostly \(Screen.hex(screen.palette.background))")
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
  let background: UInt32, surface: UInt32, ink: UInt32, secondaryInk: UInt32, accent: UInt32
  static let light = Palette(
    background: 0xF9FAF5, surface: 0xFFFFFF, ink: 0x1C1C1C, secondaryInk: 0x9D9D9B, accent: 0xB8325A)
  static let dark = Palette(
    background: 0x1A1A1A, surface: 0x252525, ink: 0xF2F2F0, secondaryInk: 0x8A8A88, accent: 0xED6E8C)
  static let forest = Palette(
    background: 0x0E1913, surface: 0x16241B, ink: 0xEEF2EC, secondaryInk: 0x83938A, accent: 0xED6E8C)
}

/// A view hosted in a window at iPhone 17 Pro size (402 × 874 pt) and drawn with `CALayer.render` at 3×, sampled in
/// points. A window, not `ImageRenderer`: the native screens are UIKit-backed (NavigationStack, Form, toolbar,
/// searchable), which `ImageRenderer` can't draw and which crashed the test process when it tried.
@MainActor
struct Screen {
  static let scale: CGFloat = 3
  let size: CGSize
  /// What the screen must show.
  let palette: Palette
  private let pixels: [UInt8]
  private let width: Int, height: Int

  /// `pointHeight: nil` lets the content pick its height (the gallery).
  init(_ view: some View, _ look: Look, pointHeight: CGFloat? = 874, name: String = #function) throws {
    let host = UIHostingController(rootView: view.environment(\.appTheme, look.theme))
    let pointHeight = pointHeight ?? host.sizeThatFits(in: CGSize(width: 402, height: CGFloat.infinity)).height
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: pointHeight))
    window.overrideUserInterfaceStyle = look.scheme == .dark ? .dark : .light
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    RunLoop.main.run(until: .now + 0.05)
    host.view.layoutIfNeeded()
    // Liquid Glass shapes (`CASDFLayer`, e.g. behind a `.confirm` toolbar button) blank the whole `render(in:)`.
    for layer in Self.layers(in: window.layer) where NSStringFromClass(type(of: layer)) == "CASDFLayer" {
      layer.isHidden = true
    }
    let format = UIGraphicsImageRendererFormat()
    format.scale = Self.scale
    format.preferredRange = .standard
    let rendered = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image {
      window.layer.render(in: $0.cgContext)
    }
    if let dir = ProcessInfo.processInfo.environment["LA_CARTE_RENDER_DIR"] {
      let file = "screen-\(name.prefix { $0 != "(" })-\(look.testDescription.replacingOccurrences(of: "/", with: "-")).png"
      try rendered.pngData()?.write(to: URL(fileURLWithPath: dir).appending(path: file))
    }

    palette = look.palette
    let image = try #require(rendered.cgImage)
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

  private static func layers(in layer: CALayer) -> [CALayer] {
    [layer] + (layer.sublayers ?? []).flatMap(layers(in:))
  }

  /// The part of the screen between fractions `top` and `bottom` of its height (and `left`, `right` of its width).
  func band(_ top: CGFloat, _ bottom: CGFloat, x left: CGFloat = 0, _ right: CGFloat = 1) -> CGRect {
    CGRect(x: size.width * left, y: size.height * top,
           width: size.width * (right - left), height: size.height * (bottom - top))
  }

  func color(at point: CGPoint) -> UInt32 {
    let x = min(max(Int(point.x * Self.scale), 0), width - 1)
    let y = min(max(Int(point.y * Self.scale), 0), height - 1)
    let i = (y * width + x) * 4
    return UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2])
  }

  /// The pixel columns and rows covered by `rect` (default: the whole screen).
  private func pixelRanges(_ rect: CGRect?) -> (xs: Range<Int>, ys: Range<Int>) {
    let r = rect ?? CGRect(origin: .zero, size: size)
    return (max(Int(r.minX * Self.scale), 0)..<min(Int(r.maxX * Self.scale), width),
            max(Int(r.minY * Self.scale), 0)..<min(Int(r.maxY * Self.scale), height))
  }

  /// Pixels in `rect` (as r, g, b) that match `predicate`, and how many pixels `rect` has.
  private func count(in rect: CGRect? = nil, where predicate: (Int, Int, Int) -> Bool) -> (matching: Int, total: Int) {
    let (xs, ys) = pixelRanges(rect)
    var n = 0
    pixels.withUnsafeBufferPointer { p in
      for y in ys {
        for x in xs {
          let i = (y * width + x) * 4
          if predicate(Int(p[i]), Int(p[i + 1]), Int(p[i + 2])) { n += 1 }
        }
      }
    }
    return (n, xs.count * ys.count)
  }

  /// Fraction of pixels in `rect` (default: the whole screen) within ±4 per channel of `color`.
  func share(of color: UInt32, in rect: CGRect? = nil) -> Double {
    let (r, g, b) = (Int(color >> 16), Int(color >> 8 & 0xFF), Int(color & 0xFF))
    let n = count(in: rect) { abs($0 - r) <= 4 && abs($1 - g) <= 4 && abs($2 - b) <= 4 }
    return n.total == 0 ? 0 : Double(n.matching) / Double(n.total)
  }

  func expect(at point: CGPoint, _ expected: UInt32, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let c = color(at: point)
    #expect(Self.isClose(c, expected), "\(what) at \(point) is \(Self.hex(c)), expected \(Self.hex(expected))",
            sourceLocation: sourceLocation)
  }

  /// Mostly the background, and the four edges (top-left, left middle, right at 35 %, bottom-left) too, like the UI
  /// tests sample.
  func expectBackground(sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(share(of: palette.background) > 0.5, "screen mostly \(Self.hex(palette.background))",
            sourceLocation: sourceLocation)
    for (name, point) in [
      ("top-left", CGPoint(x: 3, y: 3)), ("left edge", CGPoint(x: 3, y: size.height / 2)),
      ("right edge", CGPoint(x: size.width - 3, y: size.height * 0.35)), ("bottom-left", CGPoint(x: 8, y: size.height - 8)),
    ] {
      expect(at: point, palette.background, "background \(name)", sourceLocation: sourceLocation)
    }
  }
  /// Text is anti-aliased, and light-on-dark glyphs overshoot a little at their edges: the commonest colour among the
  /// pixels furthest from the background in `rect` (within 90 % of the furthest) should be the token (± 10).
  func expectText(in rect: CGRect, _ expected: UInt32, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let (xs, ys) = pixelRanges(rect)
    let colors = ys.flatMap { y in
      xs.map { x in
        let i = (y * width + x) * 4
        let color = UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2])
        return (color: color, distance: Self.distance(color, palette.background))
      }
    }
    let furthest = colors.map(\.distance).max() ?? 0
    let core = Dictionary(colors.filter { $0.distance * 10 >= furthest * 9 }.map { ($0.color, 1) }, uniquingKeysWith: +)
    let text = core.max { $0.value < $1.value }?.key ?? palette.background
    #expect(Self.isClose(text, expected, tolerance: 10), "\(what) text is \(Self.hex(text)), expected \(Self.hex(expected))",
            sourceLocation: sourceLocation)
  }

  /// Design system "no default blue tint": no saturated blue pixel anywhere (same rule as the UI tests).
  func expectNoBlue(sourceLocation: SourceLocation = #_sourceLocation) {
    let blue = count { r, g, b in b > r + 60 && b > g + 30 }.matching
    #expect(blue == 0, "\(blue) blue pixels", sourceLocation: sourceLocation)
  }

  static func isClose(_ a: UInt32, _ b: UInt32, tolerance: Int = 4) -> Bool {
    distances(a, b).allSatisfy { $0 <= tolerance }
  }

  static func distance(_ a: UInt32, _ b: UInt32) -> Int {
    abs(Int(a >> 16 & 0xFF) - Int(b >> 16 & 0xFF)) + abs(Int(a >> 8 & 0xFF) - Int(b >> 8 & 0xFF))
      + abs(Int(a & 0xFF) - Int(b & 0xFF))
  }

  private static func distances(_ a: UInt32, _ b: UInt32) -> [Int] {
    [16, 8, 0].map { abs(Int(a >> $0 & 0xFF) - Int(b >> $0 & 0xFF)) }
  }

  static func hex(_ c: UInt32) -> String { String(format: "#%06X", c) }
}
