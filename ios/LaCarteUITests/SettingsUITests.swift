import XCTest

/// Spec 003: server settings (URL + token), "Test connection", persistence across launches.
///
/// Stub checks launch with `APIMode.stored` (no API env at all) and type a `StubAPIServer` URL into Settings, so
/// they go through the same path as a real phone: stored URL + Keychain token → live `APIClient`.
final class SettingsUITests: SettingsTestCase {
  // MARK: - #1 open from the deck, #8 close by button and by swipe

  /// #1: `deck.settings` (gear) sits next to `deck.add` in the title row; it opens the sheet with title, URL field,
  /// secure token field, "Test connection" and close. #8: close button and swipe-down both return to the deck.
  @MainActor
  func testSettings_openFromDeckAndClose() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock)
    openDeck(app)
    assertGearInTitleRow(app)
    snapshot("deck-with-settings", appearance: .light)

    openSettings(app)
    assertSettingsScreen(app)
    assertSettingsColors(app, appearance: .light)
    XCTAssertFalse(statusText(app).exists && !statusText(app).label.isEmpty,
                   "settings.status shows '\(statusText(app).label)' before any check")
    snapshot("settings", appearance: .light)

    // #8: close button.
    el(app, "settings.close").tap()
    waitForAbsence(sheetBar(app, "Settings"), "settings still open after settings.close")
    waitForDeckTitle(app)

    // #8: swipe down.
    openSettings(app)
    swipeSheetDown(app, from: sheetBar(app, "Settings"))
    waitForAbsence(sheetBar(app, "Settings"), "settings still open after swiping down")
    waitForDeckTitle(app)
  }

  /// Design checklist: 44pt hit area. "Test connection" is the screen's only action.
  @MainActor
  func testSettings_testButtonHitArea() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock)
    openDeck(app)
    openSettings(app)
    let test = el(app, "settings.test")
    let b = test.frame
    // 009b: a Form row button; the whole row (≥ 44pt) is the target. Tap near its bottom, then (after editing to
    // clear the status) near its top.
    XCTAssertGreaterThanOrEqual(b.height, 43.5, "settings.test row under 44pt: \(b)")
    test.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: b.height / 2 - 4)).tap()
    waitForLabel(statusText(app), "Connected · 3 cards", timeout: 3)
    let token = el(app, "settings.token")
    tapEnd(token)
    token.typeText("x")
    assertStatusCleared(app, "after editing the token")
    test.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: -(b.height / 2 - 4))).tap()
    waitForLabel(statusText(app), "Connected · 3 cards", timeout: 3)
  }

  // MARK: - #4 test connection

  /// #4 (mock): "Connected · 3 cards" with the in-memory deck.
  @MainActor
  func testSettings_testConnectionMock() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock)
    openDeck(app)
    openSettings(app)
    el(app, "settings.test").tap()
    waitForLabel(statusText(app), "Connected · 3 cards")
    assertStatusBelowTest(app)
    snapshot("settings-connected", appearance: .light)
  }

  // MARK: - #2/#3/#6 persistence across launches (+ spec 004 #5 theme)

  /// URL, token (spec 003) and theme (spec 004 #5) picked in Settings survive a relaunch with no API env and no
  /// `-theme` argument: the first requests after launch go to the stored URL with the stored token, study opens in
  /// Forest, and Settings shows them again (token masked, Forest selected). Puts the theme back to System.
  @MainActor
  func testSettings_persistAcrossRelaunch() throws {
    XCUIDevice.shared.appearance = .light
    addTeardownBlock { @MainActor [self] in  // the test resets the theme itself; only a failure leaves Forest
      guard testRun?.hasSucceeded == false else { return }
      let app = launch(api: .mock, theme: nil)
      openDeck(app)
      openSettings(app)
      themeSegment(app, "System").tap()
      app.terminate()
    }
    let deck = StubDeck([card("b1", "persist", "stays")])
    let server = try startStub(deck, token: Self.goodToken)
    var app = launch(api: .stored, theme: nil)
    openDeck(app)
    openSettings(app)
    setText(app, "settings.url", server.url)
    setText(app, "settings.token", Self.goodToken, secure: true)
    themeSegment(app, "Forest").tap()
    XCTAssertTrue(poll(timeout: 3) { themeSegment(app, "Forest").isSelected }, "Forest not selected after tapping it")
    el(app, "settings.close").tap()
    waitForAbsence(sheetBar(app, "Settings"))
    app.terminate()

    let before = server.requests.count
    app = launch(api: .stored, theme: nil)
    waitForLabel(el(app, "study.front"), "persist", timeout: 15)
    let afterLaunch = server.requests[before...]
    XCTAssertFalse(afterLaunch.isEmpty, "relaunched app sent nothing to the stored URL")
    XCTAssertTrue(afterLaunch.allSatisfy { $0.headers["authorization"] == "Bearer \(Self.goodToken)" },
                  "requests after relaunch without the stored token: \(afterLaunch.map { $0.headers["authorization"] ?? "none" })")
    let window = app.windows.firstMatch.frame
    waitForColors(app, [("study background (forest after relaunch)", CGPoint(x: 3, y: window.midY), Palette.forest.background)])
    snapshot("study-relaunched-forest", appearance: .light)
    openDeck(app)
    openSettings(app)
    XCTAssertEqual(fieldText(app, "settings.url"), server.url, "stored URL not shown after relaunch")
    let token = el(app, "settings.token")
    let masked = token.value as? String ?? ""
    XCTAssertEqual(masked, String(repeating: "•", count: Self.goodToken.count),
                   "stored token not shown masked (one dot per character) after relaunch")
    assertTokenNotOnScreen(app, Self.goodToken)
    XCTAssertEqual(["System", "Light", "Dark", "Forest"].filter { themeSegment(app, $0).isSelected }, ["Forest"],
                   "stored theme not selected after relaunch")
    snapshot("settings-relaunched", appearance: .light)
    themeSegment(app, "System").tap()
    XCTAssertTrue(poll(timeout: 3) { themeSegment(app, "System").isSelected }, "System not selected after tapping it")
    server.stop()
  }

  // MARK: - 016b Ask AI app picker

  /// 016b #1/#2: the picker lists the six apps, defaults to Vibe, and a pick survives a relaunch.
  /// Opening other apps can't be checked on the simulator: left for the user on device (016b #7).
  @MainActor
  func testSettings_aiAppPicker() {
    for appearance in [XCUIDevice.Appearance.light, .dark] {
      XCUIDevice.shared.appearance = appearance
      var app = launch(api: .mock, theme: nil)
      openDeck(app)
      openSettings(app)
      let picker = el(app, "settings.aiApp")
      scrollIntoView(app, picker)
      XCTAssertTrue(picker.label.contains("Vibe") || (picker.value as? String) == "Vibe",
                    "default isn't Vibe: \(picker.label) / \(String(describing: picker.value))")
      picker.tap()
      for title in ["Vibe", "Claude", "ChatGPT", "Perplexity", "Grok", "Copy only"] {
        XCTAssertTrue(app.buttons[title].waitFor(timeout: 5), "no \(title) in the picker")
      }
      Thread.sleep(forTimeInterval: 0.5)
      snapshot("settings-ai-app", appearance: appearance)
      app.buttons["Grok"].tap()
      XCTAssertTrue(poll(timeout: 3) { (el(app, "settings.aiApp").value as? String) == "Grok" || el(app, "settings.aiApp").label.contains("Grok") })
      app.terminate()
      app = launch(api: .mock, theme: nil)
      openDeck(app)
      openSettings(app)
      scrollIntoView(app, el(app, "settings.aiApp"))
      let after = el(app, "settings.aiApp")
      XCTAssertTrue((after.value as? String) == "Grok" || after.label.contains("Grok"), "Grok not kept after relaunch")
      after.tap()
      app.buttons["Vibe"].tap()  // back to the default
      XCTAssertTrue(poll(timeout: 3) { (el(app, "settings.aiApp").value as? String) == "Vibe" || el(app, "settings.aiApp").label.contains("Vibe") })
      app.terminate()
    }
  }

  // MARK: - #9 live API (scripts/e2e.sh)

  /// #9: no launch env at all; type the e2e URL + token → "Connected · 2 cards"; token "wrong" → "Wrong token";
  /// `http://127.0.0.1:9` → "Can't reach server". Then back to the real values: study shows the seeded cards.
  @MainActor
  func testSettings_setupOnDevice_liveAPI() throws {
    guard let url = ProcessInfo.processInfo.environment["LA_CARTE_API_URL"], !url.isEmpty,
          let token = ProcessInfo.processInfo.environment["LA_CARTE_API_TOKEN"], !token.isEmpty else {
      throw XCTSkip("LA_CARTE_API_URL / LA_CARTE_API_TOKEN not set — run scripts/e2e.sh")
    }
    XCUIDevice.shared.appearance = .light
    var app = launch(api: .stored)
    openDeck(app)
    openSettings(app)
    setText(app, "settings.url", url)
    setText(app, "settings.token", token, secure: true)
    el(app, "settings.test").tap()
    waitForLabel(statusText(app), "Connected · 2 cards")
    snapshot("settings-live-connected", appearance: .light)

    setText(app, "settings.token", "wrong", secure: true)
    el(app, "settings.test").tap()
    waitForLabel(statusText(app), "Wrong token")
    snapshot("settings-live-wrong-token", appearance: .light)

    setText(app, "settings.token", token, secure: true)
    setText(app, "settings.url", unreachableAPIURL)
    el(app, "settings.test").tap()
    waitForLabel(statusText(app), "Can't reach server", timeout: 20)
    snapshot("settings-live-unreachable", appearance: .light)

    setText(app, "settings.url", url)
    el(app, "settings.test").tap()
    waitForLabel(statusText(app), "Connected · 2 cards")
    el(app, "settings.close").tap()
    waitForAbsence(sheetBar(app, "Settings"))
    swipeSheetDown(app, from: deckTitle(app))
    waitForAbsence(deckTitle(app))
    waitForLabel(el(app, "study.front"), "greeting")
    waitForLabel(el(app, "study.remaining"), "2 to review")
    snapshot("study-live-after-settings", appearance: .light)

    // Same values after a relaunch with no env (the real phone path).
    app.terminate()
    app = launch(api: .stored)
    waitForLabel(el(app, "study.front"), "greeting", timeout: 15)
  }

  // MARK: - Helpers

  /// Spec 009a #2: gear and add are system toolbar buttons on one line in the top-right, gear left of add,
  /// both above the large "Cards" title.
  @MainActor
  private func assertGearInTitleRow(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let title = deckTitleText(app).frame, add = el(app, "deck.add").frame, gear = el(app, "deck.settings").frame
    let window = app.windows.firstMatch.frame
    // System toolbar glass buttons (36pt, hit area extended by iOS; accepted by 009b QA): no 44pt frame check.
    for id in ["deck.settings", "deck.add"] {
      XCTAssertTrue(el(app, id).exists && el(app, id).isHittable, "\(id) missing or not hittable", file: file, line: line)
    }
    XCTAssertEqual(gear.midY, add.midY, accuracy: 0.5, "gear and add not on one line", file: file, line: line)
    XCTAssertLessThan(gear.maxX, add.minX + 1, "gear not left of add", file: file, line: line)
    XCTAssertGreaterThan(add.maxX, window.width - 30, "deck.add not at the right edge: \(add)", file: file, line: line)
    XCTAssertTrue(gear.intersection(title).isNull, "gear overlaps the title", file: file, line: line)
  }

  /// Spec 009b #4: native sheet. Inline nav title "Settings", toolbar close (`settings.close`) at the leading edge
  /// of the bar; Form rows URL, token, test, in that order, under the bar; segmented theme picker below.
  @MainActor
  private func assertSettingsScreen(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let window = app.windows.firstMatch.frame
    let bar = sheetBar(app, "Settings"), url = el(app, "settings.url"), token = el(app, "settings.token")
    let test = el(app, "settings.test"), close = el(app, "settings.close")
    for e in [url, token, test, close] {
      XCTAssertTrue(e.waitFor(timeout: 5), "\(e.identifier) missing", file: file, line: line)
    }
    XCTAssertTrue(bar.exists, "no navigation bar titled Settings", file: file, line: line)
    XCTAssertEqual(url.elementType, .textField, "settings.url is not a text field", file: file, line: line)
    let shown = token.value as? String ?? ""
    XCTAssertTrue(shown.allSatisfy { $0 == "•" }, "settings.token not masked at rest: '\(shown)'", file: file, line: line)
    XCTAssertEqual(test.label, "Test connection", file: file, line: line)
    XCTAssertTrue(test.isHittable, "settings.test not hittable", file: file, line: line)
    if fieldText(app, "settings.url").isEmpty {
      XCTAssertEqual(url.placeholderValue, Self.urlPlaceholder, "settings.url placeholder", file: file, line: line)
    }
    for label in ["System", "Light", "Dark", "Forest"] {
      XCTAssertTrue(themeSegment(app, label).exists, "theme segment \(label) missing", file: file, line: line)
    }
    let t = sheetTitle(app, "Settings").frame, c = close.frame, u = url.frame, k = token.frame, b = test.frame
    // System toolbar glass button: 36pt frame, hit area extended by iOS (009b: native toolbar).
    XCTAssertGreaterThanOrEqual(c.width, 35.5, "settings.close smaller than a system toolbar button: \(c)", file: file, line: line)
    XCTAssertGreaterThanOrEqual(c.height, 35.5, "settings.close smaller than a system toolbar button: \(c)", file: file, line: line)
    XCTAssertLessThan(c.minX, window.width / 4, "settings.close not in the leading toolbar slot: \(c)", file: file, line: line)
    XCTAssertEqual(t.midX, window.midX, accuracy: 4, "inline title not centred: \(t)", file: file, line: line)
    XCTAssertEqual(t.midY, c.midY, accuracy: 3, "title not on the close button's line: \(t) / \(c)", file: file, line: line)
    XCTAssertGreaterThanOrEqual(u.minY, max(t.maxY, c.maxY) - 1, "URL field not under the bar", file: file, line: line)
    XCTAssertGreaterThanOrEqual(k.minY, u.maxY - 1, "token field not under the URL field", file: file, line: line)
    XCTAssertGreaterThanOrEqual(b.minY, k.maxY - 1, "test button not under the token field", file: file, line: line)
    XCTAssertGreaterThan(themeSegment(app, "Forest").frame.minY, b.maxY, "theme picker not under Server", file: file, line: line)
    // 008 #16: the masked token is a text inside a tappable row; the 44pt eye button spans the row's height.
    let row = k.union(el(app, "settings.token.reveal").frame)
    // 009b: native Form rows (≥ 44pt by the system); the URL element is the text itself, the token row is the
    // text + the 44pt eye.
    XCTAssertGreaterThanOrEqual(row.height, 43.5, "settings.token row under 44pt: \(row)", file: file, line: line)
    XCTAssertGreaterThanOrEqual(k.minY - u.maxY, 12, "URL and token rows too tight (row < 44pt?)", file: file, line: line)
    for (id, f) in [("settings.url", u), ("settings.token row", row)] {
      XCTAssertGreaterThanOrEqual(f.minX, 12, "\(id) not inset: \(f)", file: file, line: line)
    }
  }

  @MainActor
  private func assertStatusBelowTest(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let s = statusText(app).frame, b = el(app, "settings.test").frame
    XCTAssertGreaterThanOrEqual(s.minY, b.maxY - 1, "status not under the test button: \(s) / \(b)", file: file, line: line)
  }

  /// Pixel checks: sheet background is `Theme.background`, fields sit on `surface`, the test button text is ink
  /// (not the default blue).
  @MainActor
  private func assertSettingsColors(_ app: XCUIApplication, appearance: XCUIDevice.Appearance,
                                    file: StaticString = #filePath, line: UInt = #line) {
    let p = Palette.of(appearance)
    let window = app.windows.firstMatch.frame
    let url = el(app, "settings.url").frame, token = el(app, "settings.token").frame
    waitForColors(app, [
      ("sheet background left of the URL row", CGPoint(x: 4, y: url.midY), p.background),
      ("sheet background between test and bottom", CGPoint(x: window.midX, y: window.maxY - 60), p.background),
      ("URL row fill", CGPoint(x: url.maxX - 4, y: url.midY), p.surface),
      ("token row fill", CGPoint(x: url.maxX - 4, y: token.midY), p.surface),  // row spans the URL row's width
    ], timeout: 0, file: file, line: line)
    assertNotTintedBlue(app, "settings.test", file: file, line: line)
  }
}
