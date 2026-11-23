import XCTest

/// Specs 007 and 024: the Home Screen widget, validated through its debug gallery (`LA_CARTE_SCREEN=widget`, 007 #23,
/// 024 #17). Widgets aren't reachable from XCUITest; the gallery renders `DeckWidgetView` from the spec 024 scenario
/// fixtures, in small (170 × 170) and medium (364 × 170) tiles. Each tile has its own id; the snapshots are the review
/// (no VoiceOver checks for now, docs/testing.md).
final class WidgetUITests: XCTestCase {
  /// Spec 004 #4 tokens (Support.swift `Palette`): tile = `background`, gallery wallpaper = `surface`.
  static let palettes: [String: Palette] = ["light": .light, "dark": .dark, "forest": .forest]
  static let appearances: [XCUIDevice.Appearance] = [.light, .dark]

  /// Spec 024 Scenarios table ids.
  static let scenarios = ["zero", "three", "nine", "freezes", "broken", "lone", "sixty", "sixtyFrozen", "twoHundred",
                          "eightHundred"]

  /// Tile id suffix, snapshot name, width (spec 024 "Accessibility identifiers" and "Screenshots"): small tiles in a
  /// 2-column grid, then `unavailable`, then the medium tiles.
  static let tiles: [(id: String, shot: String, width: CGFloat)] =
    scenarios.map { ("small.\($0)", "widget-small-\($0)", 170) }
      + [("unavailable", "widget-unavailable", 170)]
      + scenarios.map { ("medium.\($0)", "widget-medium-\($0)", 364) }

  override func setUp() {
    continueAfterFailure = false
  }

  // MARK: - 024 #17 (007 #23) gallery in light and dark (system theme follows the device)

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
      // Spec 024 dark tiles from the forced theme too, so they don't depend on the device appearance.
      if theme == "dark" { snapshotTiles(app, suffix: "forced-dark") }
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

  /// Title, every tile (small 170 × 170, medium 364 × 170), tile background = `background`, wallpaper = `surface`
  /// for the palette.
  @MainActor
  private func assertGallery(_ app: XCUIApplication, palette name: String, context: String,
                             file: StaticString = #filePath, line: UInt = #line) {
    let title = el(app, "widgetGallery.title")
    waitForLabel(title, "Widget", file: file, line: line)
    let palette = Self.palettes[name]!
    for tile in Self.tiles {
      let e = el(app, "widgetGallery.tile.\(tile.id)")
      scrollFullyIntoView(app, e)
      XCTAssertTrue(e.waitFor(timeout: 5), "[\(context)] tile \(tile.id) missing", file: file, line: line)
      XCTAssertEqual(e.frame.width, tile.width, accuracy: 0.5, "[\(context)] \(tile.id) width", file: file, line: line)
      XCTAssertEqual(e.frame.height, 170, accuracy: 0.5, "[\(context)] \(tile.id) height", file: file, line: line)
      let f = e.frame
      // The top-right corner (inside the 22 pt radius) and the right content margin are empty background in every
      // state (the status line and the grid are leading / trailing on the 16 pt margin); just outside is wallpaper.
      waitForColors(app, [
        ("\(tile.id) tile top-right", CGPoint(x: f.maxX - 10, y: f.minY + 10), palette.background),
        ("\(tile.id) tile right margin", CGPoint(x: f.maxX - 6, y: f.midY), palette.background),
        ("wallpaper right of \(tile.id)", CGPoint(x: f.maxX + 3, y: f.midY), palette.surface),
      ], context: context, file: file, line: line)
    }
    // Return to the top for the full-gallery screenshot.
    scrollBackIntoView(app, title, maxSwipes: 20)
  }

  /// Scrolls until the whole tile is on screen (a hittable tile can still be cut by the bottom edge).
  @MainActor
  private func scrollFullyIntoView(_ app: XCUIApplication, _ tile: XCUIElement) {
    scrollIntoView(app, tile)
    let window = app.windows.firstMatch
    var drags = 0
    while tile.frame.maxY > window.frame.maxY - 40, drags < 6 {
      window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
      drags += 1
    }
  }

  /// One cropped screenshot per tile: `<shot>-<suffix>` (e.g. `widget-small-nine-light`, `widget-medium-zero-forest`).
  @MainActor
  private func snapshotTiles(_ app: XCUIApplication, suffix: String) {
    for tile in Self.tiles {
      let e = el(app, "widgetGallery.tile.\(tile.id)")
      scrollFullyIntoView(app, e)
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
