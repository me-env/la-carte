import XCTest

/// Spec 002: Deck list + add / edit card.
/// Mock deck = `LA_CARTE_API=mock`: serendipity (…01), la carte (…02), ephemeral (…03); all due, state new.
final class DeckUITests: XCTestCase {
  static let ids = (1...3).map { "00000000-0000-0000-0000-00000000000\($0)" }
  static let fixtures: [(front: String, back: String)] = [
    ("serendipity", "finding something good without looking for it"),
    ("la carte", "the menu — and the map"),
    ("ephemeral", "lasting a very short time"),
  ]

  override func setUp() {
    continueAfterFailure = false
  }

  // MARK: - #1 list, #12 swipe-down close

  /// #1: `study.deck` → "Cards", one row per card in API order, due/state meta line, front + back preview,
  /// styled like ref 04 (surface rows, radius 12, 8pt gap, no separators, background behind). #12: swipe down closes.
  @MainActor
  func testDeck_openFromStudy() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock)
    openDeck(app)
    waitForRows(app, Self.ids)
    for (i, id) in Self.ids.enumerated() {
      assertRow(app, id, front: Self.fixtures[i].front, back: Self.fixtures[i].back, due: "Due now", state: "new")
    }
    assertDeckChrome(app)
    assertRowSpacing(app)
    assertDeckColors(app, appearance: .light)
    snapshot("deck", appearance: .light)

    // #12: swipe down closes the sheet, back to study.
    swipeSheetDown(app, from: el(app, "deck.title"))
    waitForAbsence(el(app, "deck.title"), "deck sheet still open after swiping down")
    waitForLabel(el(app, "study.front"), Self.fixtures[0].front)
  }

  /// #1 against API-shaped data: rows keep the API order (newest first), "Due in 3 days", a non-new state,
  /// long text on one line each; the live client asks for `limit=500`.
  @MainActor
  func testDeck_rowsFromAPI() throws {
    XCUIDevice.shared.appearance = .light
    let now = Date()
    let long = "a very long front that would never fit on a single line of an iPhone list row at all"
    let deck = StubDeck([
      .init(id: "aaaaaaaa-0000-0000-0000-000000000001", front: "gratitude", back: "thank you", state: "review",
            due: now.addingTimeInterval(3 * 86_400 + 3_600), createdAt: now.addingTimeInterval(-7_200)),
      .init(id: "aaaaaaaa-0000-0000-0000-000000000002", front: long, back: long + " (back)",
            createdAt: now.addingTimeInterval(-3_600)),
    ])
    let server = StubAPIServer(handler: deck.handle)
    try server.start()
    let app = launch(api: .live(server.url))
    openDeck(app)
    let newest = "aaaaaaaa-0000-0000-0000-000000000002", older = "aaaaaaaa-0000-0000-0000-000000000001"
    waitForRows(app, [newest, older])
    assertRow(app, older, front: "gratitude", back: "thank you", due: "Due in 3 days", state: "review")
    assertRow(app, newest, front: long, back: long + " (back)", due: "Due now", state: "new")
    // 1 line each: the long row is as tall as the short one.
    XCTAssertEqual(row(app, newest).frame.height, row(app, older).frame.height, accuracy: 1,
                   "long text row is taller than a short one: front/back not limited to 1 line")
    snapshot("deck-api-rows", appearance: .light)
    let lists = server.requests.filter { StubDeck.route($0.path) == "/cards" && $0.method == "GET" }
    XCTAssertFalse(lists.isEmpty, "no GET /cards")
    for r in lists {
      XCTAssertEqual(StubDeck.queryItems(r.path)["limit"], "500", "GET /cards without limit=500: \(r.path)")
    }
    server.stop()
  }

  // MARK: - #2 search

  /// #2: "ser" leaves only serendipity; clearing shows all three again.
  @MainActor
  func testDeck_search() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock)
    openDeck(app)
    waitForRows(app, Self.ids)
    let search = el(app, "deck.search")
    search.tap()
    search.typeText("ser")
    waitForRows(app, [Self.ids[0]])
    snapshot("deck-search", appearance: .light)
    search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3))
    waitForRows(app, Self.ids)
  }

  // MARK: - #3 messages

  /// #3: empty deck → "No cards yet".
  @MainActor
  func testDeck_emptyDeck() throws {
    let deck = StubDeck([])
    let server = StubAPIServer(handler: deck.handle)
    try server.start()
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .live(server.url))
    openDeck(app)
    waitForLabel(el(app, "deck.message"), "No cards yet")
    waitForRows(app, [])
    snapshot("deck-empty", appearance: .light)
    server.stop()
  }

  /// #3: failed load → "Can't reach your deck".
  @MainActor
  func testDeck_loadFailed() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .live(unreachableAPIURL))
    waitForLabel(el(app, "study.message"), "Can't reach your deck", timeout: 20)
    openDeck(app)
    waitForLabel(el(app, "deck.message"), "Can't reach your deck", timeout: 20)
    waitForRows(app, [])
    snapshot("deck-offline", appearance: .light)
  }

  // MARK: - #4 swipe to delete

  /// #4: swipe left reveals "Delete"; confirming removes the row immediately; it stays gone on reopen.
  @MainActor
  func testDeck_swipeToDelete() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock)
    openDeck(app)
    waitForRows(app, Self.ids)
    row(app, Self.ids[1]).swipeLeft()
    let delete = deleteAction(app, Self.ids[1])
    XCTAssertTrue(delete.waitFor(timeout: 3), "no deck.row.<id>.delete after swiping left")
    XCTAssertEqual(delete.label, "Delete")
    assertSystemRed(app, delete)
    snapshot("deck-swipe", appearance: .light)
    delete.tap()
    waitForRows(app, [Self.ids[0], Self.ids[2]], timeout: 1.5)
    swipeSheetDown(app, from: el(app, "deck.title"))
    waitForAbsence(el(app, "deck.title"))
    openDeck(app)
    waitForRows(app, [Self.ids[0], Self.ids[2]])
  }

  // MARK: - #5 edit

  /// #5: tapping a row → "Edit card" prefilled; changing the back + save → dismissed, row shows the new back.
  @MainActor
  func testDeck_editRow() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock)
    openDeck(app)
    waitForRows(app, Self.ids)
    row(app, Self.ids[2]).tap()
    waitForLabel(el(app, "editor.title"), "Edit card")
    XCTAssertEqual(fieldText(app, "editor.front"), Self.fixtures[2].front)
    XCTAssertEqual(fieldText(app, "editor.back"), Self.fixtures[2].back)
    assertEditorChrome(app)
    snapshot("editor-edit", appearance: .light)
    replaceText(app, "editor.back", with: "short-lived")
    XCTAssertTrue(el(app, "editor.save").isEnabled)
    el(app, "editor.save").tap()
    waitForAbsence(el(app, "editor.title"), "editor still open after saving")
    waitUntil("row shows the new back") { self.rowText(app, Self.ids[2], "short-lived").exists }
    XCTAssertFalse(rowText(app, Self.ids[2], Self.fixtures[2].back).exists, "old back still shown")
    waitForRows(app, Self.ids)  // replaced in place
    snapshot("deck-after-edit", appearance: .light)
  }

  // MARK: - #6 add from deck, #8 save disabled

  /// #6: `deck.add` → "New card", empty fields, front focused; #8 save disabled while a field is empty
  /// (after trimming); saving puts the new row at the top.
  @MainActor
  func testDeck_addFromDeck() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock)
    openDeck(app)
    waitForRows(app, Self.ids)
    el(app, "deck.add").tap()
    assertNewCardEditor(app)
    snapshot("editor-new", appearance: .light)
    el(app, "editor.front").typeText("feline")
    XCTAssertFalse(el(app, "editor.save").isEnabled, "editor.save enabled with an empty back")
    el(app, "editor.back").tap()
    el(app, "editor.back").typeText("   ")
    XCTAssertFalse(el(app, "editor.save").isEnabled, "editor.save enabled with a whitespace-only back")
    el(app, "editor.back").typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "cat")
    XCTAssertTrue(el(app, "editor.save").isEnabled, "editor.save disabled with front + back filled")
    snapshot("editor-filled", appearance: .light)
    el(app, "editor.save").tap()
    waitForAbsence(el(app, "editor.title"), "editor still open after saving")
    waitUntil("new row at the top") { self.rowIDs(app).count == 4 }
    let top = rowIDs(app)[0]
    XCTAssertFalse(Self.ids.contains(top), "new card is not the top row: \(rowIDs(app))")
    assertRow(app, top, front: "feline", back: "cat", due: "Due now", state: "new")
    XCTAssertEqual(Array(rowIDs(app).dropFirst()), Self.ids)
    snapshot("deck-after-add", appearance: .light)
  }

  // MARK: - #7 add from study

  /// #7: `study.add` over a caught-up study → "New card", front focused; saving dismisses and study shows it.
  @MainActor
  func testStudy_addWhenCaughtUp() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock)
    for card in Self.fixtures {
      waitForLabel(el(app, "study.front"), card.front)
      el(app, "study.reveal").tap()
      XCTAssertTrue(el(app, "study.rate.good").waitFor(timeout: 3))
      el(app, "study.rate.good").tap()
    }
    waitForLabel(el(app, "study.message"), "All caught up")
    el(app, "study.add").tap()
    assertNewCardEditor(app)
    el(app, "editor.front").typeText("feline")
    el(app, "editor.back").tap()
    el(app, "editor.back").typeText("cat")
    el(app, "editor.save").tap()
    waitForAbsence(el(app, "editor.title"), "editor still open after saving")
    waitForLabel(el(app, "study.front"), "feline")
    waitForLabel(el(app, "study.remaining"), "1 to review")
    snapshot("study-after-add", appearance: .light)
  }

  // MARK: - #11 study refresh

  /// #11: deleting the current study card in the deck → study shows the next card once the deck is closed;
  /// editing / adding in the deck are picked up too.
  @MainActor
  func testDeck_changesRefreshStudy() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock)
    waitForLabel(el(app, "study.front"), Self.fixtures[0].front)
    waitForLabel(el(app, "study.remaining"), "3 to review")

    // Delete the current card.
    openDeck(app)
    waitForRows(app, Self.ids)
    swipeAndDelete(app, Self.ids[0])
    waitForRows(app, Array(Self.ids.dropFirst()))
    swipeSheetDown(app, from: el(app, "deck.title"))
    waitForAbsence(el(app, "deck.title"))
    waitForLabel(el(app, "study.front"), Self.fixtures[1].front)
    waitForLabel(el(app, "study.remaining"), "2 to review")
    snapshot("study-after-delete", appearance: .light)

    // Edit the (new) current card's front.
    openDeck(app)
    waitForRows(app, Array(Self.ids.dropFirst()))
    row(app, Self.ids[1]).tap()
    waitForLabel(el(app, "editor.title"), "Edit card")
    replaceText(app, "editor.front", with: "la carta")
    el(app, "editor.save").tap()
    waitForAbsence(el(app, "editor.title"))
    swipeSheetDown(app, from: el(app, "deck.title"))
    waitForAbsence(el(app, "deck.title"))
    waitForLabel(el(app, "study.front"), "la carta")

    // Add from the deck.
    openDeck(app)
    el(app, "deck.add").tap()
    assertNewCardEditor(app)
    el(app, "editor.front").typeText("feline")
    el(app, "editor.back").tap()
    el(app, "editor.back").typeText("cat")
    el(app, "editor.save").tap()
    waitForAbsence(el(app, "editor.title"))
    swipeSheetDown(app, from: el(app, "deck.title"))
    waitForAbsence(el(app, "deck.title"))
    waitForLabel(el(app, "study.remaining"), "3 to review")
  }

  // MARK: - #12 accessibility XL

  /// #12: rows and editor fields stay readable at accessibility XL.
  @MainActor
  func testDeck_accessibilityXL() {
    XCUIDevice.shared.appearance = .light
    let baseline = launch(api: .mock)
    openDeck(baseline)
    waitForRows(baseline, Self.ids)
    let baseHeight = row(baseline, Self.ids[0]).frame.height
    baseline.terminate()

    let app = launch(api: .mock, arguments: accessibilityXLArguments)
    openDeck(app)
    XCTAssertTrue(row(app, Self.ids[0]).waitFor(timeout: 10))
    snapshot("deck-xl", appearance: .light)
    XCTAssertGreaterThan(row(app, Self.ids[0]).frame.height, baseHeight * 1.3, "rows did not scale with Dynamic Type")
    assertTextsReadable(in: app, ignoring: ["study."])
    let window = app.windows.firstMatch.frame
    for id in ["deck.title", "deck.add", "deck.search"] {
      XCTAssertTrue(window.contains(el(app, id).frame), "\(id) outside the window at XL: \(el(app, id).frame)")
    }
    let first = row(app, Self.ids[0])
    for id in ["\(Self.ids[0]).due", "\(Self.ids[0]).state"] {
      XCTAssertTrue(first.frame.contains(el(app, "deck.row.\(id)").frame), "deck.row.\(id) outside its row at XL")
    }
    XCTAssertLessThan(el(app, "deck.row.\(Self.ids[0]).due").frame.maxX,
                      el(app, "deck.row.\(Self.ids[0]).state").frame.minX, "due/state overlap at XL")

    first.tap()
    waitForLabel(el(app, "editor.title"), "Edit card")
    snapshot("editor-xl", appearance: .light)
    // Only the editor's own elements: the deck and study stay in the hierarchy under the sheet.
    let editorIDs = ["editor.title", "editor.save", "editor.close", "editor.front", "editor.back"]
    for (i, a) in editorIDs.enumerated() {
      for b in editorIDs[(i + 1)...] {
        let overlap = el(app, a).frame.intersection(el(app, b).frame)
        XCTAssertTrue(overlap.isNull || overlap.width < 1 || overlap.height < 1,
                      "\(a) \(el(app, a).frame) overlaps \(b) \(el(app, b).frame) at XL")
      }
    }
    for id in ["editor.front", "editor.back", "editor.save", "editor.close"] {
      XCTAssertTrue(window.contains(el(app, id).frame), "\(id) outside the window at XL: \(el(app, id).frame)")
    }
    XCTAssertTrue(el(app, "editor.save").isHittable && el(app, "editor.close").isHittable)
    XCTAssertGreaterThanOrEqual(el(app, "editor.front").frame.minY, el(app, "editor.title").frame.maxY - 1,
                                "editor.front overlaps the title at XL")
    XCTAssertGreaterThanOrEqual(el(app, "editor.back").frame.minY, el(app, "editor.front").frame.maxY - 1,
                                "editor.back overlaps editor.front at XL")
  }

  // MARK: - #13 live API

  /// #13: scripts/e2e.sh (seeded greeting/gratitude). Add "feline"/"cat" from study → in the deck at the top;
  /// swipe-delete it → gone after reopening the deck, and gone from the API.
  @MainActor
  func testDeck_addFromStudyThenDelete_liveAPI() throws {
    guard let url = ProcessInfo.processInfo.environment["LA_CARTE_API_URL"], !url.isEmpty else {
      throw XCTSkip("LA_CARTE_API_URL not set — run scripts/e2e.sh")
    }
    addTeardownBlock { [self] in try? self.deleteLiveCards(url, front: "feline") }
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .live(url))
    XCTAssertTrue(el(app, "study.front").waitFor(timeout: 10) || el(app, "study.message").exists)
    el(app, "study.add").tap()
    assertNewCardEditor(app)
    el(app, "editor.front").typeText("feline")
    el(app, "editor.back").tap()
    el(app, "editor.back").typeText("cat")
    el(app, "editor.save").tap()
    waitForAbsence(el(app, "editor.title"), timeout: 10, "editor still open after saving")

    openDeck(app)
    waitUntil("3 rows in the live deck") { self.rowIDs(app).count == 3 }
    let felineID = rowIDs(app)[0]
    assertRow(app, felineID, front: "feline", back: "cat", due: "Due now", state: "new")
    snapshot("deck-live", appearance: .light)
    XCTAssertTrue(try liveCards(url).contains { $0["front"] as? String == "feline" }, "feline not in the API")

    swipeAndDelete(app, felineID)
    waitForAbsence(row(app, felineID), "feline row still shown after delete")
    swipeSheetDown(app, from: el(app, "deck.title"))
    waitForAbsence(el(app, "deck.title"))
    openDeck(app)
    waitUntil("2 rows after reopening") { self.rowIDs(app).count == 2 }
    XCTAssertFalse(row(app, felineID).exists, "feline row back after reopening the deck")
    snapshot("deck-live-after-delete", appearance: .light)
    XCTAssertFalse(try liveCards(url).contains { $0["front"] as? String == "feline" }, "feline still in the API")
  }

  // MARK: - Helpers

  @MainActor
  private func openDeck(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let button = el(app, "study.deck")
    XCTAssertTrue(button.waitFor(timeout: 10), "study.deck missing", file: file, line: line)
    button.tap()
    waitForLabel(el(app, "deck.title"), "Cards", file: file, line: line)
  }

  @MainActor
  private func row(_ app: XCUIApplication, _ id: String) -> XCUIElement { el(app, "deck.row.\(id.uppercased())") }

  /// The swipe action `deck.row.<id>.delete` (spec 002 #4, as changed by 003).
  @MainActor
  private func deleteAction(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "identifier ==[c] %@", "deck.row.\(id).delete")).firstMatch
  }

  @MainActor
  private func swipeAndDelete(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
    row(app, id).swipeLeft()
    let delete = deleteAction(app, id)
    XCTAssertTrue(delete.waitFor(timeout: 3), "no deck.row.\(id).delete after swiping left", file: file, line: line)
    delete.tap()
  }

  /// The swipe action is filled with the system destructive red (not ink, not a token).
  @MainActor
  private func assertSystemRed(_ app: XCUIApplication, _ action: XCUIElement,
                               file: StaticString = #filePath, line: UInt = #line) {
    let f = action.frame
    let c = ColorProbe(screenOf: app).color(at: CGPoint(x: f.midX, y: f.minY + f.height * 0.2))
    XCTAssertTrue(c.r > 200 && c.g < 110 && c.b < 110, "Delete action fill \(c) at \(f) is not system red",
                  file: file, line: line)
  }

  @MainActor
  private func rowText(_ app: XCUIApplication, _ id: String, _ text: String) -> XCUIElement {
    row(app, id).staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
  }

  /// Card ids (uppercase, as Swift prints UUIDs) of the rows, top to bottom, from one atomic hierarchy snapshot.
  @MainActor
  private func rowIDs(_ app: XCUIApplication) -> [String] {
    guard let root = try? app.snapshot() else { return [] }
    var rows: [(String, CGFloat)] = []
    func walk(_ node: XCUIElementSnapshot) {
      let id = node.identifier
      if id.hasPrefix("deck.row."), !id.hasSuffix(".due"), !id.hasSuffix(".state"), !id.lowercased().hasSuffix(".delete"), !node.frame.isEmpty,
         !rows.contains(where: { $0.0 == id }) {
        rows.append((id, node.frame.minY))
      }
      node.children.forEach(walk)
    }
    walk(root)
    return rows.sorted { $0.1 < $1.1 }.map { String($0.0.dropFirst("deck.row.".count)).uppercased() }
  }

  @MainActor
  private func waitForRows(_ app: XCUIApplication, _ expected: [String], timeout: TimeInterval = 10,
                           file: StaticString = #filePath, line: UInt = #line) {
    let deadline = Date().addingTimeInterval(timeout)
    var ids = rowIDs(app)
    while ids != expected.map({ $0.uppercased() }), Date() < deadline {
      Thread.sleep(forTimeInterval: 0.2)
      ids = rowIDs(app)
    }
    XCTAssertEqual(ids, expected.map { $0.uppercased() }, "deck rows", file: file, line: line)
  }

  @MainActor
  private func waitUntil(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                         _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
    XCTAssertTrue(condition(), "timed out waiting for: \(what)", file: file, line: line)
  }

  /// Text of an editor field, or "" when it only shows its placeholder.
  @MainActor
  private func fieldText(_ app: XCUIApplication, _ id: String) -> String {
    let value = el(app, id).value as? String ?? ""
    return ["Word or question", "Answer", "Front", "Back"].contains(value) ? "" : value
  }

  @MainActor
  private func hasFocus(_ element: XCUIElement) -> Bool {
    (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
  }

  /// Puts the cursor at the end of a one-line field, deletes its text and types `text`.
  @MainActor
  private func replaceText(_ app: XCUIApplication, _ id: String, with text: String,
                           file: StaticString = #filePath, line: UInt = #line) {
    let field = el(app, id)
    let old = fieldText(app, id)
    field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
    waitUntil("\(id) focused", file: file, line: line) { self.hasFocus(field) }
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 2) + text)
    XCTAssertEqual(fieldText(app, id), text, "\(id) text after replacing", file: file, line: line)
  }

  @MainActor
  private func assertNewCardEditor(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    waitForLabel(el(app, "editor.title"), "New card", file: file, line: line)
    XCTAssertEqual(fieldText(app, "editor.front"), "", "editor.front not empty", file: file, line: line)
    XCTAssertEqual(fieldText(app, "editor.back"), "", "editor.back not empty", file: file, line: line)
    waitUntil("editor.front focused on a new card", timeout: 5, file: file, line: line) {
      self.hasFocus(self.el(app, "editor.front"))
    }
    XCTAssertFalse(el(app, "editor.save").isEnabled, "editor.save enabled with empty fields", file: file, line: line)
    assertEditorChrome(app, file: file, line: line)
  }

  /// Ref 03: title top-left; save then close (rightmost) circle buttons top-right, 44pt, same line; Front above Back.
  @MainActor
  private func assertEditorChrome(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let window = app.windows.firstMatch.frame
    let title = el(app, "editor.title").frame, save = el(app, "editor.save").frame, close = el(app, "editor.close").frame
    for (id, f) in [("editor.save", save), ("editor.close", close)] {
      XCTAssertEqual(f.width, 44, accuracy: 1, "\(id) not 44pt: \(f)", file: file, line: line)
      XCTAssertEqual(f.height, 44, accuracy: 1, "\(id) not 44pt: \(f)", file: file, line: line)
    }
    XCTAssertLessThan(title.minX, window.width / 4, "editor.title not left: \(title)", file: file, line: line)
    XCTAssertLessThan(save.maxX, close.minX, "editor.close is not right of editor.save", file: file, line: line)
    XCTAssertGreaterThan(close.maxX, window.width - 40, "editor.close not at the right edge: \(close)", file: file, line: line)
    XCTAssertEqual(save.minY, close.minY, accuracy: 0.5, "save/close not aligned", file: file, line: line)
    let front = el(app, "editor.front").frame, back = el(app, "editor.back").frame
    XCTAssertGreaterThanOrEqual(front.minY, max(title.maxY, close.maxY) - 1, "editor.front under the header",
                                file: file, line: line)
    XCTAssertGreaterThanOrEqual(back.minY, front.maxY - 1, "editor.back not below editor.front", file: file, line: line)
  }

  @MainActor
  private func assertRow(_ app: XCUIApplication, _ id: String, front: String, back: String, due: String, state: String,
                         file: StaticString = #filePath, line: UInt = #line) {
    let row = row(app, id)
    XCTAssertTrue(row.waitFor(timeout: 5), "deck.row.\(id) missing", file: file, line: line)
    let dueEl = el(app, "deck.row.\(id.uppercased()).due"), stateEl = el(app, "deck.row.\(id.uppercased()).state")
    waitForLabel(dueEl, due, file: file, line: line)
    waitForLabel(stateEl, state, file: file, line: line)
    let frontEl = rowText(app, id, front), backEl = rowText(app, id, back)
    XCTAssertTrue(frontEl.exists, "deck.row.\(id) doesn't show front '\(front)'", file: file, line: line)
    XCTAssertTrue(backEl.exists, "deck.row.\(id) doesn't show back '\(back)'", file: file, line: line)
    let r = row.frame, d = dueEl.frame, s = stateEl.frame, f = frontEl.frame, b = backEl.frame
    // Meta line: due left, state right, same line, on top.
    XCTAssertLessThan(d.midX, r.midX, "due not on the left", file: file, line: line)
    XCTAssertGreaterThan(s.midX, r.midX, "state not on the right", file: file, line: line)
    XCTAssertEqual(d.midY, s.midY, accuracy: 1, "due/state not on one line", file: file, line: line)
    XCTAssertGreaterThanOrEqual(f.minY, d.maxY - 1, "front not under the meta line", file: file, line: line)
    XCTAssertGreaterThanOrEqual(b.minY, f.maxY - 1, "back not under the front", file: file, line: line)
    XCTAssertEqual(f.minX, d.minX, accuracy: 1, "front not left-aligned with the meta line", file: file, line: line)
    // 1 line each: front and back are as tall as each other (same .body style).
    XCTAssertEqual(f.height, b.height, accuracy: 1, "front/back heights differ (wrapping?)", file: file, line: line)
    XCTAssertLessThan(f.height, d.height * 2.2, "front taller than one line: \(f)", file: file, line: line)
    for (name, t) in [("due", d), ("state", s), ("front", f), ("back", b)] {
      XCTAssertTrue(r.insetBy(dx: -0.5, dy: -0.5).contains(t), "\(name) outside its row: \(t) in \(r)", file: file, line: line)
    }
  }

  /// Ref 04 header: "Cards" title left, `deck.add` 44pt circle right on the same line, search under it.
  @MainActor
  private func assertDeckChrome(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let window = app.windows.firstMatch.frame
    let title = el(app, "deck.title").frame, add = el(app, "deck.add").frame, search = el(app, "deck.search").frame
    XCTAssertEqual(add.width, 44, accuracy: 1, "deck.add not 44pt: \(add)", file: file, line: line)
    XCTAssertEqual(add.height, 44, accuracy: 1, "deck.add not 44pt: \(add)", file: file, line: line)
    XCTAssertLessThan(title.minX, 30, "deck.title not left: \(title)", file: file, line: line)
    XCTAssertGreaterThan(add.maxX, window.width - 30, "deck.add not right: \(add)", file: file, line: line)
    XCTAssertEqual(title.midY, add.midY, accuracy: 3, "title and add not on one line", file: file, line: line)
    XCTAssertGreaterThanOrEqual(search.minY, max(title.maxY, add.maxY) - 1, "search not under the title row",
                                file: file, line: line)
    if let first = rowIDs(app).first {
      XCTAssertGreaterThanOrEqual(row(app, first).frame.minY, search.maxY, "rows overlap search", file: file, line: line)
    }
  }

  /// Ref 04: rows inset from the edges, ~8pt apart.
  @MainActor
  private func assertRowSpacing(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let window = app.windows.firstMatch.frame
    let frames = rowIDs(app).map { row(app, $0).frame }
    for f in frames {
      XCTAssertGreaterThanOrEqual(f.minX, 12, "row not inset from the left: \(f)", file: file, line: line)
      XCTAssertLessThanOrEqual(f.maxX, window.maxX - 12, "row not inset from the right: \(f)", file: file, line: line)
    }
    for (a, b) in zip(frames, frames.dropFirst()) {
      XCTAssertEqual(b.minY - a.maxY, 8, accuracy: 2, "gap between rows is not 8pt: \(a) / \(b)", file: file, line: line)
    }
  }

  /// Pixel checks on a screenshot: rows are `surface`, the gaps and the area around/below rows are `background`
  /// (no separators, no list background), the search field sits on `surface`. List rows can't be rendered in unit
  /// tests (`ImageRenderer` draws a List as a placeholder), so this stays here.
  @MainActor
  private func assertDeckColors(_ app: XCUIApplication, appearance: XCUIDevice.Appearance,
                                file: StaticString = #filePath, line: UInt = #line) {
    let p = Palette.of(appearance)
    let window = app.windows.firstMatch.frame
    let frames = rowIDs(app).map { row(app, $0).frame }
    guard frames.count >= 2 else { return XCTFail("need 2 rows for colour checks", file: file, line: line) }
    let search = el(app, "deck.search").frame
    waitForColors(app, [
      ("row fill", CGPoint(x: frames[0].minX + 6, y: frames[0].midY), p.surface),
      ("gap between rows", CGPoint(x: frames[0].midX, y: (frames[0].maxY + frames[1].minY) / 2), p.background),
      ("left of a row", CGPoint(x: frames[0].minX / 2, y: frames[0].midY), p.background),
      ("below the rows", CGPoint(x: window.midX, y: frames.last!.maxY + 60), p.background),
      ("near the bottom edge", CGPoint(x: window.midX, y: window.maxY - 4), p.background),
      ("search field fill", CGPoint(x: search.maxX + 6, y: search.midY), p.surface),
    ], timeout: 0, file: file, line: line)
  }

  // MARK: Live API helpers

  private func liveRequest(_ url: String, method: String = "GET") -> Data? {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = method
    if let token = ProcessInfo.processInfo.environment["LA_CARTE_API_TOKEN"] {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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

  private func deleteLiveCards(_ url: String, front: String) throws {
    for card in try liveCards(url) where card["front"] as? String == front {
      _ = liveRequest(url + "/cards/\(card["id"] as? String ?? "")", method: "DELETE")
    }
  }
}
