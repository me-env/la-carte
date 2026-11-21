import XCTest

/// Spec 007: the Home Screen widget, validated through its debug gallery (`LA_CARTE_SCREEN=widget`, #23).
/// Widgets aren't reachable from XCUITest; the gallery renders `DeckWidgetView` from fixed entries in 170 pt tiles.
/// Each state is a tile with its own id; the snapshots are the review (no VoiceOver checks for now, docs/testing.md).
final class WidgetUITests: XCTestCase {
  /// Spec 004 #4 tokens (Support.swift `Palette`): tile = `background`, gallery wallpaper = `surface`.
  static let palettes: [String: Palette] = ["light": .light, "dark": .dark, "forest": .forest]
  static let appearances: [XCUIDevice.Appearance] = [.light, .dark]

  /// state id, snapshot name (spec: "Accessibility identifiers", #16–#20).
  static let tiles: [(state: String, shot: String)] = [
    ("due", "widget-due"),
    ("caughtUp", "widget-caught-up"),
    ("caughtUpLater", "widget-caught-up-later"),
    ("empty", "widget-empty"),
    ("unavailable", "widget-unavailable"),
    ("long", "widget-long"),
  ]

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

  // MARK: - Helpers

  /// Title, every tile (170×170), tile background = `background`, wallpaper =
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
      XCTAssertTrue(e.waitFor(timeout: 5), "[\(context)] tile \(tile.state) missing", file: file, line: line)
      XCTAssertEqual(e.frame.width, 170, accuracy: 0.5, "[\(context)] \(tile.state) width", file: file, line: line)
      XCTAssertEqual(e.frame.height, 170, accuracy: 0.5, "[\(context)] \(tile.state) height", file: file, line: line)
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
    XCTAssertTrue(deck.waitFor(timeout: 10), "study.deck missing")
    deck.tap()
    let gear = el(app, "deck.settings")
    XCTAssertTrue(gear.waitFor(timeout: 5), "deck.settings missing")
    gear.tap()
    waitForSheet(app, "Settings")
    let button = themeSegment(app, theme.capitalized)
    XCTAssertTrue(button.waitFor(timeout: 5), "theme segment \(theme.capitalized) missing")
    button.tap()
    XCTAssertTrue(poll(timeout: 3) { button.isSelected }, "\(theme) not selected")
    app.terminate()
  }
}
