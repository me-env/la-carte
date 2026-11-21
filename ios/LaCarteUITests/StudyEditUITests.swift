import XCTest

/// Spec 010: inline edit of the revealed card (double-tap front/back → field in place → commit on Done / focus loss).
/// Mock deck = `LA_CARTE_API=mock` (serendipity first). "Stub" = `StubAPIServer` + `StubDeck`, to see the PATCH and
/// make it fail.
final class StudyEditUITests: XCTestCase {
  static let ratings = ["again", "hard", "good", "easy"]
  static let front = "serendipity"
  static let back = "finding something good without looking for it"
  static let base = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01: due now
  static let idA = "AAAAAAAA-0000-0000-0000-0000000000A1"
  static let idB = "BBBBBBBB-0000-0000-0000-0000000000B2"

  override func setUp() {
    continueAfterFailure = false
  }

  // MARK: - #1

  /// #1: before reveal, a double-tap on the front reveals (first tap) and opens no editor.
  @MainActor
  func testStudyEdit_doubleTapUnrevealedOnlyReveals() {
    for appearance in [XCUIDevice.Appearance.light, .dark] {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .mock)
      waitForLabel(el(app, "study.front"), Self.front)
      XCTAssertFalse(el(app, "study.back").exists, "back visible before reveal")
      el(app, "study.front").doubleTap()
      waitForLabel(el(app, "study.back"), Self.back)
      Thread.sleep(forTimeInterval: 1)
      XCTAssertFalse(el(app, "study.frontField").exists, "double-tap on the unrevealed card opened the front editor")
      XCTAssertFalse(el(app, "study.backField").exists, "double-tap on the unrevealed card opened the back editor")
      XCTAssertFalse(app.keyboards.firstMatch.exists, "keyboard shown after a double-tap on the unrevealed card")
      assertRatingsShown(app)
      snapshot("study-doubletap-unrevealed", appearance: appearance)
      app.terminate()
    }
  }

  // MARK: - #2, #14

  /// #2 (light, dark, forest): double-tap the revealed front → `study.frontField` "serendipity", focused, keyboard up,
  /// back still visible, no ratings / reveal / counter. #14: the field sits where the text was (no layout shift).
  /// Done with the text unchanged ends the edit (ratings back).
  @MainActor
  func testStudyEdit_editFront() {
    let runs: [(XCUIDevice.Appearance, String, String)] = [
      (.light, "system", "study-editing-front"), (.dark, "system", "study-editing-front"),
      (.light, "forest", "study-editing-front-forest"),
    ]
    for (appearance, theme, name) in runs {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .mock, theme: theme)
      reveal(app)
      let frontText = el(app, "study.front").frame, backText = el(app, "study.back").frame
      let field = startEditing(app, .front)
      XCTAssertEqual(field.value as? String, Self.front, "frontField content")
      XCTAssertTrue(el(app, "study.back").exists, "study.back hidden while editing the front")
      XCTAssertEqual(el(app, "study.back").label, Self.back)
      assertEditingChrome(app)
      // #14 no layout shift: same height, centered, same distance to the back as the text had.
      let fieldFrame = field.frame, backNow = el(app, "study.back").frame
      XCTAssertEqual(fieldFrame.height, frontText.height, accuracy: 2, "frontField height \(fieldFrame) vs text \(frontText)")
      XCTAssertEqual(fieldFrame.midX, app.windows.firstMatch.frame.midX, accuracy: 1, "frontField not centered")
      XCTAssertEqual(backNow.minY - fieldFrame.maxY, backText.minY - frontText.maxY, accuracy: 1.5,
                     "gap front→back changed when the field replaced the text (layout shift)")
      snapshot(name, appearance: appearance)

      // Done with no change → back to the revealed card.
      tapDone(app)
      waitForAbsence(field, "frontField still shown after Done")
      waitForLabel(el(app, "study.front"), Self.front)
      assertRatingsShown(app)
      XCTAssertTrue(el(app, "study.remaining").waitForExistence(timeout: 3), "counter not back after the edit")
      app.terminate()
    }
  }

  // MARK: - #3, #4 (Done key), risk (a) caret tap

  /// #3: double-tap the back → `study.backField` with the back, focused, front visible, no ratings.
  /// Risk (a): tapping inside the field (to move the caret) does not end the edit.
  /// #4: change to "a happy accident", tap the keyboard's Done key → text shown at once, PATCH with front + back,
  /// ratings back, same card, still revealed.
  @MainActor
  func testStudyEdit_editBackDone() throws {
    for appearance in [XCUIDevice.Appearance.light, .dark] {
      XCUIDevice.shared.appearance = appearance
      let (server, deck) = try startStub()
      let app = launch(api: .live(server.url))
      reveal(app)
      let backText = el(app, "study.back").frame
      let field = startEditing(app, .back)
      XCTAssertEqual(field.value as? String, Self.back, "backField content")
      XCTAssertEqual(el(app, "study.front").label, Self.front, "study.front hidden while editing the back")
      assertEditingChrome(app)
      XCTAssertEqual(field.frame.height, backText.height, accuracy: 2, "backField height \(field.frame) vs text \(backText)")
      snapshot("study-editing-back", appearance: appearance)

      // Risk (a): tap inside the field near its left edge (caret move) → still editing.
      field.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
      Thread.sleep(forTimeInterval: 1)
      XCTAssertTrue(field.exists, "tapping inside the field ended the edit")
      XCTAssertTrue(hasFocus(field), "tapping inside the field removed the focus")
      XCTAssertTrue(app.keyboards.firstMatch.exists, "keyboard gone after tapping inside the field")
      XCTAssertEqual(server.requests.filter { $0.method == "PATCH" }.count, 0, "caret tap sent a PATCH")
      field.typeText("Z")
      let typed = field.value as? String ?? ""
      XCTAssertTrue(typed.contains("Z") && !typed.hasSuffix("Z"),
                    "caret did not move where tapped (typed 'Z' → '\(typed)')")

      replaceText(field, with: "a happy accident")
      tapDone(app)
      waitForLabel(el(app, "study.back"), "a happy accident", timeout: 3)
      XCTAssertFalse(field.exists, "backField still shown after Done")
      assertRatingsShown(app)
      XCTAssertEqual(el(app, "study.front").label, Self.front, "card changed after the edit")
      let patch = try waitForPatch(server)
      XCTAssertEqual(patch.path.lowercased(), "/cards/\(Self.idA.lowercased())")
      let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(patch.body.utf8)) as? [String: Any])
      XCTAssertEqual(body["front"] as? String, Self.front, "PATCH front")
      XCTAssertEqual(body["back"] as? String, "a happy accident", "PATCH back")
      XCTAssertEqual(deck.cards.first?.back, "a happy accident", "stub deck not updated")
      Thread.sleep(forTimeInterval: 1)
      waitForLabel(el(app, "study.back"), "a happy accident")
      waitForLabel(el(app, "study.remaining"), "2 to review")
      if appearance == .light { snapshot("study-edited", appearance: appearance) }
      app.terminate()
      server.stop()
    }
  }

  // MARK: - #5

  /// #5: tapping the card outside the field commits; so does swiping the keyboard down.
  @MainActor
  func testStudyEdit_commitByTapOutsideAndKeyboardSwipe() throws {
    XCUIDevice.shared.appearance = .light
    let (server, deck) = try startStub()
    let app = launch(api: .live(server.url))
    reveal(app)

    // Tap in the card area, away from both texts.
    var field = startEditing(app, .back)
    replaceText(field, with: "a happy accident")
    let point = tapCardOutsideTexts(app, field: field)
    Thread.sleep(forTimeInterval: 1)
    if field.exists {
      snapshot("study-edit-tap-outside-still-editing", appearance: .light)
      XCTFail("tap on the empty card area at \(point) (card \(el(app, "study.card").frame), field \(field.frame)) "
              + "did not commit: field still shown, focused=\(hasFocus(field)), "
              + "keyboard=\(app.keyboards.firstMatch.exists), PATCHes=\(server.requests.filter { $0.method == "PATCH" }.count)")
    }
    waitForLabel(el(app, "study.back"), "a happy accident", timeout: 3)
    assertRatingsShown(app)
    _ = try waitForPatch(server, count: 1)
    XCTAssertEqual(deck.cards.first?.back, "a happy accident")

    // Swipe the keyboard down (drag on the card's scroll view).
    field = startEditing(app, .front)
    replaceText(field, with: "serendipity!")
    let window = app.windows.firstMatch
    let start = el(app, "study.back").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    start.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
    waitForAbsence(app.keyboards.firstMatch, timeout: 5, "keyboard still up after swiping it down")
    waitForLabel(el(app, "study.front"), "serendipity!", timeout: 3)
    XCTAssertFalse(field.exists, "frontField still shown after the keyboard was swiped down")
    assertRatingsShown(app)
    let patch = try waitForPatch(server, count: 2)
    XCTAssertTrue(patch.body.contains("serendipity!"), "second PATCH body: \(patch.body)")
    snapshot("study-edited-swipe", appearance: .light)

    // Tap on the other (non-edited) side's text commits too.
    field = startEditing(app, .back)
    replaceText(field, with: "a lucky find")
    el(app, "study.front").tap()
    waitForLabel(el(app, "study.back"), "a lucky find", timeout: 3)
    XCTAssertFalse(field.exists, "backField still shown after tapping the front text")
    XCTAssertFalse(el(app, "study.frontField").exists, "tapping the front while editing the back started a front edit")
    assertRatingsShown(app)
    let third = try waitForPatch(server, count: 3)
    XCTAssertTrue(third.body.contains("a lucky find"), "third PATCH body: \(third.body)")
  }

  /// Risk (b) / onSubmit on a vertical field (iOS 27): with the caret in the middle of the text, the Done key must
  /// end the edit and save the text without a newline (the "newline typed at the end" fallback can't cover this).
  @MainActor
  func testStudyEdit_doneWithCaretMidText() throws {
    XCUIDevice.shared.appearance = .light
    let (server, deck) = try startStub()
    let app = launch(api: .live(server.url))
    reveal(app)
    let field = startEditing(app, .back)
    field.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
    Thread.sleep(forTimeInterval: 0.5)
    field.typeText("Z")
    let draft = field.value as? String ?? ""
    XCTAssertTrue(draft.contains("Z") && !draft.hasSuffix("Z"), "caret not mid-text: '\(draft)'")
    tapDone(app)
    waitForAbsence(field, timeout: 3, "Done with the caret mid-text did not end the edit (onSubmit not firing?)")
    waitForLabel(el(app, "study.back"), draft, timeout: 3)
    let patch = try waitForPatch(server)
    XCTAssertFalse(patch.body.contains("\\n"), "newline saved: \(patch.body)")
    XCTAssertEqual(deck.cards.first?.back, draft, "saved back")
  }

  // MARK: - #6

  /// #6: tapping `study.add` while editing commits the edit (PATCH) and opens the "New card" editor.
  @MainActor
  func testStudyEdit_addCommitsThenOpensEditor() throws {
    XCUIDevice.shared.appearance = .light
    let (server, deck) = try startStub()
    let app = launch(api: .live(server.url))
    reveal(app)
    let field = startEditing(app, .back)
    replaceText(field, with: "a happy accident")
    el(app, "study.add").tap()
    waitForLabel(el(app, "editor.title"), "New card")
    _ = try waitForPatch(server)
    XCTAssertEqual(deck.cards.first?.back, "a happy accident")
    snapshot("study-edit-add-editor", appearance: .light)
    el(app, "editor.close").tap()
    waitForAbsence(el(app, "editor.title"))
    waitForLabel(el(app, "study.back"), "a happy accident")
    assertRatingsShown(app)
  }

  // MARK: - #9 (stub PATCH 500)

  /// #9: PATCH fails → old text back, `study.editError` "Couldn't save the edit" in place of the counter, still on
  /// the card (not offline). Starting another edit clears it; rating clears it.
  @MainActor
  func testStudyEdit_saveFailureShowsError() throws {
    for appearance in [XCUIDevice.Appearance.light, .dark] {
      XCUIDevice.shared.appearance = appearance
      let (server, deck) = try startStub()
      deck.writeStatus = 500
      let app = launch(api: .live(server.url))
      reveal(app)
      var field = startEditing(app, .back)
      replaceText(field, with: "a happy accident")
      tapDone(app)
      _ = try waitForPatch(server)
      waitForLabel(el(app, "study.editError"), "Couldn't save the edit")
      waitForLabel(el(app, "study.back"), Self.back)
      XCTAssertFalse(el(app, "study.remaining").exists, "counter shown together with the error line")
      XCTAssertFalse(el(app, "study.message").exists, "screen left the card (offline/unauthorized) after a failed save")
      XCTAssertEqual(el(app, "study.editError").frame.midX, app.windows.firstMatch.frame.midX, accuracy: 1,
                     "error line not centered")
      XCTAssertEqual(el(app, "study.editError").frame.midY, el(app, "study.deck").frame.midY, accuracy: 3,
                     "error line not in the counter slot")
      assertRatingsShown(app)
      snapshot("study-edit-error", appearance: appearance)

      // Another edit clears the message.
      field = startEditing(app, .back)
      XCTAssertFalse(el(app, "study.editError").exists, "error line still shown after starting another edit")
      tapDone(app)
      waitForAbsence(field)

      // Fail again, then rate → cleared, counter back.
      field = startEditing(app, .front)
      replaceText(field, with: "serendipity!")
      tapDone(app)
      waitForLabel(el(app, "study.editError"), "Couldn't save the edit")
      waitForLabel(el(app, "study.front"), Self.front)
      el(app, "study.rate.good").tap()
      waitForLabel(el(app, "study.front"), "gratitude")
      XCTAssertFalse(el(app, "study.editError").exists, "error line still shown after rating")
      XCTAssertTrue(el(app, "study.remaining").waitForExistence(timeout: 3), "counter not back after rating")
      app.terminate()
      server.stop()
    }
  }

  // MARK: - Risk (d): reloads don't replace the card under the user's fingers

  /// Spec rule: while editing, a foreground reload is skipped. The server's copy changes while the user types;
  /// backgrounding + reactivating must not call the API nor replace the draft; Done saves what was typed.
  @MainActor
  func testStudyEdit_foregroundReloadSkippedWhileEditing() throws {
    XCUIDevice.shared.appearance = .light
    let (server, deck) = try startStub()
    let app = launch(api: .live(server.url))
    reveal(app)
    let field = startEditing(app, .back)
    replaceText(field, with: "typed by me")
    deck.remove(id: Self.idA)
    deck.add(.init(id: Self.idA, front: Self.front, back: "changed by an agent", due: Self.base, createdAt: Self.base))
    let before = server.requests.count
    backgroundAndReactivate(app)
    Thread.sleep(forTimeInterval: 2)
    let calls = server.requests.dropFirst(before).map { "\($0.method) \($0.path)" }
    let backField = el(app, "study.backField")
    if backField.exists {
      XCTAssertEqual(backField.value as? String, "typed by me", "draft replaced while editing")
      XCTAssertTrue(calls.isEmpty, "API called on reactivation while editing: \(calls)")
      snapshot("study-editing-after-foreground", appearance: .light)
      tapDone(app)
    }
    // Whether or not backgrounding ended the edit, what the user typed must be what's saved and shown.
    waitForLabel(el(app, "study.back"), "typed by me", timeout: 5)
    let patch = try waitForPatch(server)
    XCTAssertTrue(patch.body.contains("typed by me"), "PATCH body: \(patch.body)")
    XCTAssertTrue(backField.exists == false)
  }

  // MARK: - #15

  /// #15 (light): a ~200-character back wraps inside the field; the card scrolls; the field stays above the keyboard.
  @MainActor
  func testStudyEdit_longText() throws {
    XCUIDevice.shared.appearance = .light
    let long = String(repeating: "a long answer that keeps going ", count: 7).trimmingCharacters(in: .whitespaces)
    let (server, _) = try startStub(back: long)
    let app = launch(api: .live(server.url))
    reveal(app, back: long)
    let line = el(app, "study.front").frame.height
    let field = startEditing(app, .back)
    XCTAssertEqual(field.value as? String, long)
    XCTAssertGreaterThan(field.frame.height, line * 2, "long back not wrapped in the field: \(field.frame)")
    let window = app.windows.firstMatch.frame
    XCTAssertGreaterThanOrEqual(field.frame.minX, window.minX - 0.5, "field clipped left")
    XCTAssertLessThanOrEqual(field.frame.maxX, window.maxX + 0.5, "field clipped right")
    assertFieldReachableAboveKeyboard(app, field)
    snapshot("study-editing-long", appearance: .light)
    field.typeText("!")
    tapDone(app)
    waitForLabel(el(app, "study.back"), long + "!", timeout: 3)
    assertRatingsShown(app)
  }

  /// #15 (light, accessibility XL): the field is readable and not hidden by the keyboard.
  @MainActor
  func testStudyEdit_accessibilityXL() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock, arguments: accessibilityXLArguments)
    reveal(app)
    let backText = el(app, "study.back").frame
    let field = startEditing(app, .back)
    XCTAssertEqual(field.value as? String, Self.back)
    XCTAssertEqual(field.frame.height, backText.height, accuracy: 3, "XL backField height \(field.frame) vs text \(backText)")
    assertFieldReachableAboveKeyboard(app, field)
    snapshot("study-editing-xl", appearance: .light)
    field.typeText("!")
    tapDone(app)
    waitForLabel(el(app, "study.back"), Self.back + "!", timeout: 3)
  }

  // MARK: - #13 VoiceOver

  /// #13: VoiceOver "Edit" action on the revealed front/back, absent before reveal. XCUITest has no API to list or
  /// perform custom actions; on iOS 27 we drive VoiceOver itself (`voiceOverService`): focus the back, swipe down
  /// (next action) then double-tap (activate) and expect the field.
  @MainActor
  func testStudyEdit_voiceOverEditAction() throws {
    guard #available(iOS 27, *) else { throw XCTSkip("XCUIVoiceOverService needs iOS 27") }
    try voiceOverEditAction()
  }

  @available(iOS 27, *)
  @MainActor
  private func voiceOverEditAction() throws {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock)
    waitForLabel(el(app, "study.front"), Self.front)
    let vo = XCUIDevice.shared.voiceOverService
    try vo.enable()
    addTeardownBlock { @MainActor in try? XCUIDevice.shared.voiceOverService.disable() }

    // Before reveal: walk to the front, note what's spoken.
    let unrevealed = try focusVoiceOver(on: Self.front, vo)
    XCTAssertFalse(unrevealed.localizedCaseInsensitiveContains("action"),
                   "VoiceOver announces actions on the unrevealed front: '\(unrevealed)'")
    // Control: can a synthesized double-tap activate anything under VoiceOver? Focus "Show answer", double-tap.
    _ = try focusVoiceOver(on: "Show answer", vo)
    app.windows.firstMatch.doubleTap()
    let voActivates = el(app, "study.back").waitForExistence(timeout: 3)
    print("VO control (double-tap on Show answer revealed): \(voActivates)")
    XCTContext.runActivity(named: "VO control revealed=\(voActivates)") { _ in }
    if !voActivates {
      try vo.disable()
      el(app, "study.reveal").tap()
      try vo.enable()
    }
    waitForLabel(el(app, "study.back"), Self.back)

    let spoken = try focusVoiceOver(on: Self.back, vo)
    Thread.sleep(forTimeInterval: 2)  // hint ("Actions available") is spoken after a pause
    let withHint = (try? vo.currentSpeech().utterance) ?? spoken
    print("VO back speech: '\(spoken)' / '\(withHint)'")
    // Activate the first custom action with VoiceOver gestures.
    XCTAssertTrue(withHint.contains("Actions available") || spoken.contains("Actions available"),
                  "no custom action announced on the revealed back: '\(spoken)' / '\(withHint)'")
    app.swipeDown()
    Thread.sleep(forTimeInterval: 1)
    let actionSpeech = (try? vo.currentSpeech().utterance) ?? ""
    print("VO after swipe down: '\(actionSpeech)'")
    XCTAssertEqual(actionSpeech, "Edit", "first custom action on study.back is not 'Edit'")
    guard voActivates else {
      try vo.disable()
      throw XCTSkip("#13 partial: 'Edit' action listed on the revealed back and absent before reveal, but a "
                    + "synthesized double-tap doesn't activate under VoiceOver (control on Show answer failed)")
    }
    // VoiceOver's "double-tap anywhere" activates the selected action. Try the synthesized gestures in turn.
    let field = el(app, "study.backField")
    let window = app.windows.firstMatch
    let attempts: [(String, () -> Void)] = [
      ("window.doubleTap", { window.doubleTap() }),
      ("back.coordinate.doubleTap", {
        self.el(app, "study.back").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
      }),
      ("tap.tap", {
        let c = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        c.press(forDuration: 0.02); c.press(forDuration: 0.02)
      }),
    ]
    var opened = false
    var log: [String] = []
    for (name, gesture) in attempts where !opened {
      gesture()
      opened = field.waitForExistence(timeout: 3)
      log.append("\(name): opened=\(opened) frontField=\(self.el(app, "study.frontField").exists) speech='\((try? vo.currentSpeech().utterance) ?? "-")'")
      if !opened {  // re-select the Edit action on the back for the next attempt
        _ = try? vo.moveBackward(); _ = try? vo.moveForward()
        app.swipeDown()
        Thread.sleep(forTimeInterval: 0.5)
      }
    }
    print("VO attempts: \(log)")
    try vo.disable()
    XCTAssertTrue(opened, "VoiceOver Edit action did not open study.backField (speech '\(spoken)', "
                  + "after swipe down '\(actionSpeech)'; attempts \(log))")
    if opened {
      snapshot("study-editing-voiceover", appearance: .light)
      XCTAssertEqual(field.label, "Back", "field accessibility label")
    }
  }

  // MARK: - #16 live API

  /// #16: live API (scripts/e2e.sh seeds `greeting`/`hello`): reveal, double-tap the back, append "!", Done →
  /// `GET /cards` shows "hello!"; then restore "hello" via PATCH (deck-neutral).
  @MainActor
  func testStudyEdit_appendToBack_liveAPI() throws {
    guard let url = ProcessInfo.processInfo.environment["LA_CARTE_API_URL"], !url.isEmpty else {
      throw XCTSkip("LA_CARTE_API_URL not set — run scripts/e2e.sh")
    }
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .live(url))
    waitForLabel(el(app, "study.front"), "greeting")
    el(app, "study.card").tap()
    waitForLabel(el(app, "study.back"), "hello")
    let field = startEditing(app, .back)
    XCTAssertEqual(field.value as? String, "hello")
    field.typeText("!")
    tapDone(app)
    waitForLabel(el(app, "study.back"), "hello!", timeout: 5)
    assertRatingsShown(app)
    snapshot("study-edit-live", appearance: .light)

    let deadline = Date().addingTimeInterval(5)
    var card: [String: Any]?
    repeat {
      card = try liveCards(url).first { $0["front"] as? String == "greeting" }
      if card?["back"] as? String == "hello!" { break }
      Thread.sleep(forTimeInterval: 0.3)
    } while Date() < deadline
    XCTAssertEqual(card?["back"] as? String, "hello!", "API card after the inline edit: \(card ?? [:])")
    let id = try XCTUnwrap(card?["id"] as? String)
    _ = liveRequest(url + "/cards/\(id)", method: "PATCH", body: #"{"front":"greeting","back":"hello"}"#)
    let restored = try liveCards(url).first { $0["id"] as? String == id }
    XCTAssertEqual(restored?["back"] as? String, "hello", "deck not restored")
  }

  // MARK: - Helpers

  enum Side: String { case front, back }

  private func startStub(back: String = StudyEditUITests.back) throws -> (StubAPIServer, StubDeck) {
    let deck = StubDeck([
      .init(id: Self.idA, front: Self.front, back: back, due: Self.base, createdAt: Self.base),
      .init(id: Self.idB, front: "gratitude", back: "thank you", due: Self.base.addingTimeInterval(60),
            createdAt: Self.base.addingTimeInterval(60)),
    ])
    // StubDeck has no review route: a review removes the card from the due list and echoes it.
    let server = StubAPIServer { request in
      let route = StubDeck.route(request.path)
      guard request.method == "POST", route.hasSuffix("/review") else { return deck.handle(request) }
      let id = String(route.dropFirst("/cards/".count).dropLast("/review".count))
      guard let card = deck.cards.first(where: { $0.id.lowercased() == id.lowercased() }) else {
        return .init(status: 404, body: "{}")
      }
      deck.remove(id: id)
      return .init(body: StubDeck.json(card))
    }
    try server.start()
    return (server, deck)
  }

  @MainActor
  private func reveal(_ app: XCUIApplication, back: String = StudyEditUITests.back, file: StaticString = #filePath, line: UInt = #line) {
    waitForLabel(el(app, "study.front"), Self.front, file: file, line: line)
    el(app, "study.reveal").tap()
    waitForLabel(el(app, "study.back"), back, file: file, line: line)
    assertRatingsShown(app, file: file, line: line)
  }

  /// Double-taps the text and returns its field, checked focused with the keyboard up.
  @MainActor
  private func startEditing(_ app: XCUIApplication, _ side: Side,
                            file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
    el(app, "study.\(side.rawValue)").doubleTap()
    let field = el(app, "study.\(side.rawValue)Field")
    XCTAssertTrue(field.waitForExistence(timeout: 5), "study.\(side.rawValue)Field missing after double-tap",
                  file: file, line: line)
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no keyboard after double-tap",
                  file: file, line: line)
    XCTAssertTrue(hasFocus(field), "study.\(side.rawValue)Field not focused", file: file, line: line)
    XCTAssertFalse(el(app, "study.\(side.rawValue)").exists, "study.\(side.rawValue) still shown next to its field",
                   file: file, line: line)
    Thread.sleep(forTimeInterval: 0.6)  // keyboard slide-in + scroll settle
    return field
  }

  @MainActor
  private func hasFocus(_ element: XCUIElement) -> Bool {
    (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
  }

  @MainActor
  private func replaceText(_ field: XCUIElement, with text: String) {
    let current = field.value as? String ?? ""
    // Move the caret to the end first (a previous tap may have moved it).
    field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.95)).tap()
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
    field.typeText(text)
    XCTAssertEqual(field.value as? String, text, "field content after typing")
  }

  /// The keyboard's Done (return) key: system keyboard keys have no identifier, so match its label.
  @MainActor
  private func tapDone(_ app: XCUIApplication) {
    let done = app.keyboards.buttons.matching(NSPredicate(format: "label ==[c] 'done'")).firstMatch
    XCTAssertTrue(done.waitForExistence(timeout: 3), "keyboard has no Done key (submitLabel(.done) missing?)")
    done.tap()
  }

  @MainActor
  @discardableResult
  private func tapCardOutsideTexts(_ app: XCUIApplication, field: XCUIElement) -> CGPoint {
    // Empty card area above the texts (never under the keyboard). Frames read once the keyboard has settled.
    Thread.sleep(forTimeInterval: 1)
    let card = el(app, "study.card").frame
    let top = [el(app, "study.front"), el(app, "study.frontField"), el(app, "study.back"), field]
      .filter(\.exists).map(\.frame.minY).min() ?? card.minY
    XCTAssertGreaterThan(top - card.minY, 16, "no free card area above the texts (card \(card), top \(top))")
    let y = (card.minY + top) / 2
    let window = app.windows.firstMatch
    window.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: card.midX, dy: y)).tap()
    return CGPoint(x: card.midX, y: y)
  }

  @MainActor
  private func assertFieldReachableAboveKeyboard(_ app: XCUIApplication, _ field: XCUIElement,
                                                 file: StaticString = #filePath, line: UInt = #line) {
    let keyboard = app.keyboards.firstMatch.frame
    let topBar = el(app, "study.deck").frame.maxY
    XCTAssertLessThan(field.frame.minY, keyboard.minY - 20, "field hidden behind the keyboard: field \(field.frame), "
                      + "keyboard \(keyboard)", file: file, line: line)
    XCTAssertGreaterThan(field.frame.maxY, topBar, "field scrolled out above the top bar: \(field.frame)",
                         file: file, line: line)
  }

  @MainActor
  private func assertEditingChrome(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    for rating in Self.ratings {
      XCTAssertFalse(el(app, "study.rate.\(rating)").exists, "study.rate.\(rating) shown while editing",
                     file: file, line: line)
    }
    XCTAssertFalse(el(app, "study.reveal").exists, "study.reveal shown while editing", file: file, line: line)
    XCTAssertFalse(el(app, "study.remaining").exists, "counter shown while editing (design note)", file: file, line: line)
    XCTAssertTrue(el(app, "study.deck").isHittable, "study.deck not reachable while editing", file: file, line: line)
    XCTAssertTrue(el(app, "study.add").isHittable, "study.add not reachable while editing", file: file, line: line)
  }

  @MainActor
  private func assertRatingsShown(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    for rating in Self.ratings {
      XCTAssertTrue(el(app, "study.rate.\(rating)").waitForExistence(timeout: 3), "study.rate.\(rating) missing",
                    file: file, line: line)
    }
  }

  private func waitForPatch(_ server: StubAPIServer, count: Int = 1, timeout: TimeInterval = 5,
                            file: StaticString = #filePath, line: UInt = #line) throws -> StubAPIServer.Request {
    let deadline = Date().addingTimeInterval(timeout)
    var patches: [StubAPIServer.Request] = []
    repeat {
      patches = server.requests.filter { $0.method == "PATCH" }
      if patches.count >= count { break }
      Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    XCTAssertEqual(patches.count, count, "PATCH requests: \(patches.map(\.path))", file: file, line: line)
    return try XCTUnwrap(patches.last, file: file, line: line)
  }

  /// Moves VoiceOver forward (from the start) until the spoken text contains `text`; returns the utterance.
  @available(iOS 27, *)
  @MainActor
  private func focusVoiceOver(on text: String, _ vo: XCUIVoiceOverService) throws -> String {
    var seen: [String] = []
    for _ in 0..<20 {
      let speech = try vo.moveForward().utterance
      seen.append(speech)
      if speech.contains(text) { return speech }
    }
    XCTFail("VoiceOver never reached '\(text)'; spoke: \(seen)")
    return ""
  }

  private func liveRequest(_ url: String, method: String = "GET", body: String? = nil) -> Data? {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = method
    if let token = ProcessInfo.processInfo.environment["LA_CARTE_API_TOKEN"] {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let body {
      request.httpBody = Data(body.utf8)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    var result: Data?
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, _, _ in
      result = data
      done.signal()
    }.resume()
    _ = done.wait(timeout: .now() + 10)
    return result
  }

  private func liveCards(_ url: String) throws -> [[String: Any]] {
    let data = try XCTUnwrap(liveRequest(url + "/cards?limit=500"), "no response from \(url)/cards")
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
  }
}
