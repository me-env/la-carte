import XCTest

/// Spec 004: themes (System / Light / Dark / Forest), picked in Settings → Appearance, stored under `theme`,
/// `-theme <value>` launch argument.
///
/// The stored theme survives between test launches. Every test that taps the picker launches with `theme: nil`
/// (so the argument domain doesn't mask the picker) and registers `resetThemeOnTeardown()`, which puts the stored
/// value back to System even when the test fails. Other suites launch with `-theme system` (see `launch`).
final class ThemeUITests: XCTestCase {
  typealias RGB = (Int, Int, Int)
  struct Palette {
    let background: RGB, surface: RGB, ink: RGB, secondaryInk: RGB
    static let light = Palette(background: (249, 250, 245), surface: (255, 255, 255), ink: (28, 28, 28),
                               secondaryInk: (157, 157, 155))
    static let dark = Palette(background: (26, 26, 26), surface: (37, 37, 37), ink: (242, 242, 240),
                              secondaryInk: (138, 138, 136))
    /// Spec 004 #4: background #0E1913, surface #16241B, ink #EEF2EC, secondaryInk #83938A.
    static let forest = Palette(background: (14, 25, 19), surface: (22, 36, 27), ink: (238, 242, 236),
                                secondaryInk: (131, 147, 138))
  }

  static let themes = ["system", "light", "dark", "forest"]
  static let appearances: [XCUIDevice.Appearance] = [.light, .dark]
  static let mockIDs = (1...3).map { "00000000-0000-0000-0000-00000000000\($0)" }
  static let fixtures: [(front: String, back: String)] = [
    ("serendipity", "finding something good without looking for it"),
    ("la carte", "the menu — and the map"),
    ("ephemeral", "lasting a very short time"),
  ]

  override func setUp() {
    continueAfterFailure = false
  }

  // MARK: - #1 picker

  /// #1: "Appearance" section with four equal-width options in one row (System, Light, Dark, Forest); System is
  /// selected by default (stored value = System, reset by every theme test); selected = ink fill, others = surface.
  @MainActor
  func testSettings_appearancePicker() {
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .mock, theme: nil)
      openDeck(app)
      openSettings(app)
      let palette: Palette = appearance == .dark ? .dark : .light
      let buttons = Self.themes.map { themeButton(app, $0) }
      for (theme, b) in zip(Self.themes, buttons) {
        XCTAssertTrue(b.waitForExistence(timeout: 5), "settings.theme.\(theme) missing")
        XCTAssertTrue(b.isHittable, "settings.theme.\(theme) not hittable")
        XCTAssertEqual(b.label, theme.capitalized, "settings.theme.\(theme) label")
        XCTAssertGreaterThanOrEqual(b.frame.height, 43.5, "settings.theme.\(theme) under 44pt: \(b.frame)")
      }
      assertSelected(app, "system")
      // One row, equal widths, in order, under the server section.
      let frames = buttons.map(\.frame)
      for f in frames.dropFirst() {
        XCTAssertEqual(f.minY, frames[0].minY, accuracy: 0.5, "options not on one row: \(frames)")
        XCTAssertEqual(f.width, frames[0].width, accuracy: 1, "options not equal width: \(frames)")
      }
      for (a, b) in zip(frames, frames.dropFirst()) {
        XCTAssertLessThan(a.maxX, b.minX, "options out of order / overlapping: \(frames)")
      }
      XCTAssertGreaterThanOrEqual(frames[0].minY, el(app, "settings.test").frame.maxY - 1,
                                  "Appearance not below the server section")
      // Fills: selected = ink, others = surface; the sheet stays on background.
      waitForColors(app, [
        ("selected (System) fill", CGPoint(x: frames[0].minX + 5, y: frames[0].midY), palette.ink),
        ("Light option fill", CGPoint(x: frames[1].minX + 5, y: frames[1].midY), palette.surface),
        ("Forest option fill", CGPoint(x: frames[3].minX + 5, y: frames[3].midY), palette.surface),
        ("sheet background left of the options", CGPoint(x: 3, y: frames[0].midY), palette.background),
      ])
      snapshot("settings-appearance", appearance: appearance)
      app.terminate()
    }
  }

  // MARK: - #2 live switch, #3 forced schemes

  /// #2: tapping an option re-renders at once: the open Settings sheet, the Deck sheet under it, Study once closed.
  /// Forest, then Dark, then Light (device light) and back to System, checked by pixels at every step.
  @MainActor
  func testTheme_switchLiveAcrossSheets() {
    continueAfterFailure = true  // keep going so every stuck sheet/screen is captured
    resetThemeOnTeardown()
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock, theme: nil)
    openDeck(app)
    openSettings(app)

    for (theme, palette) in [("forest", Palette.forest), ("dark", .dark), ("light", .light)] {
      themeButton(app, theme).tap()
      assertSelected(app, theme)
      assertSettingsColors(app, palette, "\(theme) tapped: settings sheet")
      snapshot("settings-switched-\(theme)", appearance: .light)
      // Deck sheet that was under Settings: already themed when Settings closes (no reload needed).
      closeSettings(app)
      assertDeckColors(app, palette, "\(theme) tapped: deck sheet under settings")
      snapshot("deck-switched-\(theme)", appearance: .light)
      closeDeck(app)
      assertStudyColors(app, palette, "\(theme) tapped: study after closing the sheets")
      assertStatusBar(app, darkScheme: theme != "light", "\(theme) tapped")
      snapshot("study-switched-\(theme)", appearance: .light)
      openDeck(app)
      openSettings(app)
    }
    // Back to System with the device light → light palette.
    themeButton(app, "system").tap()
    assertSelected(app, "system")
    assertSettingsColors(app, .light, "back to system (device light)")
    snapshot("settings-switched-system", appearance: .light)
  }

  /// #3: device dark + Light → light palette, dark status bar text, light keyboard; device light + Dark → dark.
  /// Going back to System follows the device again; with System chosen, flipping the device appearance while the
  /// app runs re-themes it; with Light chosen, flipping it changes nothing.
  @MainActor
  func testTheme_forcedSchemesAndBackToSystem() {
    continueAfterFailure = true  // keep going so every stuck sheet/screen is captured
    resetThemeOnTeardown()
    for (device, forced) in [(XCUIDevice.Appearance.dark, "light"), (.light, "dark")] {
      XCUIDevice.shared.appearance = device
      let devicePalette: Palette = device == .dark ? .dark : .light
      let forcedPalette: Palette = forced == "dark" ? .dark : .light
      let app = launch(api: .mock, theme: nil)
      waitForLabel(el(app, "study.front"), Self.fixtures[0].front)
      assertStudyColors(app, devicePalette, "System on a \(device == .dark ? "dark" : "light") device")

      openDeck(app)
      openSettings(app)
      themeButton(app, forced).tap()
      assertSelected(app, forced)
      assertSettingsColors(app, forcedPalette, "\(forced) on the other device appearance")
      // Keyboard follows the forced scheme (#3).
      tapField(app, "settings.url")
      assertKeyboard(app, dark: forced == "dark", "\(forced) forced")
      snapshot("settings-forced-\(forced)-keyboard", appearance: device)
      closeSettings(app)
      closeDeck(app)
      assertStudyColors(app, forcedPalette, "study, \(forced) forced")
      assertStatusBar(app, darkScheme: forced == "dark", "\(forced) forced")
      snapshot("study-forced-\(forced)", appearance: device)

      // Flip the device while forced: nothing changes.
      XCUIDevice.shared.appearance = device == .dark ? .light : .dark
      Thread.sleep(forTimeInterval: 1)
      assertStudyColors(app, forcedPalette, "\(forced) forced after flipping the device")
      XCUIDevice.shared.appearance = device

      // Back to System → follows the device again, immediately.
      openDeck(app)
      openSettings(app)
      themeButton(app, "system").tap()
      assertSelected(app, "system")
      assertSettingsColors(app, devicePalette, "back to system after \(forced)")
      snapshot("settings-reopened-back-to-system-after-\(forced)", appearance: device)  // round 1 bug 1, repro D
      closeSettings(app)
      closeDeck(app)
      assertStudyColors(app, devicePalette, "study back on system after \(forced)")
      assertStatusBar(app, darkScheme: device == .dark, "back to system after \(forced)")
      snapshot("study-back-to-system-after-\(forced)", appearance: device)

      // System follows a live device change.
      let other: XCUIDevice.Appearance = device == .dark ? .light : .dark
      XCUIDevice.shared.appearance = other
      assertStudyColors(app, other == .dark ? .dark : .light, "system after the device switched appearance")
      XCUIDevice.shared.appearance = device
      app.terminate()
    }
  }

  /// #2 + #3, without relaunching: device light → Dark then System; device dark → Light then System. The open
  /// Settings sheet and the Deck sheet behind it (Settings swiped down) must both go back to the device appearance,
  /// not stay stuck on the forced scheme.
  @MainActor
  func testTheme_backToSystemInOpenSheets() {
    continueAfterFailure = true  // keep going so every stuck sheet/screen is captured
    resetThemeOnTeardown()
    for (device, forced) in [(XCUIDevice.Appearance.light, "dark"), (.dark, "light")] {
      XCUIDevice.shared.appearance = device
      let devicePalette: Palette = device == .dark ? .dark : .light
      let forcedPalette: Palette = forced == "dark" ? .dark : .light
      let app = launch(api: .mock, theme: nil)
      openDeck(app)
      openSettings(app)
      themeButton(app, forced).tap()
      assertSelected(app, forced)
      assertSettingsColors(app, forcedPalette, "\(forced) tapped in the open sheet")
      themeButton(app, "system").tap()
      assertSelected(app, "system")
      assertSettingsColors(app, devicePalette, "system after \(forced), settings still open")
      snapshot("settings-back-to-system-after-\(forced)", appearance: device)
      swipeSheetDown(app, from: el(app, "settings.title"))
      waitForAbsence(el(app, "settings.title"), "settings still open after swiping down")
      assertDeckColors(app, devicePalette, "deck behind settings, system after \(forced)")
      snapshot("deck-back-to-system-after-\(forced)", appearance: device)
      closeDeck(app)
      assertStudyColors(app, devicePalette, "study, system after \(forced)")
      app.terminate()
    }
  }

  /// #3 + #4: Forest picked from Settings on a light device forces a dark scheme (status bar, keyboard).
  @MainActor
  func testTheme_forestFromPickerForcesDarkScheme() {
    resetThemeOnTeardown()
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock, theme: nil)
    openDeck(app)
    openSettings(app)
    themeButton(app, "forest").tap()
    assertSelected(app, "forest")
    assertSettingsColors(app, .forest, "forest from the picker")
    tapField(app, "settings.url")
    assertKeyboard(app, dark: true, "forest from the picker")
    snapshot("settings-forest-keyboard", appearance: .light)
    closeSettings(app)
    closeDeck(app)
    assertStudyColors(app, .forest, "study, forest from the picker")
    assertStatusBar(app, darkScheme: true, "forest from the picker")
  }

  // MARK: - #5 persistence

  /// #5: Forest survives a relaunch (no launch argument): study opens in forest and the picker shows Forest; then
  /// Light survives too.
  @MainActor
  func testTheme_persistsAcrossRelaunch() {
    resetThemeOnTeardown()
    XCUIDevice.shared.appearance = .light
    for (theme, palette) in [("forest", Palette.forest), ("light", .light)] {
      if theme == "light" { XCUIDevice.shared.appearance = .dark }  // Light must still win on a dark device
      var app = launch(api: .mock, theme: nil)
      openDeck(app)
      openSettings(app)
      themeButton(app, theme).tap()
      assertSelected(app, theme)
      app.terminate()

      app = launch(api: .mock, theme: nil)
      waitForLabel(el(app, "study.front"), Self.fixtures[0].front)
      assertStudyColors(app, palette, "\(theme) after relaunch")
      snapshot("study-relaunched-\(theme)", appearance: XCUIDevice.shared.appearance)
      openDeck(app)
      openSettings(app)
      assertSelected(app, theme)
      app.terminate()
    }
  }

  // MARK: - #4 + #6 forest on every screen via `-theme forest`

  /// #6: `-theme forest` starts in forest. #4: forest palette on Study (front, revealed, caught up), Deck, Editor
  /// (keyboard dark), Settings (Forest selected), on a light and a dark device. The argument doesn't persist.
  @MainActor
  func testTheme_forestEveryScreen() {
    resetThemeOnTeardown()
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      var app = launch(api: .mock, theme: "forest")
      let p = Palette.forest

      // Study front.
      waitForLabel(el(app, "study.front"), Self.fixtures[0].front)
      assertStudyColors(app, p, "study front")
      assertStatusBar(app, darkScheme: true, "-theme forest")
      assertTextColor(app, "study.front", p.ink, background: p.background)
      assertTextColor(app, "study.remaining", p.secondaryInk, background: p.background)
      snapshot("study-forest", appearance: appearance)

      // Revealed.
      el(app, "study.card").tap()
      XCTAssertTrue(el(app, "study.rate.good").waitForExistence(timeout: 5), "ratings missing after reveal")
      assertStudyColors(app, p, "study revealed")
      assertTextColor(app, "study.back", p.secondaryInk, background: p.background)
      snapshot("study-revealed-forest", appearance: appearance)

      // Deck.
      openDeck(app)
      assertDeckColors(app, p, "deck")
      snapshot("deck-forest", appearance: appearance)

      // Editor (edit), then new card with the keyboard up.
      deckRow(app, Self.mockIDs[2]).tap()
      waitForLabel(el(app, "editor.title"), "Edit card")
      assertEditorColors(app, p, "editor (edit)")
      snapshot("editor-forest", appearance: appearance)
      el(app, "editor.close").tap()
      waitForAbsence(el(app, "editor.title"))
      el(app, "deck.add").tap()
      waitForLabel(el(app, "editor.title"), "New card")
      assertKeyboard(app, dark: true, "-theme forest, new card")
      snapshot("editor-new-forest", appearance: appearance)
      el(app, "editor.close").tap()
      waitForAbsence(el(app, "editor.title"))

      // Settings: Forest is the selected option.
      openSettings(app)
      assertSelected(app, "forest")
      assertSettingsColors(app, p, "settings")
      snapshot("settings-forest", appearance: appearance)
      closeSettings(app)
      closeDeck(app)

      // Caught up.
      for card in Self.fixtures.dropFirst() {
        if el(app, "study.rate.good").exists { el(app, "study.rate.good").tap() }
        waitForLabel(el(app, "study.front"), card.front)
        el(app, "study.reveal").tap()
        XCTAssertTrue(el(app, "study.rate.good").waitForExistence(timeout: 5))
      }
      el(app, "study.rate.good").tap()
      waitForLabel(el(app, "study.message"), "All caught up")
      assertStudyColors(app, p, "caught up")
      assertTextColor(app, "study.message", p.ink, background: p.background)
      snapshot("study-caught-up-forest", appearance: appearance)
      app.terminate()

      // The argument is not written to the stored value: a plain relaunch is back on System.
      app = launch(api: .mock, theme: nil)
      waitForLabel(el(app, "study.front"), Self.fixtures[0].front)
      assertStudyColors(app, appearance == .dark ? .dark : .light, "relaunch without -theme")
      app.terminate()
    }
  }

  /// #6 + gallery: `LA_CARTE_SCREEN=design-system` with `-theme forest` renders the gallery in forest.
  @MainActor
  func testDesignSystem_forest() {
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .mock, screen: "design-system", theme: "forest")
      let button = app.buttons["gallery.button.plus"]
      XCTAssertTrue(button.waitForExistence(timeout: 5), "gallery missing")
      scrollIntoView(app, button)
      let window = app.windows.firstMatch.frame
      let f = button.frame
      waitForColors(app, [
        ("gallery background left edge", CGPoint(x: 3, y: f.midY), Palette.forest.background),
        ("gallery background bottom", CGPoint(x: 8, y: window.maxY - 8), Palette.forest.background),
        ("gallery circle button fill", CGPoint(x: f.midX - f.width / 2 + 7, y: f.midY), Palette.forest.surface),
      ])
      assertStatusBar(app, darkScheme: true, "gallery -theme forest")
      snapshot("design-system-forest", appearance: appearance)
      app.terminate()
    }
  }

  // MARK: - accessibility XL

  /// At accessibility XL the four options stay inside the window, don't overlap and keep their full label; Forest
  /// can be picked; study in forest at XL stays readable.
  @MainActor
  func testTheme_accessibilityXL() {
    resetThemeOnTeardown()
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      var app = launch(api: .mock, arguments: accessibilityXLArguments, theme: nil)
      openDeck(app)
      openSettings(app)
      let forest = themeButton(app, "forest")
      if !forest.isHittable { app.swipeUp() }
      XCTAssertTrue(forest.isHittable, "settings.theme.forest not reachable at XL")
      let window = app.windows.firstMatch.frame
      let frames = Self.themes.map { themeButton(app, $0).frame }
      for (theme, f) in zip(Self.themes, frames) {
        XCTAssertTrue(window.insetBy(dx: -0.5, dy: -0.5).contains(f), "settings.theme.\(theme) clipped at XL: \(f)")
        XCTAssertGreaterThanOrEqual(f.height, 43.5, "settings.theme.\(theme) under 44pt at XL")
      }
      for (i, a) in frames.enumerated() {
        for b in frames[(i + 1)...] {
          let o = a.intersection(b)
          XCTAssertTrue(o.isNull || o.width < 1 || o.height < 1, "theme options overlap at XL: \(a) / \(b)")
        }
      }
      assertSelected(app, "system")
      snapshot("settings-appearance-xl", appearance: appearance)
      forest.tap()
      assertSelected(app, "forest")
      snapshot("settings-forest-xl", appearance: appearance)
      themeButton(app, "system").tap()
      assertSelected(app, "system")
      app.terminate()

      app = launch(api: .mock, arguments: accessibilityXLArguments, theme: "forest")
      waitForLabel(el(app, "study.front"), Self.fixtures[0].front)
      assertStudyColors(app, .forest, "study forest XL")
      assertTextsReadable(in: app)
      snapshot("study-forest-xl", appearance: appearance)
      el(app, "study.card").tap()
      XCTAssertTrue(el(app, "study.rate.good").waitForExistence(timeout: 5))
      snapshot("study-revealed-forest-xl", appearance: appearance)
      app.terminate()
    }
  }

  // MARK: - live API (scripts/e2e.sh)

  /// Forest against the real API: study and the seeded deck render on the forest palette. Read-only.
  @MainActor
  func testTheme_forestDeck_liveAPI() throws {
    guard let url = ProcessInfo.processInfo.environment["LA_CARTE_API_URL"], !url.isEmpty else {
      throw XCTSkip("LA_CARTE_API_URL not set — run scripts/e2e.sh")
    }
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .live(url), theme: "forest")
    XCTAssertTrue(el(app, "study.deck").waitForExistence(timeout: 15))
    assertStudyColors(app, .forest, "live study")
    snapshot("study-live-forest", appearance: .light)
    openDeck(app)
    let anyRow = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'deck.row.'"))
      .firstMatch
    XCTAssertTrue(anyRow.waitForExistence(timeout: 10), "no seeded rows in the live deck")
    assertDeckColors(app, .forest, "live deck")
    snapshot("deck-live-forest", appearance: .light)
  }

  // MARK: - Helpers

  /// Puts the stored theme back to System after the test, pass or fail.
  @MainActor
  private func resetThemeOnTeardown() {
    addTeardownBlock { @MainActor [self] in
      XCUIDevice.shared.appearance = .light
      let app = launch(api: .mock, theme: nil)
      openDeck(app)
      openSettings(app)
      themeButton(app, "system").tap()
      assertSelected(app, "system")
      app.terminate()
    }
  }

  @MainActor
  private func themeButton(_ app: XCUIApplication, _ theme: String) -> XCUIElement {
    el(app, "settings.theme.\(theme)")
  }

  @MainActor
  private func deckRow(_ app: XCUIApplication, _ id: String) -> XCUIElement { el(app, "deck.row.\(id.uppercased())") }

  /// Exactly `theme` carries the selected trait.
  @MainActor
  private func assertSelected(_ app: XCUIApplication, _ theme: String, file: StaticString = #filePath, line: UInt = #line) {
    let deadline = Date().addingTimeInterval(3)
    func state() -> [String] { Self.themes.filter { themeButton(app, $0).isSelected } }
    while state() != [theme], Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    XCTAssertEqual(state(), [theme], "selected theme options", file: file, line: line)
  }

  @MainActor
  private func openDeck(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let button = el(app, "study.deck")
    XCTAssertTrue(button.waitForExistence(timeout: 10), "study.deck missing", file: file, line: line)
    button.tap()
    waitForDeckTitle(app, file: file, line: line)
  }

  @MainActor
  private func closeDeck(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    swipeSheetDown(app, from: deckTitle(app))
    waitForAbsence(deckTitle(app), "deck still open", file: file, line: line)
  }

  @MainActor
  private func openSettings(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let gear = el(app, "deck.settings")
    XCTAssertTrue(gear.waitForExistence(timeout: 5), "deck.settings missing", file: file, line: line)
    gear.tap()
    waitForLabel(el(app, "settings.title"), "Settings", file: file, line: line)
  }

  @MainActor
  private func closeSettings(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    el(app, "settings.close").tap()
    waitForAbsence(el(app, "settings.title"), "settings still open", file: file, line: line)
  }

  @MainActor
  private func tapField(_ app: XCUIApplication, _ id: String) {
    el(app, id).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no keyboard after tapping \(id)")
  }

  private static func close(_ c: RGB, _ e: RGB, tolerance: Int = 4) -> Bool {
    abs(c.0 - e.0) <= tolerance && abs(c.1 - e.1) <= tolerance && abs(c.2 - e.2) <= tolerance
  }

  /// Polls screenshots for up to `timeout` until every point has its expected color (re-render + sheet animations).
  @MainActor
  private func waitForColors(_ app: XCUIApplication, _ checks: [(String, CGPoint, RGB)], context: String = "",
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

  @MainActor
  private func assertStudyColors(_ app: XCUIApplication, _ p: Palette, _ context: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
    let deck = el(app, "study.deck")
    XCTAssertTrue(deck.waitForExistence(timeout: 10), "study.deck missing", file: file, line: line)
    let window = app.windows.firstMatch.frame, d = deck.frame
    waitForColors(app, [
      ("study background top-left (status bar area)", CGPoint(x: 3, y: 3), p.background),
      ("study background left edge", CGPoint(x: 3, y: window.midY), p.background),
      ("study background right edge", CGPoint(x: window.maxX - 3, y: window.height * 0.35), p.background),
      ("study background bottom-left", CGPoint(x: 8, y: window.maxY - 8), p.background),
      ("study.deck circle fill", CGPoint(x: d.minX + 7, y: d.midY), p.surface),
    ], context: context, file: file, line: line)
  }

  @MainActor
  private func assertDeckColors(_ app: XCUIApplication, _ p: Palette, _ context: String,
                                file: StaticString = #filePath, line: UInt = #line) {
    let window = app.windows.firstMatch.frame
    // Spec 009a: large navigation title + system search field and glass toolbar buttons (system materials).
    let title = deckTitleText(app).frame
    let firstRow = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'deck.row.'"))
      .firstMatch
    XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "no deck rows", file: file, line: line)
    let r = firstRow.frame
    waitForColors(app, [
      ("deck background left of the title", CGPoint(x: 4, y: title.midY), p.background),
      ("deck background near the bottom edge", CGPoint(x: window.midX, y: window.maxY - 4), p.background),
      ("deck background left of a row", CGPoint(x: r.minX / 2, y: r.midY), p.background),
      ("deck row fill", CGPoint(x: r.minX + 6, y: r.midY), p.surface),
    ], context: context, file: file, line: line)
  }

  @MainActor
  private func assertEditorColors(_ app: XCUIApplication, _ p: Palette, _ context: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
    let window = app.windows.firstMatch.frame
    let title = el(app, "editor.title").frame, close = el(app, "editor.close").frame, front = el(app, "editor.front").frame
    waitForColors(app, [
      ("editor background left of the title", CGPoint(x: 4, y: title.midY), p.background),
      ("editor background between title and buttons", CGPoint(x: window.midX, y: title.midY), p.background),
      ("editor background left of the front field", CGPoint(x: 4, y: front.midY), p.background),
      ("editor.close circle fill", CGPoint(x: close.minX + 7, y: close.midY), p.surface),
    ], context: context, file: file, line: line)
  }

  @MainActor
  private func assertSettingsColors(_ app: XCUIApplication, _ p: Palette, _ context: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
    let window = app.windows.firstMatch.frame
    let url = el(app, "settings.url").frame, close = el(app, "settings.close").frame
    let selected = Self.themes.map { themeButton(app, $0) }.first { $0.isSelected }?.frame ?? .zero
    let unselected = Self.themes.map { themeButton(app, $0) }.first { !$0.isSelected }!.frame
    waitForColors(app, [
      ("settings background left of the URL row", CGPoint(x: 4, y: url.midY), p.background),
      ("settings background near the bottom", CGPoint(x: window.midX, y: window.maxY - 60), p.background),
      ("settings URL row fill", CGPoint(x: url.maxX - 4, y: url.midY), p.surface),
      ("settings.close circle fill", CGPoint(x: close.minX + 7, y: close.midY), p.surface),
      ("selected option fill (ink)", CGPoint(x: selected.minX + 5, y: selected.midY), p.ink),
      ("unselected option fill (surface)", CGPoint(x: unselected.minX + 5, y: unselected.midY), p.surface),
    ], context: context, file: file, line: line)
  }

  /// The glyph pixel furthest from the background along the element's middle should be the token color.
  @MainActor
  private func assertTextColor(_ app: XCUIApplication, _ id: String, _ expected: RGB, background: RGB,
                               file: StaticString = #filePath, line: UInt = #line) {
    let element = el(app, id)
    XCTAssertTrue(element.waitForExistence(timeout: 5), "\(id) missing", file: file, line: line)
    let f = element.frame
    let pixels = Pixels(XCUIScreen.main.screenshot(), pointWidth: app.windows.firstMatch.frame.width)
    var best = background, bestDistance = -1
    for y in stride(from: f.minY + f.height * 0.3, through: f.minY + f.height * 0.7, by: 0.5) {
      for x in stride(from: f.minX, to: f.maxX, by: 0.34) {
        let c = pixels.color(at: CGPoint(x: x, y: y))
        let d = abs(c.0 - background.0) + abs(c.1 - background.1) + abs(c.2 - background.2)
        if d > bestDistance { bestDistance = d; best = c }
      }
    }
    XCTAssertTrue(Self.close(best, expected, tolerance: 8), "\(id) text color \(best), expected \(expected)",
                  file: file, line: line)
  }

  /// Status bar glyphs (time, top-left): light text on a dark scheme, dark text on a light one.
  @MainActor
  private func assertStatusBar(_ app: XCUIApplication, darkScheme: Bool, _ context: String,
                               file: StaticString = #filePath, line: UInt = #line) {
    let width = app.windows.firstMatch.frame.width
    let bottom = min(50, el(app, "study.deck").exists ? el(app, "study.deck").frame.minY - 2 : 50)
    let deadline = Date().addingTimeInterval(3)
    var minL = 255.0, maxL = 0.0
    repeat {
      let pixels = Pixels(XCUIScreen.main.screenshot(), pointWidth: width)
      minL = 255; maxL = 0
      for y in stride(from: 8.0, to: bottom, by: 0.5) {
        for x in stride(from: 16.0, to: 140.0, by: 0.5) {
          let c = pixels.color(at: CGPoint(x: x, y: y))
          let l = 0.299 * Double(c.0) + 0.587 * Double(c.1) + 0.114 * Double(c.2)
          minL = min(minL, l); maxL = max(maxL, l)
        }
      }
      if darkScheme ? maxL > 200 : minL < 80 { return }
      Thread.sleep(forTimeInterval: 0.2)
    } while Date() < deadline
    XCTFail("[\(context)] status bar text not \(darkScheme ? "light (dark scheme)" : "dark (light scheme)"): "
      + "luminance \(Int(minL))…\(Int(maxL))", file: file, line: line)
  }

  /// Average luminance of the keyboard: dark keyboard < 110, light keyboard > 150.
  @MainActor
  private func assertKeyboard(_ app: XCUIApplication, dark: Bool, _ context: String,
                              file: StaticString = #filePath, line: UInt = #line) {
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "[\(context)] no keyboard", file: file, line: line)
    Thread.sleep(forTimeInterval: 0.8)  // keyboard slide-in
    let f = keyboard.frame
    let pixels = Pixels(XCUIScreen.main.screenshot(), pointWidth: app.windows.firstMatch.frame.width)
    var total = 0.0, n = 0.0
    for y in stride(from: f.minY + 4, to: f.maxY - 4, by: 4) {
      for x in stride(from: f.minX + 4, to: f.maxX - 4, by: 4) {
        let c = pixels.color(at: CGPoint(x: x, y: y))
        total += 0.299 * Double(c.0) + 0.587 * Double(c.1) + 0.114 * Double(c.2)
        n += 1
      }
    }
    let avg = n > 0 ? total / n : 0
    XCTAssertTrue(dark ? avg < 110 : avg > 150, "[\(context)] keyboard average luminance \(Int(avg)), expected a "
      + (dark ? "dark" : "light") + " keyboard", file: file, line: line)
  }
}
