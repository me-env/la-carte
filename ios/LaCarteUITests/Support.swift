import XCTest

enum APIMode {
  case mock
  case live(String)
  /// No API env at all (neither `LA_CARTE_API` nor `LA_CARTE_API_URL`/`_TOKEN`): the app uses the URL and token
  /// stored by Settings (spec 003 #6, #9).
  case stored
}

/// Port nothing listens on: used to exercise the "API unreachable" state.
let unreachableAPIURL = "http://127.0.0.1:9"

/// Launch argument pair forcing Dynamic Type to accessibility XL.
let accessibilityXLArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
/// Largest Dynamic Type size (AX5), spec 009b #9.
let accessibilityAX5Arguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

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
    XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element) missing", file: file, line: line)
    let predicate = NSPredicate(format: "label == %@", expected)
    let exp = XCTNSPredicateExpectation(predicate: predicate, object: element)
    let result = XCTWaiter().wait(for: [exp], timeout: timeout)
    XCTAssertEqual(result, .completed, "Expected label '\(expected)', got '\(element.label)'", file: file, line: line)
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

  /// Waits until `element` no longer exists.
  @MainActor
  func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 5, _ message: String = "",
                      file: StaticString = #filePath, line: UInt = #line) {
    let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
    XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: timeout), .completed,
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
    Thread.sleep(forTimeInterval: 1)
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
    XCTAssertTrue(deckTitle(app).waitForExistence(timeout: timeout), "deck navigation bar \"Cards\" missing",
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
    app.navigationBars.matching(NSPredicate(format: "identifier IN %@", ["New card", "Edit card"])).firstMatch
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
    XCTAssertTrue(sheetBar(app, title).waitForExistence(timeout: timeout), "sheet '\(title)' missing",
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
