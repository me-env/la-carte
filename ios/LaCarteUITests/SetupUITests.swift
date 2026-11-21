import XCTest

/// Spec 008: "Connect your deck" (no URL or no token) and "Token rejected" (401/403), on Study and Deck.
/// Every test launches with `APIMode.stored` (no API env) and first clears whatever a previous test stored.
/// Lives on `SettingsUITests` to share its Settings helpers (`setText`, `startStub`, `guarded`, …).
extension SettingsUITests {
  static let notSetUp = (message: "Connect your deck", detail: "Add your server URL and token in Settings.")
  static let rejected = (message: "Token rejected", detail: "Check your token in Settings.")

  // MARK: - #4 not set up, #8 token rejected (light, dark, forest)

  /// #4: nothing stored → "Connect your deck" + detail + "Open Settings", no remaining / retry, no request.
  /// #8: URL + token "wrong" against a guarded stub → "Token rejected" with the same layout, no retry.
  @MainActor
  func testSetup_studyStates() throws {
    continueAfterFailure = true  // keep going so every state gets its screenshot
    let server = try startStub(StubDeck([card("f1", "alpha", "one")]), token: Self.goodToken)
    for (appearance, theme) in [(XCUIDevice.Appearance.light, "system"), (.dark, "system"), (.light, "forest")] {
      XCUIDevice.shared.appearance = appearance
      let suffix = theme == "forest" ? "-forest" : ""
      let app = launch(api: .stored, theme: theme)
      clearStoredServer(app)
      let before = server.requests.count
      assertStudyMessage(app, Self.notSetUp)
      snapshot("study-not-set-up" + suffix, appearance: appearance)

      el(app, "study.openSettings").tap()
      waitForLabel(el(app, "settings.title"), "Settings")
      setText(app, "settings.url", server.url)
      setText(app, "settings.token", "wrong", secure: true)
      closeSettingsSheet(app)
      assertStudyMessage(app, Self.rejected)
      XCTAssertTrue(server.requests[before...].contains { $0.headers["authorization"] == "Bearer wrong" },
                    "no request sent with the wrong token")
      snapshot("study-token-rejected" + suffix, appearance: appearance)
      app.terminate()
    }
    server.stop()
  }

  // MARK: - #5 open Settings from Study, #6 close re-checks

  /// #5: `study.openSettings` shows Settings directly over Study. #6: URL only → close → still not set up, and no
  /// request reached the stub; add the token → swipe down → the stub's first card.
  @MainActor
  func testSetup_connectFromStudy() throws {
    continueAfterFailure = true  // keep going so every state gets its screenshot
    XCUIDevice.shared.appearance = .light
    let server = try startStub(StubDeck([card("f1", "alpha", "one"), card("f2", "bravo", "two")]),
                               token: Self.goodToken)
    let app = launch(api: .stored)
    clearStoredServer(app)
    assertStudyMessage(app, Self.notSetUp)

    el(app, "study.openSettings").tap()
    waitForLabel(el(app, "settings.title"), "Settings")
    XCTAssertFalse(el(app, "deck.title").exists, "Settings opened via the deck, not directly over Study")
    XCTAssertEqual(el(app, "settings.url").placeholderValue, "Server URL", "settings.url placeholder (#13)")
    XCTAssertEqual(el(app, "settings.token").label, "Token", "settings.token label (#13, #16)")
    XCTAssertEqual(fieldText(app, "settings.token"), "", "settings.token not empty after clearing")
    snapshot("settings-from-study", appearance: .light)

    setText(app, "settings.url", server.url)
    closeSettingsSheet(app)
    assertStudyMessage(app, Self.notSetUp)
    XCTAssertTrue(server.requests.isEmpty, "requests sent without a token: \(server.requests.map(\.path))")

    el(app, "study.openSettings").tap()
    waitForLabel(el(app, "settings.title"), "Settings")
    XCTAssertEqual(fieldText(app, "settings.url"), server.url, "stored URL not shown")
    setText(app, "settings.token", Self.goodToken, secure: true)
    for _ in 0..<2 where el(app, "settings.title").exists {  // first drag may only drop the keyboard
      swipeSheetDown(app, from: el(app, "settings.title"))
      Thread.sleep(forTimeInterval: 0.6)
    }
    waitForAbsence(el(app, "settings.title"), "settings still open after swiping down")
    assertNoSavePasswordPrompt(app)
    waitForLabel(el(app, "study.front"), "alpha", timeout: 15)
    waitForLabel(el(app, "study.remaining"), "2 to review")
    XCTAssertFalse(el(app, "study.openSettings").exists, "study.openSettings still shown with a card")
    snapshot("study-after-setup", appearance: .light)
    server.stop()
  }

  // MARK: - #11 deck states, #12 closing the deck's Settings re-checks

  /// #11: deck not set up (light, dark) and token rejected (light) show `deck.message` + `deck.openSettings`,
  /// which opens the deck's Settings; offline shows "Can't reach your deck" with no button.
  @MainActor
  func testSetup_deckStates() throws {
    continueAfterFailure = true  // keep going so every state gets its screenshot
    let server = try startStub(StubDeck([card("f1", "alpha", "one")]), token: Self.goodToken)
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .stored)
      clearStoredServer(app)
      openDeck(app)
      assertDeckMessage(app, Self.notSetUp.message, button: true)
      snapshot("deck-not-set-up", appearance: appearance)
      if appearance == .light {
        el(app, "deck.openSettings").tap()
        waitForLabel(el(app, "settings.title"), "Settings")
        XCTAssertTrue(el(app, "deck.title").exists, "deck.openSettings did not open the deck's Settings sheet")
        setText(app, "settings.url", server.url)
        setText(app, "settings.token", "wrong", secure: true)
        closeSettingsSheet(app)
        assertDeckMessage(app, Self.rejected.message, button: true)
        snapshot("deck-token-rejected", appearance: appearance)

        el(app, "deck.openSettings").tap()
        waitForLabel(el(app, "settings.title"), "Settings")
        setText(app, "settings.url", unreachableAPIURL)
        setText(app, "settings.token", Self.goodToken, secure: true)
        closeSettingsSheet(app)
        assertDeckMessage(app, "Can't reach your deck", button: false, timeout: 20)
        snapshot("deck-offline-after-setup", appearance: appearance)
      }
      app.terminate()
    }
    server.stop()
  }

  /// #12: set up → deck → Settings → clear the token → close → deck says "Connect your deck" → close the deck →
  /// Study says "Connect your deck" too.
  @MainActor
  func testSetup_clearTokenFromDeck() throws {
    continueAfterFailure = true  // keep going so every state gets its screenshot
    XCUIDevice.shared.appearance = .light
    let server = try startStub(StubDeck([card("f1", "alpha", "one")]), token: Self.goodToken)
    let app = launch(api: .stored)
    clearStoredServer(app)
    el(app, "study.openSettings").tap()
    waitForLabel(el(app, "settings.title"), "Settings")
    setText(app, "settings.url", server.url)
    setText(app, "settings.token", Self.goodToken, secure: true)
    closeSettingsSheet(app)
    waitForLabel(el(app, "study.front"), "alpha", timeout: 15)

    openDeck(app)
    XCTAssertTrue(el(app, "deck.row.\(uuid("f1"))").waitForExistence(timeout: 5), "deck row missing once set up")
    openSettings(app)
    setText(app, "settings.token", "", secure: true)
    closeSettingsSheet(app)
    assertDeckMessage(app, Self.notSetUp.message, button: true)
    swipeSheetDown(app, from: el(app, "deck.title"))
    waitForAbsence(el(app, "deck.title"))
    assertStudyMessage(app, Self.notSetUp)
    server.stop()
  }

  // MARK: - #16 masked token field

  /// #16: the token is masked at rest (one dot per character, never in clear), the eye `settings.token.reveal`
  /// toggles plain text, tapping the row reveals + focuses, focus moving to the URL field masks it again.
  /// Uses a fake token only.
  @MainActor
  func testSetup_tokenMasked() throws {
    continueAfterFailure = true  // keep going so every state gets its screenshot
    let fake = "fake-qa-token-0000"
    let dots = String(repeating: "•", count: fake.count)
    for (appearance, theme) in [(XCUIDevice.Appearance.light, "system"), (.dark, "system"), (.light, "forest")] {
      XCUIDevice.shared.appearance = appearance
      let suffix = theme == "forest" ? "-forest" : ""
      let app = launch(api: .stored, theme: theme)
      clearStoredServer(app)
      el(app, "study.openSettings").tap()
      waitForLabel(el(app, "settings.title"), "Settings")
      let token = el(app, "settings.token"), url = el(app, "settings.url"), eye = el(app, "settings.token.reveal")

      // Row tap reveals + focuses (inside setText → tapEnd), typing shows plain text.
      setText(app, "settings.token", fake, secure: true)
      XCTAssertTrue(hasFocus(token), "settings.token not focused after tapping the row")
      XCTAssertEqual(token.value as? String, fake, "typed token not shown in plain text while focused")

      // Focus loss masks it.
      tapEnd(url)
      waitUntil("settings.token masked after focus loss") { token.value as? String == dots }
      XCTAssertEqual(token.label, "Token", "settings.token VoiceOver label")
      assertTokenNotOnScreen(app, fake)
      XCTAssertTrue(eye.exists, "settings.token.reveal missing")
      XCTAssertEqual(eye.label, "Show token")
      XCTAssertGreaterThanOrEqual(eye.frame.height, 43.99, "settings.token.reveal under 44pt: \(eye.frame)")
      XCTAssertGreaterThanOrEqual(eye.frame.width, 43.99, "settings.token.reveal under 44pt: \(eye.frame)")
      snapshot("settings-token-masked" + suffix, appearance: appearance)

      // Eye reveals, eye again hides.
      eye.tap()
      waitUntil("settings.token revealed by the eye") { token.value as? String == fake }
      XCTAssertEqual(eye.label, "Hide token")
      snapshot("settings-token-revealed" + suffix, appearance: appearance)
      eye.tap()
      waitUntil("settings.token masked by the eye") { token.value as? String == dots }
      assertTokenNotOnScreen(app, fake)

      // Tapping the row away from the dots (between the text and the eye, near the row's top edge) reveals and
      // focuses too; then focus loss re-hides.
      let k = token.frame, e = eye.frame
      app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        .withOffset(CGVector(dx: (k.maxX + e.minX) / 2, dy: e.minY + 4)).tap()
      waitUntil("settings.token revealed by a tap on the row") { token.value as? String == fake }
      waitUntil("settings.token focused by a tap on the row", timeout: 3) { self.hasFocus(token) }
      tapEnd(url)
      waitUntil("settings.token masked after focus loss (2)") { token.value as? String == dots }

      // Closing with a typed token: no "Save Password?", Study takes taps at once.
      closeSettingsSheet(app)
      assertStudyMessage(app, Self.notSetUp)  // URL is empty
      el(app, "study.openSettings").tap()
      waitForLabel(el(app, "settings.title"), "Settings")
      XCTAssertEqual(el(app, "settings.token").value as? String, dots, "saved token not shown masked on reopen")
      app.terminate()
    }
  }

  // MARK: - Helpers

  /// `settings.close`, then #16: no system "Save Password?" sheet over the next screen.
  @MainActor
  func closeSettingsSheet(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    el(app, "settings.close").tap()
    waitForAbsence(el(app, "settings.title"), file: file, line: line)
    assertNoSavePasswordPrompt(app, file: file, line: line)
  }

  /// #16: iOS used to offer "Save Password?" for the secure token field after Settings closed, blocking every tap.
  @MainActor
  func assertNoSavePasswordPrompt(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let prompt = app.descendants(matching: .any).matching(
      NSPredicate(format: "label == 'Not Now' OR label BEGINSWITH 'Save Password'")).firstMatch
    XCTAssertFalse(prompt.waitForExistence(timeout: 2), "system 'Save Password?' prompt shown after closing Settings",
                   file: file, line: line)
  }

  /// Empties the stored URL and token through the UI (Study's "Open Settings" if shown, else deck → gear), then
  /// returns to Study.
  @MainActor
  func clearStoredServer(_ app: XCUIApplication) {
    let study = el(app, "study.openSettings"), deck = el(app, "study.deck")
    XCTAssertTrue(deck.waitForExistence(timeout: 10), "study.deck missing")
    let direct = study.waitForExistence(timeout: 3)
    if direct {
      study.tap()
      waitForLabel(el(app, "settings.title"), "Settings")
    } else {
      openDeck(app)
      openSettings(app)
    }
    setText(app, "settings.url", "")
    setText(app, "settings.token", "", secure: true)
    closeSettingsSheet(app)
    if !direct {
      swipeSheetDown(app, from: el(app, "deck.title"))
      waitForAbsence(el(app, "deck.title"))
    }
  }

  /// Study's centered message + detail + "Open Settings" (≥44pt, under the detail), top bar kept, no
  /// remaining / retry.
  @MainActor
  func assertStudyMessage(_ app: XCUIApplication, _ copy: (message: String, detail: String),
                          file: StaticString = #filePath, line: UInt = #line) {
    waitForLabel(el(app, "study.message"), copy.message, timeout: 15, file: file, line: line)
    waitForLabel(el(app, "study.detail"), copy.detail, file: file, line: line)
    let button = el(app, "study.openSettings")
    XCTAssertTrue(button.waitForExistence(timeout: 5), "study.openSettings missing", file: file, line: line)
    XCTAssertEqual(button.label, "Open Settings", file: file, line: line)
    XCTAssertTrue(button.isHittable, "study.openSettings not hittable", file: file, line: line)
    XCTAssertFalse(el(app, "study.retry").exists, "study.retry shown in '\(copy.message)'", file: file, line: line)
    XCTAssertFalse(el(app, "study.remaining").exists && !el(app, "study.remaining").label.isEmpty,
                   "study.remaining shown in '\(copy.message)'", file: file, line: line)
    for id in ["study.deck", "study.add"] {
      XCTAssertTrue(el(app, id).isHittable, "\(id) not in the top bar", file: file, line: line)
    }
    let window = app.windows.firstMatch.frame
    let m = el(app, "study.message").frame, d = el(app, "study.detail").frame, b = button.frame
    for (id, f) in [("study.message", m), ("study.detail", d), ("study.openSettings", b)] {
      XCTAssertEqual(f.midX, window.midX, accuracy: 2, "\(id) not centered: \(f)", file: file, line: line)
    }
    XCTAssertGreaterThanOrEqual(d.minY, m.maxY - 1, "detail not under the message", file: file, line: line)
    XCTAssertGreaterThanOrEqual(b.minY, d.maxY - 1, "button not under the detail", file: file, line: line)
    XCTAssertGreaterThanOrEqual(b.height, 43.99, "study.openSettings under 44pt: \(b)", file: file, line: line)
    assertTextsReadable(in: app)
  }

  /// Deck message, with or without `deck.openSettings` under it.
  @MainActor
  func assertDeckMessage(_ app: XCUIApplication, _ message: String, button: Bool, timeout: TimeInterval = 15,
                         file: StaticString = #filePath, line: UInt = #line) {
    waitForLabel(el(app, "deck.message"), message, timeout: timeout, file: file, line: line)
    let open = el(app, "deck.openSettings")
    if button {
      XCTAssertTrue(open.waitForExistence(timeout: 5), "deck.openSettings missing", file: file, line: line)
      XCTAssertEqual(open.label, "Open Settings", file: file, line: line)
      XCTAssertTrue(open.isHittable, "deck.openSettings not hittable", file: file, line: line)
      XCTAssertGreaterThanOrEqual(open.frame.minY, el(app, "deck.message").frame.maxY - 1,
                                  "deck.openSettings not under the message", file: file, line: line)
      XCTAssertGreaterThanOrEqual(open.frame.height, 43.99, "deck.openSettings under 44pt: \(open.frame)", file: file, line: line)
    } else {
      XCTAssertFalse(open.exists, "deck.openSettings shown with '\(message)'", file: file, line: line)
    }
  }
}
