import XCTest

/// Spec 003: server settings (URL + token), "Test connection", persistence across launches.
///
/// Stub checks launch with `APIMode.stored` (no API env at all) and type a `StubAPIServer` URL into Settings, so
/// they go through the same path as a real phone: stored URL + Keychain token → live `APIClient`.
final class SettingsUITests: XCTestCase {
  static let appearances: [XCUIDevice.Appearance] = [.light, .dark]
  static let urlPlaceholder = "Server URL"
  static let goodToken = "qa-good-token"

  override func setUp() {
    continueAfterFailure = false
  }

  // MARK: - #1 open from the deck, #8 close by button and by swipe

  /// #1: `deck.settings` (gear) sits next to `deck.add` in the title row; it opens the sheet with title, URL field,
  /// secure token field, "Test connection" and close. #8: close button and swipe-down both return to the deck.
  @MainActor
  func testSettings_openFromDeckAndClose() {
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .mock)
      openDeck(app)
      assertGearInTitleRow(app)
      snapshot("deck-with-settings", appearance: appearance)

      openSettings(app)
      assertSettingsScreen(app)
      assertSettingsColors(app, appearance: appearance)
      XCTAssertFalse(statusText(app).exists && !statusText(app).label.isEmpty,
                     "settings.status shows '\(statusText(app).label)' before any check")
      snapshot("settings", appearance: appearance)

      // #8: close button.
      el(app, "settings.close").tap()
      waitForAbsence(sheetBar(app, "Settings"), "settings still open after settings.close")
      waitForDeckTitle(app)

      // #8: swipe down.
      openSettings(app)
      swipeSheetDown(app, from: sheetBar(app, "Settings"))
      waitForAbsence(sheetBar(app, "Settings"), "settings still open after swiping down")
      waitForDeckTitle(app)
      app.terminate()
    }
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

  /// #4: "Checking…" while `GET /stats` is in flight, then "Connected · N cards"; the request carries the typed
  /// token. #5: editing the URL, then the token, clears the status.
  @MainActor
  func testSettings_checkingThenConnectedThenEditClears() throws {
    XCUIDevice.shared.appearance = .light
    let deck = StubDeck([card("a1", "alpha", "one"), card("a2", "bravo", "two")])
    let server = try startStub(deck, token: Self.goodToken, statsDelay: 5)
    let app = launch(api: .stored)
    openDeck(app)
    openSettings(app)
    setText(app, "settings.url", server.url)
    setText(app, "settings.token", Self.goodToken, secure: true)

    el(app, "settings.test").tap()
    waitForLabel(statusText(app), "Checking…", timeout: 4)
    snapshot("settings-checking", appearance: .light)
    waitForLabel(statusText(app), "Connected · 2 cards")
    let stats = server.requests.filter { StubDeck.route($0.path) == "/stats" }
    XCTAssertFalse(stats.isEmpty, "no GET /stats sent to the URL typed in Settings")
    XCTAssertEqual(stats.last?.headers["authorization"], "Bearer \(Self.goodToken)", "token typed in Settings not sent")

    // #5: editing the URL clears the status.
    let urlField = el(app, "settings.url")
    tapEnd(urlField)
    urlField.typeText(XCUIKeyboardKey.delete.rawValue)
    assertStatusCleared(app, "after editing the URL")
    urlField.typeText(String(server.url.last!))
    XCTAssertEqual(fieldText(app, "settings.url"), server.url)

    // Check again, then #5: editing the token clears the status.
    server.handler = { [deck] in Self.guarded(deck, token: Self.goodToken, statsDelay: 0)($0) }
    el(app, "settings.test").tap()
    waitForLabel(statusText(app), "Connected · 2 cards")
    let tokenField = el(app, "settings.token")
    tapEnd(tokenField)
    tokenField.typeText("x")
    assertStatusCleared(app, "after editing the token")
    server.stop()
  }

  /// #4: HTTP 401 → "Wrong token".
  @MainActor
  func testSettings_wrongToken() throws {
    XCUIDevice.shared.appearance = .light
    let server = try startStub(StubDeck([card("a1", "alpha", "one")]), token: Self.goodToken)
    let app = launch(api: .stored)
    openDeck(app)
    openSettings(app)
    setText(app, "settings.url", server.url)
    setText(app, "settings.token", "wrong", secure: true)
    el(app, "settings.test").tap()
    waitForLabel(statusText(app), "Wrong token")
    XCTAssertEqual(server.requests.last { StubDeck.route($0.path) == "/stats" }?.headers["authorization"], "Bearer wrong")
    snapshot("settings-unauthorized", appearance: .light)
    server.stop()
  }

  /// #4: any other error → "Can't reach server" (nothing listening, then a 500 from the stub).
  @MainActor
  func testSettings_unreachable() throws {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .stored)
    openDeck(app)
    openSettings(app)
    setText(app, "settings.url", unreachableAPIURL)
    setText(app, "settings.token", Self.goodToken, secure: true)
    el(app, "settings.test").tap()
    waitForLabel(statusText(app), "Can't reach server", timeout: 20)
    snapshot("settings-unreachable", appearance: .light)

    let server = StubAPIServer { _ in .init(status: 500, body: #"{"detail":"boom"}"#) }
    try server.start()
    setText(app, "settings.url", server.url)
    el(app, "settings.test").tap()
    waitForLabel(statusText(app), "Can't reach server")
    server.stop()
  }

  // MARK: - #2/#3/#6 persistence across launches

  /// URL and token typed in Settings survive a relaunch with no API env: the first requests after launch go to
  /// the stored URL with the stored token, and Settings shows them again (token masked).
  @MainActor
  func testSettings_persistAcrossRelaunch() throws {
    XCUIDevice.shared.appearance = .light
    let deck = StubDeck([card("b1", "persist", "stays")])
    let server = try startStub(deck, token: Self.goodToken)
    var app = launch(api: .stored)
    openDeck(app)
    openSettings(app)
    setText(app, "settings.url", server.url)
    setText(app, "settings.token", Self.goodToken, secure: true)
    el(app, "settings.close").tap()
    waitForAbsence(sheetBar(app, "Settings"))
    app.terminate()

    let before = server.requests.count
    app = launch(api: .stored)
    waitForLabel(el(app, "study.front"), "persist", timeout: 15)
    let afterLaunch = server.requests[before...]
    XCTAssertFalse(afterLaunch.isEmpty, "relaunched app sent nothing to the stored URL")
    XCTAssertTrue(afterLaunch.allSatisfy { $0.headers["authorization"] == "Bearer \(Self.goodToken)" },
                  "requests after relaunch without the stored token: \(afterLaunch.map { $0.headers["authorization"] ?? "none" })")
    openDeck(app)
    openSettings(app)
    XCTAssertEqual(fieldText(app, "settings.url"), server.url, "stored URL not shown after relaunch")
    let token = el(app, "settings.token")
    let masked = token.value as? String ?? ""
    XCTAssertEqual(masked, String(repeating: "•", count: Self.goodToken.count),
                   "stored token not shown masked (one dot per character) after relaunch")
    assertTokenNotOnScreen(app, Self.goodToken)
    snapshot("settings-relaunched", appearance: .light)
    server.stop()
  }

  /// A token typed then dismissed with a swipe (no close button, no test) is still stored after a relaunch.
  @MainActor
  func testSettings_tokenSavedOnSwipeDismiss() throws {
    XCUIDevice.shared.appearance = .light
    let deck = StubDeck([card("c1", "swiped", "slid")])
    let server = try startStub(deck, token: Self.goodToken)
    var app = launch(api: .stored)
    openDeck(app)
    openSettings(app)
    setText(app, "settings.url", server.url)
    setText(app, "settings.token", Self.goodToken, secure: true)
    for _ in 0..<2 where sheetBar(app, "Settings").exists {  // first drag may only drop the keyboard
      swipeSheetDown(app, from: sheetBar(app, "Settings"))
      Thread.sleep(forTimeInterval: 0.6)
    }
    waitForAbsence(sheetBar(app, "Settings"), "settings still open after swiping down")
    app.terminate()

    let before = server.requests.count
    app = launch(api: .stored)
    waitForLabel(el(app, "study.front"), "swiped", timeout: 15)
    XCTAssertTrue(server.requests[before...].allSatisfy { $0.headers["authorization"] == "Bearer \(Self.goodToken)" })
    server.stop()
  }

  // MARK: - #7 a successful test reloads deck and study

  /// Server A then server B: each successful test makes the deck fetch the new server at once (before the sheet
  /// closes), and study shows the new server's card once back.
  @MainActor
  func testSettings_successReloadsDeckAndStudy() throws {
    XCUIDevice.shared.appearance = .light
    let later = Date(timeIntervalSince1970: 1_767_312_000)  // 2026-01-02: still due, after the first card
    var extraA = card("e1", "zulu", "z"), extraB = card("e2", "yankee", "y")
    extraA.due = later
    extraB.due = later
    let deckA = StubDeck([card("d1", "alpha", "one"), extraA]), deckB = StubDeck([card("d2", "bravo", "two"), extraB])
    let serverA = try startStub(deckA, token: Self.goodToken), serverB = try startStub(deckB, token: Self.goodToken)
    let app = launch(api: .stored)

    for (server, front, id) in [(serverA, "alpha", "d1"), (serverB, "bravo", "d2")] {
      openDeck(app)
      openSettings(app)
      setText(app, "settings.url", server.url)
      setText(app, "settings.token", Self.goodToken, secure: true)
      el(app, "settings.test").tap()
      waitForLabel(statusText(app), "Connected · 2 cards")
      waitUntil("deck reloaded from \(server.url) after the successful test") {
        let reqs = server.requests
        guard let stats = reqs.lastIndex(where: { StubDeck.route($0.path) == "/stats" }) else { return false }
        return reqs[(stats + 1)...].contains { $0.method == "GET" && StubDeck.route($0.path) == "/cards" }
      }
      XCTAssertTrue(sheetBar(app, "Settings").exists, "settings closed by itself after the test")
      el(app, "settings.close").tap()
      waitForAbsence(sheetBar(app, "Settings"))
      XCTAssertTrue(el(app, "deck.row.\(uuid(id))").waitForExistence(timeout: 5), "deck doesn't show \(front)")
      swipeSheetDown(app, from: deckTitle(app))
      waitForAbsence(deckTitle(app))
      waitForLabel(el(app, "study.front"), front)
      waitForLabel(el(app, "study.remaining"), "2 to review")
    }
    snapshot("study-after-server-change", appearance: .light)
    serverA.stop()
    serverB.stop()
  }

  // MARK: - accessibility XL

  /// Settings stays readable at accessibility XL: no clipped/overlapping text, fields and button reachable.
  @MainActor
  func testSettings_accessibilityXL() {
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .mock, arguments: accessibilityXLArguments)
      openDeck(app)
      openSettings(app)
      assertSettingsTextsReadable(app)
      let window = app.windows.firstMatch.frame
      for id in ["settings.url", "settings.token", "settings.test", "settings.close"] {
        let f = el(app, id).frame
        XCTAssertTrue(window.contains(f), "\(id) outside the window at XL: \(f)")
      }
      snapshot("settings-xl", appearance: appearance)
      el(app, "settings.test").tap()
      waitForLabel(statusText(app), "Connected · 3 cards")
      assertSettingsTextsReadable(app)
      XCTAssertTrue(window.contains(statusText(app).frame), "settings.status outside the window at XL")
      snapshot("settings-xl-connected", appearance: appearance)
      app.terminate()
    }
  }

  /// Spec 009b #9: at AX5 (light) the Settings form doesn't clip; every id stays reachable (scrolling if needed),
  /// the theme segments stay inside the window with their full labels.
  @MainActor
  func testSettings_accessibilityAX5() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock, arguments: accessibilityAX5Arguments)
    openDeck(app)
    openSettings(app)
    let window = app.windows.firstMatch.frame
    XCTAssertTrue(window.contains(sheetTitle(app, "Settings").frame), "title clipped at AX5")
    for id in ["settings.close", "settings.url", "settings.token", "settings.token.reveal", "settings.test"] {
      let e = el(app, id)
      XCTAssertTrue(e.waitForExistence(timeout: 5), "\(id) missing at AX5")
      XCTAssertTrue(window.contains(e.frame), "\(id) outside the window at AX5: \(e.frame)")
    }
    snapshot("settings-ax5", appearance: .light)
    el(app, "settings.test").tap()
    waitForLabel(statusText(app), "Connected · 3 cards")
    scrollIntoView(app, themeSegment(app, "Forest"))
    for label in ["System", "Light", "Dark", "Forest"] {
      let s = themeSegment(app, label)
      XCTAssertTrue(s.isHittable, "theme segment \(label) not reachable at AX5")
      XCTAssertTrue(window.insetBy(dx: -0.5, dy: -0.5).contains(s.frame), "segment \(label) clipped at AX5: \(s.frame)")
    }
    XCTAssertTrue(statusText(app).exists, "settings.status missing at AX5")
    snapshot("settings-ax5-scrolled", appearance: .light)
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

  func uuid(_ suffix: String) -> String {
    "00000000-0000-0000-0000-" + String(repeating: "0", count: 12 - suffix.count) + suffix.uppercased()
  }

  func card(_ id: String, _ front: String, _ back: String) -> StubDeck.Card {
    .init(id: uuid(id), front: front, back: back)
  }

  /// Wraps a stub deck: any request without `Bearer <token>` gets a 401 (like the API); `/stats` can be slow.
  static func guarded(_ deck: StubDeck, token: String, statsDelay: TimeInterval)
    -> @Sendable (StubAPIServer.Request) -> StubAPIServer.Response {
    { request in
      guard request.headers["authorization"] == "Bearer \(token)" else {
        return .init(status: 401, body: #"{"detail":"Invalid token"}"#)
      }
      var response = deck.handle(request)
      if StubDeck.route(request.path) == "/stats" { response.delay = statsDelay }
      return response
    }
  }

  func startStub(_ deck: StubDeck, token: String, statsDelay: TimeInterval = 0) throws -> StubAPIServer {
    let server = StubAPIServer(handler: Self.guarded(deck, token: token, statsDelay: statsDelay))
    try server.start()
    return server
  }

  @MainActor
  func openDeck(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let button = el(app, "study.deck")
    XCTAssertTrue(button.waitForExistence(timeout: 10), "study.deck missing", file: file, line: line)
    button.tap()
    waitForDeckTitle(app, file: file, line: line)
  }

  @MainActor
  func openSettings(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let gear = el(app, "deck.settings")
    XCTAssertTrue(gear.waitForExistence(timeout: 5), "deck.settings missing", file: file, line: line)
    gear.tap()
    waitForSheet(app, "Settings", file: file, line: line)
  }

  @MainActor
  func statusText(_ app: XCUIApplication) -> XCUIElement { el(app, "settings.status") }

  @MainActor
  private func assertStatusCleared(_ app: XCUIApplication, _ context: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
    let status = statusText(app)
    waitUntil("settings.status cleared \(context)", timeout: 3, file: file, line: line) {
      !status.exists || status.label.isEmpty
    }
  }

  /// Text of a settings field, or "" when it only shows its placeholder.
  @MainActor
  func fieldText(_ app: XCUIApplication, _ id: String) -> String {
    let field = el(app, id)
    let value = field.value as? String ?? ""
    return value == field.placeholderValue || value == Self.urlPlaceholder || value == "Token" ? "" : value
  }

  /// No element label or value contains `token` in clear.
  @MainActor
  func assertTokenNotOnScreen(_ app: XCUIApplication, _ token: String, file: StaticString = #filePath, line: UInt = #line) {
    let clear = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", token, token))
    XCTAssertEqual(clear.count, 0, "token shown in clear", file: file, line: line)
  }

  @MainActor
  func hasFocus(_ element: XCUIElement) -> Bool {
    (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
  }

  /// Taps right of the (short) text so the cursor lands at its end. Not at the far right edge: the last ~10pt of
  /// the row don't focus the field (see report).
  @MainActor
  func tapEnd(_ field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
    field.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
    waitUntil("\(field.identifier) focused", timeout: 5, file: file, line: line) { self.hasFocus(field) }
  }

  /// Replaces a field's text: cursor at the end, delete everything, type `text`.
  @MainActor
  func setText(_ app: XCUIApplication, _ id: String, _ text: String, secure: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) {
    let field = el(app, id)
    XCTAssertTrue(field.waitForExistence(timeout: 5), "\(id) missing", file: file, line: line)
    let old = fieldText(app, id)
    tapEnd(field, file: file, line: line)
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 2) + text)
    if secure {
      XCTAssertEqual(fieldText(app, id).count, text.count, "\(id) length after typing", file: file, line: line)
    } else {
      XCTAssertEqual(fieldText(app, id), text, "\(id) text after typing", file: file, line: line)
    }
  }

  @MainActor
  func waitUntil(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                         _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
    XCTAssertTrue(condition(), "timed out waiting for: \(what)", file: file, line: line)
  }

  /// Spec 009a #2: gear and add are system toolbar buttons on one line in the top-right, gear left of add,
  /// both above the large "Cards" title.
  @MainActor
  private func assertGearInTitleRow(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let title = deckTitleText(app).frame, add = el(app, "deck.add").frame, gear = el(app, "deck.settings").frame
    let window = app.windows.firstMatch.frame
    for (id, f) in [("deck.settings", gear), ("deck.add", add)] {
      XCTAssertGreaterThanOrEqual(f.height, 43.5, "\(id) hit area under 44pt: \(f)", file: file, line: line)
    }
    XCTAssertEqual(gear.midY, add.midY, accuracy: 0.5, "gear and add not on one line", file: file, line: line)
    XCTAssertLessThan(gear.maxX, add.minX + 1, "gear not left of add", file: file, line: line)
    XCTAssertGreaterThan(add.maxX, window.width - 30, "deck.add not at the right edge: \(add)", file: file, line: line)
    XCTAssertTrue(gear.intersection(title).isNull, "gear overlaps the title", file: file, line: line)
    XCTAssertEqual(el(app, "deck.settings").label.isEmpty, false, "deck.settings has no accessibility label",
                   file: file, line: line)
  }

  /// Spec 009b #4: native sheet. Inline nav title "Settings", toolbar close (`settings.close`) at the leading edge
  /// of the bar; Form rows URL, token, test, in that order, under the bar; segmented theme picker below.
  @MainActor
  private func assertSettingsScreen(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let window = app.windows.firstMatch.frame
    let bar = sheetBar(app, "Settings"), url = el(app, "settings.url"), token = el(app, "settings.token")
    let test = el(app, "settings.test"), close = el(app, "settings.close")
    for e in [url, token, test, close] {
      XCTAssertTrue(e.waitForExistence(timeout: 5), "\(e.identifier) missing", file: file, line: line)
    }
    XCTAssertTrue(bar.exists, "no navigation bar titled Settings", file: file, line: line)
    XCTAssertFalse(el(app, "settings.title").exists, "settings.title should be gone (nav title)", file: file, line: line)
    XCTAssertEqual(url.elementType, .textField, "settings.url is not a text field", file: file, line: line)
    let shown = token.value as? String ?? ""
    XCTAssertTrue(shown.allSatisfy { $0 == "•" }, "settings.token not masked at rest: '\(shown)'", file: file, line: line)
    XCTAssertEqual(test.label, "Test connection", file: file, line: line)
    XCTAssertTrue(test.isHittable, "settings.test not hittable", file: file, line: line)
    XCTAssertEqual(token.label, "Token", "settings.token label", file: file, line: line)
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

  /// The deck under the sheet stays in the accessibility tree, so only the sheet's own texts are compared: the
  /// static texts at or below the title and above the bottom of the status/test button, plus the test button.
  @MainActor
  private func assertSettingsTextsReadable(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let window = app.windows.firstMatch.frame
    let ids = ["settings.test", "settings.status", "settings.url", "settings.token", "settings.close"]
    var frames: [(String, CGRect)] = ids.map { ($0, el(app, $0)) }.filter { $0.1.exists }.map { ($0.0, $0.1.frame) }
    frames.append(("title", sheetTitle(app, "Settings").frame))
    // The "Server" caption has no identifier: the static text between the bar and the URL field.
    let title = sheetBar(app, "Settings").frame, url = el(app, "settings.url").frame
    for t in app.staticTexts.allElementsBoundByIndex where t.identifier.isEmpty
      && t.frame.minY >= title.maxY - 1 && t.frame.maxY <= url.minY + 1 && t.frame.minX < window.midX {
      frames.append(("caption '\(t.label)'", t.frame))
    }
    for (id, f) in frames {
      XCTAssertTrue(window.insetBy(dx: -0.5, dy: -0.5).contains(f), "\(id) clipped: \(f)", file: file, line: line)
    }
    for (i, a) in frames.enumerated() {
      for b in frames[(i + 1)...] {
        let o = a.1.intersection(b.1)
        XCTAssertTrue(o.isNull || o.width < 1 || o.height < 1, "\(a.0) \(a.1) overlaps \(b.0) \(b.1)", file: file, line: line)
      }
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
    let background = appearance == .dark ? (26, 26, 26) : (249, 250, 245)
    let surface = appearance == .dark ? (37, 37, 37) : (255, 255, 255)
    let window = app.windows.firstMatch.frame
    let pixels = Pixels(XCUIScreen.main.screenshot(), pointWidth: window.width)
    func close(_ c: (Int, Int, Int), _ e: (Int, Int, Int)) -> Bool {
      abs(c.0 - e.0) <= 4 && abs(c.1 - e.1) <= 4 && abs(c.2 - e.2) <= 4
    }
    func check(_ name: String, _ p: CGPoint, _ expected: (Int, Int, Int)) {
      let c = pixels.color(at: p)
      XCTAssertTrue(close(c, expected), "\(name) at \(p) is \(c), expected \(expected)", file: file, line: line)
    }
    let url = el(app, "settings.url").frame, token = el(app, "settings.token").frame, test = el(app, "settings.test").frame
    check("sheet background left of the URL row", CGPoint(x: 4, y: url.midY), background)
    check("sheet background between test and bottom", CGPoint(x: window.midX, y: window.maxY - 60), background)
    check("URL row fill", CGPoint(x: url.maxX - 4, y: url.midY), surface)
    check("token row fill", CGPoint(x: url.maxX - 4, y: token.midY), surface)  // row spans the URL row's width
    // Darkest/brightest pixel across the test label: must be neutral (ink), not blue.
    var blueish = false
    for x in stride(from: test.minX, to: test.maxX, by: 1) {
      let c = pixels.color(at: CGPoint(x: x, y: test.midY))
      if c.2 - max(c.0, c.1) > 40 { blueish = true }
    }
    XCTAssertFalse(blueish, "settings.test text is tinted blue", file: file, line: line)
  }
}
