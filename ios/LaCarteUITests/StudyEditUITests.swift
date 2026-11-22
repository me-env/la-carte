import XCTest

/// Spec 010: inline edit of the revealed card (double-tap front/back → field in place → commit on Done / focus loss).
/// Mock deck = `LA_CARTE_API=mock` (serendipity first). "Stub" = `StubAPIServer` + `StubDeck`, to see the PATCH and
/// make it fail.
final class StudyEditUITests: XCTestCase {
  static let ratings = ["again", "good"]  // 011: two buttons; hard/easy are drag-only
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
    for appearance in [XCUIDevice.Appearance.light] {
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
      XCTAssertTrue(el(app, "study.remaining").waitFor(timeout: 3), "counter not back after the edit")
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

    // Tap on the other (non-edited) side's text commits too.
    field = startEditing(app, .back)
    replaceText(field, with: "a lucky find")
    el(app, "study.front").tap()
    waitForLabel(el(app, "study.back"), "a lucky find", timeout: 3)
    XCTAssertFalse(field.exists, "backField still shown after tapping the front text")
    XCTAssertFalse(el(app, "study.frontField").exists, "tapping the front while editing the back started a front edit")
    assertRatingsShown(app)
    let second = try waitForPatch(server, count: 2)
    XCTAssertTrue(second.body.contains("a lucky find"), "second PATCH body: \(second.body)")

    // Swipe the keyboard down: drag on the card's scroll view into the keyboard. Two drags: from the back text,
    // then from the empty card area just above the keyboard.
    field = startEditing(app, .front)
    replaceText(field, with: "serendipity!")
    let window = app.windows.firstMatch
    let keyboardTop = app.keyboards.firstMatch.frame.minY
    let starts = [el(app, "study.back").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                  window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 201, dy: keyboardTop - 30))]
    for start in starts where app.keyboards.firstMatch.exists {
      start.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
      Thread.sleep(forTimeInterval: 2)
    }
    if app.keyboards.firstMatch.exists { snapshot("study-edit-swipe-still-editing", appearance: .light) }
    waitForAbsence(app.keyboards.firstMatch, timeout: 3, "keyboard still up after swiping it down (two drags)")
    waitForLabel(el(app, "study.front"), "serendipity!", timeout: 3)
    XCTAssertFalse(field.exists, "frontField still shown after the keyboard was swiped down")
    assertRatingsShown(app)
    let patch = try waitForPatch(server, count: 3)
    XCTAssertTrue(patch.body.contains("serendipity!"), "third PATCH body: \(patch.body)")
    snapshot("study-edited-swipe", appearance: .light)
  }

  /// Return never inserts a newline (spec rule; onSubmit doesn't fire on a vertical field on iOS 27): the Done key
  /// with the caret mid-text ends the edit, and so does a typed newline at the end. Nothing saved has a newline.
  @MainActor
  func testStudyEdit_returnCommitsWithoutNewline() throws {
    XCUIDevice.shared.appearance = .light
    let (server, deck) = try startStub()
    let app = launch(api: .live(server.url))
    reveal(app)
    var field = startEditing(app, .back)
    field.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
    Thread.sleep(forTimeInterval: 0.5)
    field.typeText("Z")
    let draft = field.value as? String ?? ""
    XCTAssertTrue(draft.contains("Z") && !draft.hasSuffix("Z"), "caret not mid-text: '\(draft)'")
    tapDone(app)
    waitForAbsence(field, timeout: 3, "Done with the caret mid-text did not end the edit")
    waitForLabel(el(app, "study.back"), draft, timeout: 3)
    var patch = try waitForPatch(server)
    XCTAssertFalse(patch.body.contains("\\n"), "newline saved: \(patch.body)")
    XCTAssertEqual(deck.cards.first?.back, draft, "saved back")
    assertRatingsShown(app)

    // A newline typed at the end (hardware return / paste) commits and is dropped.
    field = startEditing(app, .front)
    field.typeText("!\n")
    waitForAbsence(field, timeout: 3, "a typed newline did not end the edit")
    waitForLabel(el(app, "study.front"), Self.front + "!", timeout: 3)
    patch = try waitForPatch(server, count: 2)
    XCTAssertFalse(patch.body.contains("\\n"), "newline saved: \(patch.body)")
    XCTAssertEqual(deck.cards.first?.front, Self.front + "!", "saved front")
    assertRatingsShown(app)
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
    waitForSheet(app, "New card")
    _ = try waitForPatch(server)
    XCTAssertEqual(deck.cards.first?.back, "a happy accident")
    snapshot("study-edit-add-editor", appearance: .light)
    el(app, "editor.close").tap()
    waitForAbsence(el(app, "editor.close"))
    waitForLabel(el(app, "study.back"), "a happy accident")
    assertRatingsShown(app)
  }

  // MARK: - #9 (stub PATCH 500)

  /// #9: PATCH fails → old text back, `study.editError` "Couldn't save the edit" in place of the counter, still on
  /// the card (not offline). Clearing it on rating / a new edit is reducer logic (StudyFeatureTests).
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

      app.terminate()
      server.stop()
    }
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

  // MARK: - Tap-away recognizer (QA follow-ups to the bug B fix)

  /// #5 on a card that scrolls: a downward swipe that starts off the field (on the answer, above the keyboard) ends
  /// the edit and saves it, while the card's scroll view also takes the drag. An upward drag (reading on) is noted.
  @MainActor
  func testStudyEdit_swipeDownOnScrollingCardCommits() throws {
    XCUIDevice.shared.appearance = .light
    let front = "Which treaty, signed in 1648, ended the Thirty Years' War?"
    let back = String(repeating: "Spaced repetition schedules each review just before you would forget. ", count: 20)
      .trimmingCharacters(in: .whitespaces)
    let (server, deck) = try startStub(front: front, back: back)
    // English-only language list: a simulator's default list (th, vi, ar…) raises the line height, CI's doesn't
    // (RatingsUITests.longCardArguments), so the card must overflow at the shorter CI line height.
    let app = launch(api: .live(server.url), arguments: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"])
    reveal(app, front: front, back: back)
    let rateTop = el(app, "study.rate.good").frame.minY
    XCTAssertGreaterThan(el(app, "study.back").frame.maxY, rateTop, "card does not overflow: \(el(app, "study.back").frame)")

    let field = startEditing(app, .front)
    field.typeText("!")
    XCTAssertTrue(poll(timeout: 3) { (field.value as? String)?.contains("!") == true }, "draft: \(field.value ?? "")")
    let draft = field.value as? String ?? ""
    let window = app.windows.firstMatch
    let keyboardTop = app.keyboards.firstMatch.frame.minY
    let answer = el(app, "study.back").frame
    // Start on the answer, between the field and the keyboard.
    let startY = min(max(field.frame.maxY + 20, answer.minY + 10), keyboardTop - 20)
    XCTAssertGreaterThan(startY, field.frame.maxY + 5, "no answer visible between field \(field.frame) and keyboard \(keyboardTop)")
    snapshot("study-edit-scrolling-card-editing", appearance: .light)

    // Upward drag first (scrolling to read on): behaviour noted, the test asserts nothing about it.
    let origin = window.coordinate(withNormalizedOffset: .zero)
    origin.withOffset(CGVector(dx: 201, dy: startY))
      .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 201, dy: startY - 120)))
    // The edit may end a moment after the drag (keyboard dismissal): give it time before reading the field.
    _ = poll(timeout: 2) { !field.exists }
    note("QA tap-away: after an upward drag on the answer, field exists=\(field.exists) focused=\(field.exists && hasFocus(field)) "
         + "keyboard=\(app.keyboards.firstMatch.exists)")
    if !field.exists {
      // The upward drag ended the edit: restart it for the downward swipe.
      _ = startEditing(app, .front)
    }

    let startY2 = min(max(field.frame.maxY + 20, el(app, "study.back").frame.minY + 10), app.keyboards.firstMatch.frame.minY - 20)
    origin.withOffset(CGVector(dx: 201, dy: startY2))
      .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 201, dy: startY2 + 200)))
    waitForAbsence(field, timeout: 3, "a downward swipe on the scrolling card's answer did not end the edit")
    waitForAbsence(app.keyboards.firstMatch, timeout: 3, "keyboard still up after the downward swipe")
    let saved = field.exists ? "" : el(app, "study.front").label
    XCTAssertEqual(saved, draft, "front after the swipe: '\(saved)' (draft was '\(draft)')")
    assertRatingsShown(app)
    let patch = try waitForPatch(server, count: 1)
    XCTAssertTrue(patch.body.contains("!"), "PATCH body: \(patch.body)")
    XCTAssertEqual(deck.cards.first?.front, draft, "saved front: \(deck.cards.first?.front ?? "nil")")
    snapshot("study-edit-scrolling-card-swiped", appearance: .light)
  }

  /// A drag that starts in the field never ends the edit: moving the caret (long press + drag, sideways and down a
  /// line), and dragging a selection's end after a double-tap selects a word.
  @MainActor
  func testStudyEdit_caretAndSelectionDragKeepEditing() throws {
    XCUIDevice.shared.appearance = .light
    let long = String(repeating: "a long answer that keeps going ", count: 4).trimmingCharacters(in: .whitespaces)
    let (server, deck) = try startStub(back: long)
    let app = launch(api: .live(server.url))
    reveal(app, back: long)
    let field = startEditing(app, .back)
    XCTAssertGreaterThan(field.frame.height, 60, "back field should wrap to 2+ lines: \(field.frame)")

    func assertStillEditing(_ what: String) {
      Thread.sleep(forTimeInterval: 1)
      note("QA tap-away: after \(what): field exists=\(field.exists) focused=\(field.exists && hasFocus(field)) "
           + "keyboard=\(app.keyboards.firstMatch.exists)")
      if !field.exists || !hasFocus(field) { snapshot("study-edit-drag-ended-\(what)", appearance: .light) }
      XCTAssertTrue(field.exists, "\(what) ended the edit")
      XCTAssertTrue(hasFocus(field), "\(what): field lost focus")
      XCTAssertFalse(el(app, "study.rate.good").exists, "\(what): ratings back while editing")
      XCTAssertEqual(server.requests.filter { $0.method == "PATCH" }.count, 0, "\(what): a PATCH was sent")
    }

    // Caret drag sideways on the first line.
    field.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.15))
      .press(forDuration: 0.8, thenDragTo: field.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.15)))
    assertStillEditing("caret-drag-sideways")
    // Caret drag down from the first line to the last (> 30 pt down: the swipe-down threshold).
    let lineDrop = field.frame.height * 0.7
    XCTAssertGreaterThan(lineDrop, 30, "field too short to test a > 30 pt downward caret drag")
    field.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15))
      .press(forDuration: 0.8, thenDragTo: field.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.85)))
    assertStillEditing("caret-drag-down")
    snapshot("study-edit-caret-dragged", appearance: .light)

    // Select a word (double-tap in the field), then drag from its end handle down and right.
    field.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.15)).doubleTap()
    Thread.sleep(forTimeInterval: 0.6)
    snapshot("study-edit-word-selected", appearance: .light)
    assertStillEditing("double-tap-select")
    field.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.2))
      .press(forDuration: 0.3, thenDragTo: field.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.85)))
    assertStillEditing("selection-drag")
    snapshot("study-edit-selection-dragged", appearance: .light)

    // Still a working edit: type, Done → saved.
    replaceText(field, with: "edited after drags")
    tapDone(app)
    waitForLabel(el(app, "study.back"), "edited after drags", timeout: 3)
    _ = try waitForPatch(server, count: 1)
    XCTAssertEqual(deck.cards.first?.back, "edited after drags")
  }

  /// A tap on the field right after the double-tap opened it (keyboard and card still animating), at several delays.
  /// Expected: the edit stays open every time. Timings are noted.
  @MainActor
  func testStudyEdit_tapFieldRightAfterOpen() throws {
    XCUIDevice.shared.appearance = .light
    let (server, _) = try startStub()
    let app = launch(api: .live(server.url))
    reveal(app)
    var failures: [String] = []
    for (side, delay) in [(Side.back, 0.0), (.back, 0.15), (.back, 0.3), (.front, 0.0), (.front, 0.15), (.back, 0.6)] {
      let start = Date()
      el(app, "study.\(side.rawValue)").doubleTap()
      let field = el(app, "study.\(side.rawValue)Field")
      XCTAssertTrue(field.waitFor(timeout: 5), "\(side)Field missing")
      if delay > 0 { Thread.sleep(forTimeInterval: delay) }
      let tapAt = Date().timeIntervalSince(start)
      field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
      Thread.sleep(forTimeInterval: 1)
      let open = field.exists && hasFocus(field)
      note(String(format: "QA tap-away: %@ delay %.2f s, tap %.2f s after the double-tap → edit %@",
                  side.rawValue, delay, tapAt, open ? "still open" : "ENDED"))
      if !open {
        failures.append(String(format: "%@ +%.2fs", side.rawValue, tapAt))
        snapshot("study-edit-tap-right-after-open-ended", appearance: .light)
      } else {
        tapDone(app)
        waitForAbsence(field, timeout: 3)
      }
      assertRatingsShown(app)
      Thread.sleep(forTimeInterval: 0.5)
    }
    XCTAssertTrue(failures.isEmpty, "a tap on the field right after it opened ended the edit: \(failures)")

    // Fastest XCUITest can do: no query between the double-tap and the tap, at the text's pre-edit position (where
    // the field is first drawn, before the keyboard lifts the card). XCUITest waits for the app to idle after the
    // double-tap, so the tap lands ~0.65 s later, after the keyboard has lifted the card (QA recording, 2026-11-22):
    // the point is then empty card area and ending the edit is correct; a tap during the move would be ignored.
    // Either outcome is acceptable, so this part only notes what happened.
    let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
    for side in [Side.back, .front, .back] {
      let text = el(app, "study.\(side.rawValue)").frame
      let start = Date()
      el(app, "study.\(side.rawValue)").doubleTap()
      let tapAt = Date().timeIntervalSince(start)
      origin.withOffset(CGVector(dx: text.midX, dy: text.midY)).tap()
      let field = el(app, "study.\(side.rawValue)Field")
      Thread.sleep(forTimeInterval: 1)
      let open = field.exists && hasFocus(field)
      note(String(format: "QA tap-away: %@ immediate tap at the pre-edit text position %.2f s after the double-tap "
                  + "returned → edit %@ (field now %@)", side.rawValue, tapAt, open ? "still open" : "ENDED",
                  String(describing: field.exists ? field.frame : .zero)))
      if open {
        tapDone(app)
        waitForAbsence(field, timeout: 3)
      }
      assertRatingsShown(app)
      Thread.sleep(forTimeInterval: 0.5)
    }
  }

  private func note(_ line: String) {
    print(line)
    XCTContext.runActivity(named: line) { _ in }
  }

  // MARK: - Helpers

  enum Side: String { case front, back }

  private func startStub(front: String = StudyEditUITests.front, back: String = StudyEditUITests.back)
    throws -> (StubAPIServer, StubDeck) {
    let deck = StubDeck([
      .init(id: Self.idA, front: front, back: back, due: Self.base, createdAt: Self.base),
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
  private func reveal(_ app: XCUIApplication, front: String = StudyEditUITests.front, back: String = StudyEditUITests.back,
                      file: StaticString = #filePath, line: UInt = #line) {
    waitForLabel(el(app, "study.front"), front, file: file, line: line)
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
    XCTAssertTrue(field.waitFor(timeout: 5), "study.\(side.rawValue)Field missing after double-tap",
                  file: file, line: line)
    XCTAssertTrue(app.keyboards.firstMatch.waitFor(timeout: 5), "no keyboard after double-tap",
                  file: file, line: line)
    XCTAssertTrue(hasFocus(field), "study.\(side.rawValue)Field not focused", file: file, line: line)
    XCTAssertFalse(el(app, "study.\(side.rawValue)").exists, "study.\(side.rawValue) still shown next to its field",
                   file: file, line: line)
    Thread.sleep(forTimeInterval: 0.6)  // keyboard slide-in + scroll settle
    return field
  }

  /// The caret goes to the end first (a previous tap may have moved it).
  @MainActor
  private func replaceText(_ field: XCUIElement, with text: String, file: StaticString = #filePath, line: UInt = #line) {
    replaceText(field, with: text, caret: CGVector(dx: 0.99, dy: 0.95), file: file, line: line)
  }

  /// The keyboard's Done (return) key: system keyboard keys have no identifier, so match its label.
  @MainActor
  private func tapDone(_ app: XCUIApplication) {
    let done = app.keyboards.buttons.matching(NSPredicate(format: "label ==[c] 'done'")).firstMatch
    XCTAssertTrue(done.waitFor(timeout: 3), "keyboard has no Done key (submitLabel(.done) missing?)")
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
      XCTAssertTrue(el(app, "study.rate.\(rating)").waitFor(timeout: 3), "study.rate.\(rating) missing",
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
