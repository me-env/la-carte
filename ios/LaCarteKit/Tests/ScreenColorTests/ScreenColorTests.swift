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

  /// Spec 017: the question depends only on itself, in every candidate layout. Revealing the answer doesn't change a
  /// pixel of it, and short, 2-line and 4-line answers leave it at the same horizontal place (the stack's vertical
  /// centring may differ). In layout D, a leading answer under a wide question (widest line ≥ 85 % of the column)
  /// stays within its width, and under any other question starts at the column's edge.
  /// Amended by #14 (reveal lift): with a 4-line answer the question sits > 40 pt high, so it starts centred in the
  /// card and rises on reveal into the place it has under Reduce Motion (no lift), which is today's revealed place.
  @Test(arguments: StudyView.TextLayout.allCases, CardLines.questions.map(\.1) + CardLines.singleLines.map(\.1))
  func questionStaysPut(_ layout: StudyView.TextLayout, _ question: String) throws {
    let defaultLayout = StudyView.textLayout
    StudyView.textLayout = layout
    defer { StudyView.textLayout = defaultLayout }
    var columns: [ClosedRange<CGFloat>] = []
    var cardCentre: CGFloat?
    let questionLines = (CardLines.questions.first { $0.1 == question })?.0 ?? 1
    for (answerLines, answer) in CardLines.answers {
      let card = CardLines.card(question, answer)
      func screen(revealed: Bool, reduceMotion: Bool = false) throws -> Screen {
        var state = StudyFeature.State()
        state.cards = [card]
        state.phase = .studying
        state.isRevealed = revealed
        let view = StudyView(store: Store(initialState: state) { EmptyReducer() })
          .environment(\._accessibilityReduceMotion, reduceMotion)
        return try Screen(view, Self.looks[0], name: "study-reveal-check")
      }
      let front = try screen(revealed: false), revealed = try screen(revealed: true)
      let still = try screen(revealed: false, reduceMotion: true)
      let ink = try #require(still.inkBounds(in: still.band(0.14, 0.85)), "no question drawn")
      #expect(revealed.changedPixels(from: still, in: ink) == 0, "question moved on reveal (answer: \(answer))")
      let lifted = try #require(front.inkBounds(in: front.band(0.14, 0.85)), "no question drawn")
      #expect(lifted.minX == ink.minX && lifted.maxX == ink.maxX, "lift moved the question sideways: \(lifted) vs \(ink)")
      if answerLines <= 2 {
        #expect(front.changedPixels(from: still, in: ink.union(lifted)) == 0, "question lifted (answer: \(answer))")
        if answerLines == 1 {
          // The 1-line pair is centred in the card: its centre is midway between the question's top and the answer's
          // bottom (ink, so within a few points of the frames).
          let below = CGRect(x: 0, y: ink.maxY + 1, width: revealed.size.width, height: revealed.band(0, 0.85).maxY - ink.maxY - 1)
          cardCentre = try #require(revealed.inkBounds(in: below)).maxY / 2 + ink.minY / 2
        }
      } else {
        #expect(lifted.midY - ink.midY > 40, "question not lifted: \(lifted) vs \(ink) (answer: \(answer))")
        let centre = try #require(cardCentre)
        #expect(abs(lifted.midY - centre) <= 4, "lifted question off the card's centre: \(lifted.midY) vs \(centre)")
      }
      columns.append(ink.minX...ink.maxX)
      guard layout == .questionWidth else { continue }
      let bottom = revealed.band(0, 0.85).maxY
      let below = CGRect(x: 0, y: ink.maxY + 1, width: revealed.size.width, height: bottom - ink.maxY - 1)
      let answerInk = try #require(revealed.inkBounds(in: below), "no answer drawn")
      let leading = questionLines >= 3 || answerLines >= 3
      if leading, !CardLines.wide.contains(question) {
        // Amended 2026-11-22 (user): a question under 85 % of the column, even wrapped, leaves the answer the column.
        #expect(answerInk.minX < 16 + 3 && answerInk.width > ink.width,  // at the column's 16 pt edge
                "answer held to a narrow question: \(answerInk) vs \(ink) (answer: \(answer))")
      } else if leading {
        // Ink, not frames: a glyph's ink starts a little inside its advance (side bearings differ by letter). Measured
        // with the space a wrapped line breaks at, the answer overhung a centred question by ~3.5 pt; laid out in the
        // full column, by 10+ pt.
        #expect(answerInk.minX >= ink.minX - 1 && answerInk.maxX <= ink.maxX + 1,
                "answer wider than the question: \(answerInk) vs \(ink) (answer: \(answer))")
      } else {
        // A centred answer (amended 2026-11-22) keeps the full column: it shares the question's centre, and one that
        // the question's width would wrap stays on its own lines.
        #expect(abs(answerInk.midX - ink.midX) <= 3, "centred answer off the question's centre: \(answerInk) vs \(ink)")
      }
    }
    #expect(Set(columns.map { "\($0)" }).count == 1, "question's columns depend on the answer: \(columns)")
  }

  /// Spec 017 D, amended 2026-11-22 (user): a centred answer isn't constrained by a wide question's width. "Wolfgang
  /// Amadeus Mozart" fits one line of the column but not the 2-line question's width, so it's wider than the question.
  @Test func centredAnswerIgnoresTheQuestionWidth() throws {
    var state = StudyFeature.State()
    state.cards = [CardLines.card(CardLines.narrowWrapping, "Wolfgang Amadeus Mozart")]
    state.phase = .studying
    let front = try Screen(StudyView(store: Store(initialState: state) { EmptyReducer() }), Self.looks[0])
    state.isRevealed = true
    let revealed = try Screen(StudyView(store: Store(initialState: state) { EmptyReducer() }), Self.looks[0])
    let ink = try #require(front.inkBounds(in: front.band(0.14, 0.85)), "no question drawn")
    let below = CGRect(x: 0, y: ink.maxY + 1, width: revealed.size.width, height: revealed.band(0, 0.85).maxY - ink.maxY - 1)
    let answerInk = try #require(revealed.inkBounds(in: below), "no answer drawn")
    #expect(answerInk.width > ink.width, "answer kept inside the question: \(answerInk) vs \(ink)")
    #expect(answerInk.height < 30, "answer wrapped: \(answerInk)")  // one 22 pt line
    #expect(abs(answerInk.midX - ink.midX) <= 3, "answer off the question's centre: \(answerInk) vs \(ink)")
  }

  /// "All caught up" shows the logo centred above the message. With Reduce Motion it's the finished mark from the
  /// first frame (pink line, ink card), no tilt or draw-in. The animated path is in `RenderTests/launchMark`: this
  /// window render drops 3D transforms, so it can't draw the tilt.
  @Test(arguments: looks)
  func caughtUpReduceMotion(_ look: Look) throws {
    var state = StudyFeature.State()
    state.phase = .caughtUp(nextDue: nil)
    let view = StudyView(store: Store(initialState: state) { EmptyReducer() })
      .environment(\._accessibilityReduceMotion, true)
    let screen = try Screen(view, look)

    screen.expectBackground()
    // The logo (64 pt) is the top of the centred content, the message under it.
    let content = try #require(screen.inkBounds(in: screen.band(0.3, 0.7, x: 0.1, 0.9)), "no content")
    let logo = try #require(
      screen.inkBounds(in: CGRect(x: 0, y: content.minY, width: screen.size.width, height: 70)), "no logo"
    )
    #expect(abs(logo.midX - screen.size.width / 2) < 8, "logo off centre: \(logo)")
    #expect(logo.height > 50, "logo not full size: \(logo)")
    #expect(screen.share(of: screen.palette.accent, in: logo) > 0.02, "logo line not drawn")
    #expect(screen.share(of: screen.palette.ink, in: logo) > 0.1, "logo card missing")
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
    let gallery = DesignSystemGalleryContent(showsGoogleButtons: false)  // the G's blue: `googleButton`
    let screen = try Screen(gallery.background(Theme.background), look, pointHeight: nil)

    screen.expect(at: CGPoint(x: 3, y: 3), screen.palette.background, "gallery background top-left")
    screen.expect(at: CGPoint(x: 3, y: screen.size.height - 3), screen.palette.background, "gallery background bottom")
    #expect(screen.share(of: screen.palette.background) > 0.5, "gallery mostly \(Screen.hex(screen.palette.background))")
    screen.expectNoBlue()
  }

  /// Spec 030c: Google's branding requires its multicolour G unaltered, so it's the one blue allowed on screen. Every
  /// saturated pixel stays within the 20 pt G, which shows Google's colours; the rest of the button has no blue.
  @Test(arguments: looks)
  func googleButton(_ look: Look) throws {
    let variants: [(String, AnyView)] = [
      ("idle", AnyView(ContinueWithGoogleButton {})),
      ("loading", AnyView(ContinueWithGoogleButton(isLoading: true) {})),
      ("disabled", AnyView(ContinueWithGoogleButton {}.disabled(true))),
    ]
    for (name, button) in variants {
      let view = button.padding(Theme.Spacing.l).background(Theme.background)
      let screen = try Screen(view, look, pointHeight: nil, name: "googleButton-\(name)")

      let g = try #require(screen.saturatedBounds(), "\(name): no G drawn")
      #expect(g.width <= 21 && g.height <= 21, "\(name): colour outside the 20 pt G: \(g)")
      if name != "disabled" {  // disabled fades the whole pill to 38 %, so its G isn't Google's colours
        for (colour, hex) in [("blue", 0x4285F4), ("red", 0xEA4335), ("yellow", 0xFBBC04), ("green", 0x34A853)] {
          #expect(screen.share(of: UInt32(hex), in: g, tolerance: 10) > 0.02, "\(name): G has no Google \(colour)")
        }
      }
      screen.expectNoBlue(outside: g)
    }
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

  /// Fraction of pixels in `rect` (default: the whole screen) within ±`tolerance` per channel of `color`.
  func share(of color: UInt32, in rect: CGRect? = nil, tolerance: Int = 4) -> Double {
    let (r, g, b) = (Int(color >> 16), Int(color >> 8 & 0xFF), Int(color & 0xFF))
    let n = count(in: rect) { abs($0 - r) <= tolerance && abs($1 - g) <= tolerance && abs($2 - b) <= tolerance }
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

  /// The bounding box, in points, of the pixels in `rect` more than 24 per channel away from the background.
  func inkBounds(in rect: CGRect) -> CGRect? {
    let (xs, ys) = pixelRanges(rect)
    var box: (x0: Int, y0: Int, x1: Int, y1: Int)?
    for y in ys {
      for x in xs where Self.distances(color(atPixel: x, y), palette.background).contains(where: { $0 > 24 }) {
        box = box.map { (min($0.x0, x), min($0.y0, y), max($0.x1, x), max($0.y1, y)) } ?? (x, y, x, y)
      }
    }
    return box.map {
      CGRect(x: CGFloat($0.x0) / Self.scale, y: CGFloat($0.y0) / Self.scale,
             width: CGFloat($0.x1 - $0.x0 + 1) / Self.scale, height: CGFloat($0.y1 - $0.y0 + 1) / Self.scale)
    }
  }

  /// How many pixels in `rect` differ between the two screens.
  func changedPixels(from other: Screen, in rect: CGRect) -> Int {
    let (xs, ys) = pixelRanges(rect)
    return ys.reduce(0) { n, y in n + xs.count { color(atPixel: $0, y) != other.color(atPixel: $0, y) } }
  }

  private func color(atPixel x: Int, _ y: Int) -> UInt32 {
    let i = (y * width + x) * 4
    return UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2])
  }

  /// Design system "no default blue tint": no saturated blue pixel anywhere (same rule as the UI tests).
  /// `outside` is only for Google's G (`googleButton`).
  func expectNoBlue(outside allowed: CGRect? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
    let isBlue = { (r: Int, g: Int, b: Int) in b > r + 60 && b > g + 30 }
    let blue = count(where: isBlue).matching - (allowed.map { count(in: $0, where: isBlue).matching } ?? 0)
    #expect(blue == 0, "\(blue) blue pixels", sourceLocation: sourceLocation)
  }

  /// The bounding box, in points, of the saturated pixels (channels more than 60 apart): no palette token is.
  func saturatedBounds() -> CGRect? {
    var box: (x0: Int, y0: Int, x1: Int, y1: Int)?
    for y in 0..<height {
      for x in 0..<width {
        let i = (y * width + x) * 4
        let channels = [pixels[i], pixels[i + 1], pixels[i + 2]]
        guard channels.max()! - channels.min()! > 60 else { continue }
        box = box.map { (min($0.x0, x), min($0.y0, y), max($0.x1, x), max($0.y1, y)) } ?? (x, y, x, y)
      }
    }
    return box.map {
      CGRect(x: CGFloat($0.x0) / Self.scale, y: CGFloat($0.y0) / Self.scale,
             width: CGFloat($0.x1 - $0.x0 + 1) / Self.scale, height: CGFloat($0.y1 - $0.y0 + 1) / Self.scale)
    }
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
