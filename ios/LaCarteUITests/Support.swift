import XCTest

enum APIMode {
  case mock
  /// `LA_CARTE_API=mock-notes`: the in-memory deck seeded with notes (spec 014b: basics + a made-up person).
  case mockNotes
  case live(String)
  /// No API env at all (neither `LA_CARTE_API` nor `LA_CARTE_API_URL`/`_TOKEN`): the app uses the URL and token
  /// stored by Settings (spec 003 #6, #9).
  case stored
}

/// Port nothing listens on: used to exercise the "API unreachable" state.
let unreachableAPIURL = "http://127.0.0.1:9"

/// Checks `condition` right away, then every 0.1 s until `timeout`. XCTWaiter (behind `waitForExistence` and
/// predicate expectations) polls once per second, so an element already on screen still cost about 1 s.
@MainActor
func poll(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while true {
    if condition() { return true }
    if Date() >= deadline { return false }
    Thread.sleep(forTimeInterval: 0.1)
  }
}

extension XCUIElement {
  /// Fast `waitForExistence`: true as soon as the element exists (checked now, then every 0.1 s).
  @MainActor
  func waitFor(timeout: TimeInterval) -> Bool {
    poll(timeout: timeout) { exists }
  }
}

extension XCTestCase {
  @MainActor
  /// `theme`: value passed as `-theme <value>` (UserDefaults argument domain, spec 004 #6). Defaults to `system`
  /// so a theme left stored by a failed run can't change other suites' colors; pass `nil` to use the stored theme
  /// (required whenever the test taps the Settings picker: the argument domain wins over what it writes).
  func launch(api: APIMode, screen: String? = nil, arguments: [String] = [],
              theme: String? = "system") -> XCUIApplication {
    let app = XCUIApplication()
    switch api {
    case .mock:
      app.launchEnvironment["LA_CARTE_API"] = "mock"
    case .mockNotes:
      app.launchEnvironment["LA_CARTE_API"] = "mock-notes"
    case let .live(url):
      app.launchEnvironment["LA_CARTE_API_URL"] = url
      // Spec 008 #14: the app needs URL + token to be "set up"; unguarded stubs ignore the header.
      let token = ProcessInfo.processInfo.environment["LA_CARTE_API_TOKEN"] ?? ""
      app.launchEnvironment["LA_CARTE_API_TOKEN"] = token.isEmpty ? "ui-test-token" : token
    case .stored:
      break
    }
    if let screen {
      app.launchEnvironment["LA_CARTE_SCREEN"] = screen
    }
    app.launchArguments += arguments
    if let theme { app.launchArguments += ["-theme", theme] }
    app.launch()
    return app
  }

  /// Waits until `element.label == expected`; fails with the actual label otherwise.
  @MainActor
  func waitForLabel(_ element: XCUIElement, _ expected: String, timeout: TimeInterval = 10,
                    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(element.waitFor(timeout: timeout), "\(element) missing", file: file, line: line)
    let matched = poll(timeout: timeout) { element.label == expected }
    XCTAssertTrue(matched, "Expected label '\(expected)', got '\(element.label)'", file: file, line: line)
  }

  /// Asserts the on-screen static texts don't overlap each other and stay inside the window width.
  @MainActor
  /// `ignoring`: identifier prefixes to skip (e.g. "study." for the screen under a sheet).
  func assertTextsReadable(in app: XCUIApplication, ignoring: [String] = [],
                           file: StaticString = #filePath, line: UInt = #line) {
    let window = app.windows.firstMatch.frame
    let texts = app.staticTexts.allElementsBoundByIndex
      .filter { $0.exists && !$0.frame.isEmpty && $0.frame.intersects(window) }
      .filter { t in !ignoring.contains { t.identifier.hasPrefix($0) } }
    for t in texts {
      XCTAssertGreaterThanOrEqual(t.frame.minX, window.minX - 0.5, "'\(t.label)' clipped on the left", file: file, line: line)
      XCTAssertLessThanOrEqual(t.frame.maxX, window.maxX + 0.5, "'\(t.label)' clipped on the right", file: file, line: line)
    }
    for (i, a) in texts.enumerated() {
      for b in texts[(i + 1)...] {
        let overlap = a.frame.intersection(b.frame)
        XCTAssertTrue(overlap.isNull || overlap.width < 1 || overlap.height < 1,
                      "'\(a.label)' \(a.frame) overlaps '\(b.label)' \(b.frame)", file: file, line: line)
      }
    }
  }

  /// Attaches a full-screen screenshot named `<name>-<light|dark>`, kept even when the test passes.
  @MainActor
  func snapshot(_ name: String, appearance: XCUIDevice.Appearance) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "\(name)-\(appearance == .dark ? "dark" : "light")"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// First element (any type) with this accessibility identifier.
  @MainActor
  func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  @MainActor
  func hasFocus(_ element: XCUIElement) -> Bool {
    (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
  }

  /// Replaces a field's text one checked step at a time, so a slow runner (CI) can't type before the focus or the
  /// deletes land: tap at `caret` (the end of the text), wait for focus, delete until empty, type, wait for the text.
  /// `placeholders`: values the field reports when empty. `secure`: only the length can be read back.
  @MainActor
  func replaceText(_ field: XCUIElement, with text: String, placeholders: [String] = [],
                   caret: CGVector = CGVector(dx: 0.97, dy: 0.5), secure: Bool = false,
                   file: StaticString = #filePath, line: UInt = #line) {
    func current() -> String {
      let value = field.value as? String ?? ""
      return value == field.placeholderValue || placeholders.contains(value) ? "" : value
    }
    XCTAssertTrue(field.waitFor(timeout: 5), "\(field.identifier) missing", file: file, line: line)
    for _ in 0..<3 {
      field.coordinate(withNormalizedOffset: caret).tap()
      XCTAssertTrue(poll(timeout: 5) { hasFocus(field) }, "\(field.identifier) not focused", file: file, line: line)
      let old = current()
      if old.isEmpty { break }
      field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 2))
      if poll(timeout: 2, { current().isEmpty }) { break }
    }
    XCTAssertEqual(current(), "", "\(field.identifier) not cleared", file: file, line: line)
    field.typeText(text)
    let typed = poll(timeout: 5) { secure ? current().count == text.count : current() == text }
    XCTAssertTrue(typed, "\(field.identifier) is '\(current())' after typing '\(text)'", file: file, line: line)
  }

  /// Waits until `element` no longer exists.
  @MainActor
  func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5, _ message: String = "",
                      file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(poll(timeout: timeout) { !element.exists },
                  message.isEmpty ? "\(element) still exists" : message, file: file, line: line)
  }

  /// Dismisses the frontmost sheet with a downward drag starting on `handle` (e.g. its title).
  @MainActor
  func swipeSheetDown(_ app: XCUIApplication, from handle: XCUIElement) {
    let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let end = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
  }

  /// Spec 006: pull-to-refresh starting on `element` (press, then drag ~40% of the window lower, then release).
  @MainActor
  func pullToRefresh(_ app: XCUIApplication, from element: XCUIElement) {
    let window = app.windows.firstMatch.frame
    let startY = element.frame.midY
    let endY = min(startY + window.height * 0.4, window.height * 0.92)
    let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY / window.height))
    let end = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY / window.height))
    start.press(forDuration: 0.05, thenDragTo: end)
  }

  /// Spec 006: Home, then bring the app back (scene `.background` → `.active`).
  @MainActor
  func backgroundAndReactivate(_ app: XCUIApplication) {
    XCUIDevice.shared.press(.home)
    _ = poll(timeout: 3) { app.state != .runningForeground }
    app.activate()
  }

  /// Spec 006: pull-to-refresh, plus a screenshot taken `after` seconds into the gesture from a background thread.
  /// XCUITest only returns from the drag once the app is idle again, i.e. after the refresh finished, so the
  /// in-flight state (spinner, content kept on screen) can only be captured concurrently. Attached as
  /// `<name>-<light|dark>`; returns the image for pixel checks.
  @MainActor
  @discardableResult
  func pullToRefreshCapturing(_ app: XCUIApplication, from element: XCUIElement, after: TimeInterval = 2,
                              name: String, appearance: XCUIDevice.Appearance) -> CGImage? {
    let box = PNGBox()
    let thread = Thread {
      Thread.sleep(forTimeInterval: after)
      box.set(screenshotPNGOffMain())
    }
    thread.start()
    pullToRefresh(app, from: element)
    let deadline = Date().addingTimeInterval(after + 5)
    while box.get() == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    guard let png = box.get() else {
      XCTFail("\(name): no in-flight screenshot captured")
      return nil
    }
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = "\(name)-\(appearance == .dark ? "dark" : "light")"
    attachment.lifetime = .keepAlways
    add(attachment)
    guard let provider = CGDataProvider(data: png as CFData) else { return nil }
    return CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }
}

final class PNGBox: @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?
  nonisolated func set(_ d: Data?) { lock.withLock { data = d } }
  nonisolated func get() -> Data? { lock.withLock { data } }
}

/// `XCUIScreen.main.screenshot().pngRepresentation` through the ObjC runtime, callable off the main actor.
nonisolated func screenshotPNGOffMain() -> Data? {
  guard let cls = NSClassFromString("XCUIScreen") as? NSObject.Type,
        let screen = cls.perform(NSSelectorFromString("mainScreen"))?.takeUnretainedValue() as? NSObject,
        let shot = screen.perform(NSSelectorFromString("screenshot"))?.takeUnretainedValue() as? NSObject
  else { return nil }
  return shot.value(forKey: "PNGRepresentation") as? Data
}

extension XCTestCase {
  /// Scrolls the frontmost scroll view up until `element` is hittable (e.g. gallery buttons below the logo).
  @MainActor
  func scrollIntoView(_ app: XCUIApplication, _ element: XCUIElement, maxSwipes: Int = 6) {
    var swipes = 0
    while !element.isHittable, swipes < maxSwipes {
      let window = app.windows.firstMatch
      window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
      swipes += 1
    }
  }
}

// MARK: - Colours (one helper for every pixel check)

/// An 8-bit sRGB colour sampled from a screenshot.
struct RGB: Equatable, CustomStringConvertible {
  let r: Int, g: Int, b: Int

  init(_ r: Int, _ g: Int, _ b: Int) {
    self.r = r; self.g = g; self.b = b
  }

  /// Rec. 601 luma, 0…255.
  var luminance: Double { 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b) }

  /// Every channel within `tolerance` of `other`.
  func isClose(to other: RGB, tolerance: Int = 4) -> Bool {
    abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance && abs(b - other.b) <= tolerance
  }

  /// Sum of channel differences.
  func distance(to other: RGB) -> Int { abs(r - other.r) + abs(g - other.g) + abs(b - other.b) }

  /// A saturated blue pixel: the default system tint leaking in (design system "no default blue tint").
  var isSaturatedBlue: Bool { b > r + 60 && b > g + 30 }

  var description: String { "(\(r), \(g), \(b))" }
}

/// The app's colour tokens (`Theme` in LaCarteKit) per palette. LaCarteKit's `ScreenColorTests` assert the same
/// values on rendered screens; UI tests only use them for what needs the device (theme switching, sheets, chrome).
struct Palette {
  let background: RGB, surface: RGB, ink: RGB, secondaryInk: RGB
  static let light = Palette(background: RGB(249, 250, 245), surface: RGB(255, 255, 255), ink: RGB(28, 28, 28),
                             secondaryInk: RGB(157, 157, 155))
  static let dark = Palette(background: RGB(26, 26, 26), surface: RGB(37, 37, 37), ink: RGB(242, 242, 240),
                            secondaryInk: RGB(138, 138, 136))
  /// Spec 004 #4: background #0E1913, surface #16241B, ink #EEF2EC, secondaryInk #83938A.
  static let forest = Palette(background: RGB(14, 25, 19), surface: RGB(22, 36, 27), ink: RGB(238, 242, 236),
                              secondaryInk: RGB(131, 147, 138))

  static func of(_ appearance: XCUIDevice.Appearance) -> Palette { appearance == .dark ? .dark : .light }
}

/// RGB sampling of a screenshot at point coordinates.
struct ColorProbe {
  private let data: [UInt8]
  private let width: Int
  private let height: Int
  private let scale: CGFloat
  /// Size of the screenshot in points.
  let size: CGSize

  /// `pointWidth`: the window width in points (the image is @2x/@3x).
  init(_ cg: CGImage, pointWidth: CGFloat) {
    width = cg.width
    height = cg.height
    scale = CGFloat(cg.width) / pointWidth
    size = CGSize(width: pointWidth, height: CGFloat(cg.height) / scale)
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    data = buffer
  }

  /// A fresh screenshot of the screen.
  @MainActor
  init(screenOf app: XCUIApplication) {
    self.init(XCUIScreen.main.screenshot().image.cgImage!, pointWidth: app.windows.firstMatch.frame.width)
  }

  /// An @3x screenshot (iPhone 17 Pro) taken without the app, e.g. by `pullToRefreshCapturing`.
  init(at3x cg: CGImage) {
    self.init(cg, pointWidth: CGFloat(cg.width) / 3)
  }

  func color(at point: CGPoint) -> RGB {
    let x = min(max(Int(point.x * scale), 0), width - 1), y = min(max(Int(point.y * scale), 0), height - 1)
    let i = (y * width + x) * 4
    return RGB(Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
  }

  /// Every sample in `rect`, `step` points apart.
  func colors(in rect: CGRect, step: CGFloat) -> [RGB] {
    stride(from: rect.minY, to: rect.maxY, by: step).flatMap { y in
      stride(from: rect.minX, to: rect.maxX, by: step).map { x in color(at: CGPoint(x: x, y: y)) }
    }
  }
}

extension XCTestCase {
  /// Polls screenshots for up to `timeout` until every point has its expected colour (re-render, sheet animations).
  @MainActor
  func waitForColors(_ app: XCUIApplication, _ checks: [(String, CGPoint, RGB)], context: String = "",
                     timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line) {
    let deadline = Date().addingTimeInterval(timeout)
    var failures: [String] = []
    repeat {
      let probe = ColorProbe(screenOf: app)
      failures = checks.compactMap { name, p, expected in
        let c = probe.color(at: p)
        return c.isClose(to: expected) ? nil : "\(name) at \(p) is \(c), expected \(expected)"
      }
      if failures.isEmpty { return }
      Thread.sleep(forTimeInterval: 0.2)
    } while Date() < deadline
    for f in failures { XCTFail(context.isEmpty ? f : "[\(context)] \(f)", file: file, line: line) }
  }

  /// Status bar glyphs (time, top-left): light text on a dark scheme, dark text on a light one. Scans above
  /// `study.deck` when it's on screen, so the circle button isn't taken for status bar glyphs.
  @MainActor
  func assertStatusBar(_ app: XCUIApplication, darkScheme: Bool, _ context: String,
                       file: StaticString = #filePath, line: UInt = #line) {
    let deck = el(app, "study.deck")
    let bottom = min(50, deck.exists ? deck.frame.minY - 2 : 50)
    let deadline = Date().addingTimeInterval(3)
    var minL = 255.0, maxL = 0.0
    repeat {
      let lums = ColorProbe(screenOf: app).colors(in: CGRect(x: 16, y: 8, width: 124, height: bottom - 8), step: 0.5)
        .map(\.luminance)
      minL = lums.min() ?? 255; maxL = lums.max() ?? 0
      if darkScheme ? maxL > 200 : minL < 80 { return }
      Thread.sleep(forTimeInterval: 0.2)
    } while Date() < deadline
    XCTFail("[\(context)] status bar text not \(darkScheme ? "light (dark scheme)" : "dark (light scheme)"): "
      + "luminance \(Int(minL))…\(Int(maxL))", file: file, line: line)
  }

  /// Average luminance of the keyboard: dark keyboard < 110, light keyboard > 150.
  @MainActor
  func assertKeyboard(_ app: XCUIApplication, dark: Bool, _ context: String,
                      file: StaticString = #filePath, line: UInt = #line) {
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(keyboard.waitFor(timeout: 5), "[\(context)] no keyboard", file: file, line: line)
    Thread.sleep(forTimeInterval: 0.8)  // keyboard slide-in
    let lums = ColorProbe(screenOf: app).colors(in: keyboard.frame.insetBy(dx: 4, dy: 4), step: 4).map(\.luminance)
    let avg = lums.isEmpty ? 0 : lums.reduce(0, +) / Double(lums.count)
    XCTAssertTrue(dark ? avg < 110 : avg > 150, "[\(context)] keyboard average luminance \(Int(avg)), expected a "
      + (dark ? "dark" : "light") + " keyboard", file: file, line: line)
  }

  /// Spec 006 #11 / design system "no default blue tint": no saturated blue pixel anywhere on an @3x screenshot.
  func assertNoBlue(_ image: CGImage?, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
    guard let image else { return XCTFail("\(context): no screenshot", file: file, line: line) }
    let probe = ColorProbe(at3x: image)
    let blue = probe.colors(in: CGRect(origin: .zero, size: probe.size), step: 1).filter(\.isSaturatedBlue)
    XCTAssertTrue(blue.isEmpty, "\(context): \(blue.count) blue pixels, e.g. \(blue.prefix(3))", file: file, line: line)
  }

  /// Text in `ink` is drawn somewhere in the content area (y 130–760 pt) of an @3x screenshot: the screen isn't blank.
  func assertInkVisible(_ image: CGImage?, ink: RGB, _ context: String,
                        file: StaticString = #filePath, line: UInt = #line) {
    guard let image else { return XCTFail("\(context): no screenshot", file: file, line: line) }
    let probe = ColorProbe(at3x: image)
    let count = probe.colors(in: CGRect(x: 0, y: 130, width: probe.size.width, height: 630), step: 1)
      .filter { $0.isClose(to: ink, tolerance: 19) }.count
    XCTAssertGreaterThan(count, 30, "\(context): no ink-coloured text in the content area", file: file, line: line)
  }
}

extension XCTestCase {
  /// No pixel across the middle line of the element is tinted blue (a text button picking up the default tint).
  @MainActor
  func assertNotTintedBlue(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
    let f = el(app, id).frame
    let samples = ColorProbe(screenOf: app).colors(in: CGRect(x: f.minX, y: f.midY, width: f.width, height: 1), step: 1)
    XCTAssertFalse(samples.contains { $0.b - max($0.r, $0.g) > 40 }, "\(id) is tinted blue", file: file, line: line)
  }

  /// The glyph pixel furthest from `background` across the middle of the element should be `expected` (± 8).
  @MainActor
  func assertTextColor(_ app: XCUIApplication, _ id: String, _ expected: RGB, background: RGB,
                       file: StaticString = #filePath, line: UInt = #line) {
    let element = el(app, id)
    XCTAssertTrue(element.waitFor(timeout: 5), "\(id) missing", file: file, line: line)
    let f = element.frame
    let probe = ColorProbe(screenOf: app)
    var best = background, bestDistance = -1
    for y in stride(from: f.minY + f.height * 0.3, through: f.minY + f.height * 0.7, by: 0.5) {
      for x in stride(from: f.minX, to: f.maxX, by: 0.34) {
        let c = probe.color(at: CGPoint(x: x, y: y))
        if c.distance(to: background) > bestDistance { bestDistance = c.distance(to: background); best = c }
      }
    }
    XCTAssertTrue(best.isClose(to: expected, tolerance: 8), "\(id) text color \(best), expected \(expected)",
                  file: file, line: line)
  }
}

/// Spec 009a: the deck is a `NavigationStack` titled "Cards" with a system `.searchable` field (no ids of its own).
extension XCTestCase {
  /// The deck's navigation bar (`app.navigationBars["Cards"]`): present while the deck sheet is shown.
  @MainActor
  func deckTitle(_ app: XCUIApplication) -> XCUIElement { app.navigationBars["Cards"] }

  /// The large/inline "Cards" title text inside the deck's navigation bar.
  @MainActor
  func deckTitleText(_ app: XCUIApplication) -> XCUIElement { deckTitle(app).staticTexts["Cards"].firstMatch }

  /// The deck's system search field.
  @MainActor
  func deckSearch(_ app: XCUIApplication) -> XCUIElement { app.searchFields.firstMatch }

  /// Waits for the deck sheet ("Cards" navigation bar) to be on screen.
  @MainActor
  func waitForDeckTitle(_ app: XCUIApplication, timeout: TimeInterval = 10,
                        file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(deckTitle(app).waitFor(timeout: timeout), "deck navigation bar \"Cards\" missing",
                  file: file, line: line)
  }
}

// MARK: - Native sheets (spec 009b): the title is the navigation bar's, not an element with an id.

extension XCTestCase {
  /// Navigation bar of the sheet titled `title` ("Settings", "New card", "Edit card").
  @MainActor
  func sheetBar(_ app: XCUIApplication, _ title: String) -> XCUIElement {
    app.navigationBars.matching(identifier: title).firstMatch
  }

  /// Navigation bar of the card editor, whichever its title ("New card" / "Edit card").
  @MainActor
  func editorBar(_ app: XCUIApplication) -> XCUIElement {
    app.navigationBars.matching(NSPredicate(format: "identifier IN %@", ["New card", "Edit card", "New person", "Edit person"])).firstMatch
  }

  /// The title text inside the sheet's navigation bar (for frame checks).
  @MainActor
  func sheetTitle(_ app: XCUIApplication, _ title: String) -> XCUIElement {
    sheetBar(app, title).staticTexts.matching(identifier: title).firstMatch
  }

  /// Waits for the sheet titled `title` to be on screen.
  @MainActor
  func waitForSheet(_ app: XCUIApplication, _ title: String, timeout: TimeInterval = 10,
                    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(sheetBar(app, title).waitFor(timeout: timeout), "sheet '\(title)' missing",
                  file: file, line: line)
  }

  /// Settings' theme segment labelled `label` ("System", "Light", "Dark", "Forest"); `settings.theme.<name>` ids
  /// are gone (spec 009b).
  @MainActor
  func themeSegment(_ app: XCUIApplication, _ label: String) -> XCUIElement {
    let control = app.segmentedControls.matching(identifier: "settings.theme").firstMatch
    return control.exists ? control.buttons[label] : app.buttons.matching(identifier: label).firstMatch
  }
}
