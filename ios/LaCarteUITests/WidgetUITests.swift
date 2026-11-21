import XCTest

/// Spec 007: the Home Screen widget, validated through its debug gallery (`LA_CARTE_SCREEN=widget`, #23).
/// Widgets aren't reachable from XCUITest; the gallery renders `DeckWidgetView` from fixed entries in 170 pt tiles.
/// Each tile is one accessibility element whose label is the widget's VoiceOver text, so it also proves the state.
final class WidgetUITests: XCTestCase {
  typealias RGB = (Int, Int, Int)
  /// Same tokens as `ThemeUITests.Palette` (spec 004 #4): tile = `background`, gallery wallpaper = `surface`.
  static let palettes: [String: (background: RGB, surface: RGB)] = [
    "light": ((249, 250, 245), (255, 255, 255)),
    "dark": ((26, 26, 26), (37, 37, 37)),
    "forest": ((14, 25, 19), (22, 36, 27)),
  ]
  static let appearances: [XCUIDevice.Appearance] = [.light, .dark]

  /// state id, snapshot name, expected VoiceOver label (spec: "Accessibility identifiers", #16–#20).
  static let tiles: [(state: String, shot: String, label: String)] = [
    ("due", "widget-due", "8 cards to review, 12-day streak"),
    ("caughtUp", "widget-caught-up", "All caught up, next at \(todayAt1840()), 3-day streak"),
    ("caughtUpLater", "widget-caught-up-later", "All caught up, next on \(inThreeDays()), No streak yet"),
    ("empty", "widget-empty", "No cards yet, No streak yet"),
    ("unavailable", "widget-unavailable", "Can't reach your deck"),
    ("long", "widget-long", "999 cards to review, 365-day streak"),
  ]

  /// "18:40" in the simulator's locale (e.g. "6:40 pm" in en_US: localized short time, #17), lowercased like the label.
  static func todayAt1840() -> String {
    let date = Calendar.current.date(bySettingHour: 18, minute: 40, second: 0, of: .now)!
    return date.formatted(date: .omitted, time: .shortened).localizedLowercase
  }

  /// "next on 24 Nov" style date (localized short date, #17) three days from now, lowercased like the label.
  static func inThreeDays() -> String {
    let date = Date.now.addingTimeInterval(3 * 86_400)
    return date.formatted(.dateTime.day().month(.abbreviated)).localizedLowercase
  }

  override func setUp() {
    continueAfterFailure = false
  }

  // MARK: - #16–#20, #23 gallery in light and dark (system theme follows the device)

  @MainActor
  func testWidget_galleryAllStates() {
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .mock, screen: "widget")
      assertGallery(app, palette: appearance == .dark ? "dark" : "light", context: "\(appearance)")
      snapshot("widget-gallery", appearance: appearance)
      snapshotTiles(app, suffix: appearance == .dark ? "dark" : "light")
      app.terminate()
    }
  }

  // MARK: - #22/#23 forest via `-theme forest`, forced light/dark win over the device

  @MainActor
  func testWidget_galleryForestAndForcedThemes() {
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .mock, screen: "widget", theme: "forest")
      assertGallery(app, palette: "forest", context: "-theme forest, device \(appearance)")
      snapshot("widget-gallery-forest", appearance: appearance)
      if appearance == .light { snapshotTiles(app, suffix: "forest") }
      app.terminate()
    }
    // Forced themes against the opposite device appearance.
    for (theme, device) in [("light", XCUIDevice.Appearance.dark), ("dark", .light)] {
      XCUIDevice.shared.appearance = device
      let app = launch(api: .mock, screen: "widget", theme: theme)
      assertGallery(app, palette: theme, context: "-theme \(theme), device \(device)")
      snapshot("widget-gallery-forced-\(theme)", appearance: device)
      app.terminate()
    }
  }

  // MARK: - #22 theme picked in Settings (stored in the App Group suite) reaches the widget view

  /// The theme picked in Settings is what the widget reads (App Group `theme` key, #11/#22): pick Forest, relaunch
  /// on the gallery with no `-theme` argument → forest tiles; then back to System.
  @MainActor
  func testWidget_storedThemeFromSettings() {
    addTeardownBlock { @MainActor [self] in pickTheme("system") }
    XCUIDevice.shared.appearance = .light
    pickTheme("forest")
    let app = launch(api: .mock, screen: "widget", theme: nil)
    assertGallery(app, palette: "forest", context: "stored forest, no launch argument")
    snapshot("widget-gallery-stored-forest", appearance: .light)
    app.terminate()
  }

  // MARK: - accessibility sizes

  /// At accessibility sizes the widget can't grow; the screenshots show how the text behaves inside the tile
  /// (reviewed visually: the accessibility frame includes overflowing text, so it isn't asserted).
  @MainActor
  func testWidget_galleryAccessibilitySizes() {
    let sizes = [("xl", "UICTContentSizeCategoryAccessibilityXL"), ("xxxl", "UICTContentSizeCategoryAccessibilityXXXL")]
    for (name, category) in sizes {
      for appearance in Self.appearances {
        XCUIDevice.shared.appearance = appearance
        let app = launch(api: .mock, screen: "widget",
                         arguments: ["-UIPreferredContentSizeCategoryName", category])
        let title = el(app, "widgetGallery.title")
        XCTAssertTrue(title.waitForExistence(timeout: 10), "widgetGallery.title missing at \(name)")
        snapshot("widget-gallery-\(name)", appearance: appearance)
        for tile in Self.tiles {
          let e = el(app, "widgetGallery.tile.\(tile.state)")
          scrollIntoView(app, e)
          XCTAssertTrue(e.exists, "tile \(tile.state) missing at \(name)")
          XCTAssertEqual(e.label, tile.label, "tile \(tile.state) label at \(name)")
          attach(e.screenshot(), "\(tile.shot)-\(name)-\(appearance == .dark ? "dark" : "light")")
        }
        app.terminate()
      }
    }
  }

  // MARK: - Helpers

  /// Title, every tile (170×170, label = expected VoiceOver text), tile background = `background`, wallpaper =
  /// `surface` for the palette.
  @MainActor
  private func assertGallery(_ app: XCUIApplication, palette name: String, context: String,
                             file: StaticString = #filePath, line: UInt = #line) {
    let title = el(app, "widgetGallery.title")
    waitForLabel(title, "Widget", file: file, line: line)
    let palette = Self.palettes[name]!
    for tile in Self.tiles {
      let e = el(app, "widgetGallery.tile.\(tile.state)")
      scrollIntoView(app, e)
      XCTAssertTrue(e.waitForExistence(timeout: 5), "[\(context)] tile \(tile.state) missing", file: file, line: line)
      XCTAssertEqual(e.frame.width, 170, accuracy: 0.5, "[\(context)] \(tile.state) width", file: file, line: line)
      XCTAssertEqual(e.frame.height, 170, accuracy: 0.5, "[\(context)] \(tile.state) height", file: file, line: line)
      XCTAssertEqual(e.label, tile.label, "[\(context)] \(tile.state) VoiceOver text", file: file, line: line)
      let f = e.frame
      // Bottom-right inner corner of the tile (inside the 22 pt radius) is empty background in every state;
      // just outside the tile is the wallpaper.
      waitForColors(app, [
        ("\(tile.state) tile background", CGPoint(x: f.maxX - 20, y: f.maxY - 20), palette.background),
        ("\(tile.state) tile center-right", CGPoint(x: f.maxX - 8, y: f.midY), palette.background),
        ("wallpaper right of \(tile.state)", CGPoint(x: f.maxX + 3, y: f.midY), palette.surface),
      ], context: context, file: file, line: line)
    }
    // Return to the top for the full-gallery screenshot.
    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
      .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
  }

  /// One cropped screenshot per tile: `<shot>-<suffix>` (e.g. `widget-due-light`, `widget-due-forest`).
  @MainActor
  private func snapshotTiles(_ app: XCUIApplication, suffix: String) {
    for tile in Self.tiles {
      let e = el(app, "widgetGallery.tile.\(tile.state)")
      scrollIntoView(app, e)
      attach(e.screenshot(), "\(tile.shot)-\(suffix)")
    }
  }

  @MainActor
  private func attach(_ shot: XCUIScreenshot, _ name: String) {
    let attachment = XCTAttachment(screenshot: shot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// Picks `theme` in Settings → Appearance (stored value, no launch argument) and quits.
  @MainActor
  private func pickTheme(_ theme: String) {
    let app = launch(api: .mock, theme: nil)
    let deck = el(app, "study.deck")
    XCTAssertTrue(deck.waitForExistence(timeout: 10), "study.deck missing")
    deck.tap()
    let gear = el(app, "deck.settings")
    XCTAssertTrue(gear.waitForExistence(timeout: 5), "deck.settings missing")
    gear.tap()
    let button = el(app, "settings.theme.\(theme)")
    XCTAssertTrue(button.waitForExistence(timeout: 5), "settings.theme.\(theme) missing")
    button.tap()
    let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: button)
    XCTAssertEqual(XCTWaiter().wait(for: [selected], timeout: 3), .completed, "\(theme) not selected")
    app.terminate()
  }

  private static func close(_ c: RGB, _ e: RGB, tolerance: Int = 4) -> Bool {
    abs(c.0 - e.0) <= tolerance && abs(c.1 - e.1) <= tolerance && abs(c.2 - e.2) <= tolerance
  }

  @MainActor
  private func waitForColors(_ app: XCUIApplication, _ checks: [(String, CGPoint, RGB)], context: String,
                             timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line) {
    let width = app.windows.firstMatch.frame.width
    let deadline = Date().addingTimeInterval(timeout)
    var failures: [String] = []
    repeat {
      let pixels = Pixels(XCUIScreen.main.screenshot(), pointWidth: width)
      failures = checks.compactMap { name, p, expected in
        let c = pixels.color(at: p)
        return Self.close(c, expected) ? nil : "\(name) at \(p) is \(c), expected \(expected)"
      }
      if failures.isEmpty { return }
      Thread.sleep(forTimeInterval: 0.2)
    } while Date() < deadline
    for f in failures { XCTFail("[\(context)] \(f)", file: file, line: line) }
  }
}
