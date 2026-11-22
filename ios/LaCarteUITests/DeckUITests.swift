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
    swipeSheetDown(app, from: deckTitle(app))
    waitForAbsence(deckTitle(app), "deck sheet still open after swiping down")
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
    // Spec 014c #1: the deck lists notes.
    let lists = server.requests.filter { StubDeck.route($0.path) == "/notes" && $0.method == "GET" }
    XCTAssertFalse(lists.isEmpty, "no GET /notes")
    for r in lists {
      XCTAssertEqual(StubDeck.queryItems(r.path)["limit"], "500", "GET /notes without limit=500: \(r.path)")
    }
    server.stop()
  }

  // MARK: - #2 search

  /// #2 + 009a #3: the system search field ("Search" prompt) filters: "ser" leaves only serendipity; its clear button
  /// brings all three back. (Debounce / query logic: DeckFeatureTests.searchIsDebouncedAndClearingShowsEveryCard.)
  @MainActor
  func testDeck_search() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock)
    openDeck(app)
    waitForRows(app, Self.ids)
    let search = deckSearch(app)
    XCTAssertEqual(search.placeholderValue, "Search", "search prompt")
    search.tap()
    search.typeText("ser")
    waitForRows(app, [Self.ids[0]])
    snapshot("deck-search", appearance: .light)
    // The field's own clear button ("Clear text" in English), not delete keystrokes (flaky on CI).
    let named = search.buttons["Clear text"]
    XCTAssertTrue(poll(timeout: 3) { named.exists || search.buttons.firstMatch.exists },
                  "no clear button in the search field")
    (named.exists ? named : search.buttons.firstMatch).tap()
    waitForRows(app, Self.ids)
    snapshot("deck-search-cleared", appearance: .light)
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

  /// Offline Deck shows `deck.retry`; tapping it reloads once the stub is back up.
  @MainActor
  func testDeck_offlineThenRetry() throws {
    XCUIDevice.shared.appearance = .light
    let server = StubAPIServer { request in
      if request.path.hasPrefix("/notes") || request.path.hasPrefix("/cards") { return .init(body: "[]") }
      return .init(status: 404, body: "{}")
    }
    try server.start()
    server.stop()
    let app = launch(api: .live(server.url))
    openDeck(app)
    waitForLabel(el(app, "deck.message"), "Can't reach your deck", timeout: 20)
    XCTAssertTrue(el(app, "deck.retry").waitFor(timeout: 5), "deck.retry missing offline")
    snapshot("deck-offline-retry", appearance: .light)
    try server.start()
    el(app, "deck.retry").tap()
    waitForLabel(el(app, "deck.message"), "No cards yet", timeout: 10)
    XCTAssertFalse(el(app, "deck.retry").exists, "deck.retry still shown after reload")
    server.stop()
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
    swipeSheetDown(app, from: deckTitle(app))
    waitForAbsence(deckTitle(app))
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
    waitForSheet(app, "Edit card")
    XCTAssertEqual(fieldText(app, "editor.front"), Self.fixtures[2].front)
    XCTAssertEqual(fieldText(app, "editor.back"), Self.fixtures[2].back)
    assertEditorChrome(app)
    snapshot("editor-edit", appearance: .light)
    replaceText(app, "editor.back", with: "short-lived")
    XCTAssertTrue(el(app, "editor.save").isEnabled)
    el(app, "editor.save").tap()
    waitForAbsence(editorBar(app), "editor still open after saving")
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
    waitForAbsence(editorBar(app), "editor still open after saving")
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
    waitForAbsence(editorBar(app), "editor still open after saving")
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
    swipeSheetDown(app, from: deckTitle(app))
    waitForAbsence(deckTitle(app))
    waitForLabel(el(app, "study.front"), Self.fixtures[1].front)
    waitForLabel(el(app, "study.remaining"), "2 to review")
    snapshot("study-after-delete", appearance: .light)

    // Edit the (new) current card's front.
    openDeck(app)
    waitForRows(app, Array(Self.ids.dropFirst()))
    row(app, Self.ids[1]).tap()
    waitForSheet(app, "Edit card")
    replaceText(app, "editor.front", with: "la carta")
    el(app, "editor.save").tap()
    waitForAbsence(editorBar(app))
    swipeSheetDown(app, from: deckTitle(app))
    waitForAbsence(deckTitle(app))
    waitForLabel(el(app, "study.front"), "la carta")

    // Add from the deck.
    openDeck(app)
    el(app, "deck.add").tap()
    assertNewCardEditor(app)
    el(app, "editor.front").typeText("feline")
    el(app, "editor.back").tap()
    el(app, "editor.back").typeText("cat")
    el(app, "editor.save").tap()
    waitForAbsence(editorBar(app))
    swipeSheetDown(app, from: deckTitle(app))
    waitForAbsence(deckTitle(app))
    waitForLabel(el(app, "study.remaining"), "3 to review")
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
    // CI runners are slow to present the sheet and focus the field: wait generously, tap the field if focus never comes.
    XCTAssertTrue(editorBar(app).waitFor(timeout: 15), "editor sheet missing")
    let front = el(app, "editor.front")
    XCTAssertTrue(front.waitFor(timeout: 15), "editor.front missing")
    if !poll(timeout: 10, { self.hasFocus(front) || app.keyboards.firstMatch.exists }) || !hasFocus(front) {
      front.tap()
      waitUntil("editor.front focused after tapping it") { self.hasFocus(front) }
    }
    front.typeText("feline")
    el(app, "editor.back").tap()
    el(app, "editor.back").typeText("cat")
    el(app, "editor.save").tap()
    waitForAbsence(editorBar(app), timeout: 10, "editor still open after saving")

    openDeck(app)
    waitUntil("3 rows in the live deck") { self.rowIDs(app).count == 3 }
    let felineID = rowIDs(app)[0]
    assertRow(app, felineID, front: "feline", back: "cat", due: "Due now", state: "new")
    snapshot("deck-live", appearance: .light)
    XCTAssertTrue(try liveCards(url).contains { $0["front"] as? String == "feline" }, "feline not in the API")

    swipeAndDelete(app, felineID)
    waitForAbsence(row(app, felineID), "feline row still shown after delete")
    swipeSheetDown(app, from: deckTitle(app))
    waitForAbsence(deckTitle(app))
    openDeck(app)
    waitUntil("2 rows after reopening") { self.rowIDs(app).count == 2 }
    XCTAssertFalse(row(app, felineID).exists, "feline row back after reopening the deck")
    snapshot("deck-live-after-delete", appearance: .light)
    XCTAssertFalse(try liveCards(url).contains { $0["front"] as? String == "feline" }, "feline still in the API")
  }

  // MARK: - Spec 009a: native deck

  /// (theme argument, device appearance, palette, screenshot suffix): light, dark, forest. Only for checks whose
  /// colours differ per look.
  static let looks: [(theme: String, appearance: XCUIDevice.Appearance, palette: Palette, name: String)] = [
    ("system", .light, .light, ""), ("system", .dark, .dark, ""), ("forest", .light, .forest, "-forest"),
  ]

  /// 009a #1: a large "Cards" navigation title on the left that collapses to an inline, centered title when the
  /// list scrolls.
  @MainActor
  func testDeck_largeTitleCollapsesOnScroll() throws {
    let base = Date(timeIntervalSince1970: 1_767_225_600)
    let deck = StubDeck((1...24).map { i in
      .init(id: String(format: "bbbbbbbb-0000-0000-0000-%012d", i), front: "word \(i)", back: "answer \(i)",
            createdAt: base.addingTimeInterval(-Double(i) * 60))
    })
    let server = StubAPIServer(handler: deck.handle)
    try server.start()
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .live(server.url))
    openDeck(app)
    waitUntil("rows loaded") { self.rowIDs(app).count >= 5 }
    let window = app.windows.firstMatch.frame
    let large = deckTitleText(app).frame
    XCTAssertLessThan(large.minX, 30, "large title not on the left: \(large)")
    XCTAssertGreaterThanOrEqual(large.height, 34, "title not large before scrolling: \(large)")
    snapshot("deck-large-title", appearance: .light)
    let start = row(app, rowIDs(app)[2]).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    start.press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
    waitUntil("title collapsed to inline") {
      let f = self.deckTitleText(app).frame
      return f.height < 30 && abs(f.midX - window.midX) < 20
    }
    XCTAssertTrue(deckTitle(app).exists, "navigation bar gone after scrolling")
    snapshot("deck-collapsed", appearance: .light)
    server.stop()
  }

  /// 009a #2: `deck.settings` (gearshape) and `deck.add` (plus) are toolbar buttons tinted ink, never pink; they open
  /// Settings and the "New card" editor. Light, dark, forest (the tint differs per look).
  @MainActor
  func testDeck_toolbarButtons() {
    for look in Self.looks {
      XCUIDevice.shared.appearance = look.appearance
      let app = launch(api: .mock, theme: look.theme)
      openDeck(app)
      waitForRows(app, Self.ids)
      assertDeckChrome(app)
      let ink = look.palette.ink
      let probe = ColorProbe(screenOf: app)
      for id in ["deck.settings", "deck.add"] {
        let f = el(app, id).frame
        XCTAssertTrue(pinkPoints(probe, in: f, theme: look.theme, appearance: look.appearance).isEmpty, "\(id) is pink")
        let glyph = inkiest(probe, in: f.insetBy(dx: f.width * 0.25, dy: f.height * 0.25), ink: ink)
        XCTAssertLessThan(glyph, 60, "\(id) glyph not ink \(ink) (closest distance \(glyph))")
      }
      if look.theme == "system", look.appearance == .light {  // navigation: once is enough
        el(app, "deck.settings").tap()
        waitForSheet(app, "Settings", timeout: 5)
        snapshot("deck-settings-open", appearance: .light)
        el(app, "settings.close").tap()
        waitForAbsence(sheetBar(app, "Settings"))
        el(app, "deck.add").tap()
        waitForSheet(app, "New card")
        el(app, "editor.close").tap()
        waitForAbsence(editorBar(app))
      }
      app.terminate()
    }
  }

  /// 009a #4: no matches → the system search empty state (`ContentUnavailableView.search`).
  @MainActor
  func testDeck_noMatchesSystemSearchState() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock)
    openDeck(app)
    waitForRows(app, Self.ids)
    deckSearch(app).tap()
    deckSearch(app).typeText("zzz")
    waitForRows(app, [])
    // The system view has no identifier of ours: its title is "No Results for “zzz”".
    let title = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'zzz'")).firstMatch
    XCTAssertTrue(title.waitFor(timeout: 5), "no ContentUnavailableView.search title mentioning the query")
    snapshot("deck-no-matches", appearance: .light)
  }

  /// 009a #5: "No cards yet" / "Can't reach your deck" are ContentUnavailableViews, also in forest.
  @MainActor
  func testDeck_messagesForest() throws {
    XCUIDevice.shared.appearance = .light
    let deck = StubDeck([])
    let server = StubAPIServer(handler: deck.handle)
    try server.start()
    var app = launch(api: .live(server.url), theme: "forest")
    openDeck(app)
    waitForLabel(el(app, "deck.message"), "No cards yet")
    snapshot("deck-empty-forest", appearance: .light)
    app.terminate()
    server.stop()
    app = launch(api: .live(unreachableAPIURL), theme: "forest")
    openDeck(app)
    waitForLabel(el(app, "deck.message"), "Can't reach your deck", timeout: 20)
    snapshot("deck-offline-forest", appearance: .light)
  }

  /// 009a #6: long-press → "Edit" (`deck.row.<id>.edit`) opens the editor for that card, "Delete"
  /// (`deck.row.<id>.contextDelete`) removes the row.
  @MainActor
  func testDeck_contextMenu() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock)
    openDeck(app)
    waitForRows(app, Self.ids)
    row(app, Self.ids[2]).press(forDuration: 1)
    let edit = el(app, "deck.row.\(Self.ids[2].uppercased()).edit")
    let delete = el(app, "deck.row.\(Self.ids[2].uppercased()).contextDelete")
    XCTAssertTrue(edit.waitFor(timeout: 3), "no deck.row.<id>.edit after a long press")
    XCTAssertTrue(delete.exists, "no deck.row.<id>.contextDelete after a long press")
    XCTAssertEqual(edit.label, "Edit")
    XCTAssertEqual(delete.label, "Delete")
    XCTAssertLessThan(edit.frame.midY, delete.frame.midY, "Edit not above Delete")
    snapshot("deck-context-menu", appearance: .light)
    edit.tap()
    waitForSheet(app, "Edit card")
    XCTAssertEqual(fieldText(app, "editor.front"), Self.fixtures[2].front)
    el(app, "editor.close").tap()
    waitForAbsence(editorBar(app))

    row(app, Self.ids[1]).press(forDuration: 1)
    let delete1 = el(app, "deck.row.\(Self.ids[1].uppercased()).contextDelete")
    XCTAssertTrue(delete1.waitFor(timeout: 3), "no contextDelete on the second long press")
    delete1.tap()
    waitForRows(app, [Self.ids[0], Self.ids[2]], timeout: 3)
  }

  /// 009a #8 + design-system accent rule: with the search field focused and text typed, pink shows only inside the
  /// search field (cursor); toolbar, rows and the system Cancel button stay un-pinked. Light, dark, forest.
  @MainActor
  func testDeck_searchAccentOnly() {
    for look in Self.looks {
      XCUIDevice.shared.appearance = look.appearance
      let app = launch(api: .mock, theme: look.theme)
      openDeck(app)
      waitForRows(app, Self.ids)
      let search = deckSearch(app)
      search.tap()
      search.typeText("ser")
      waitForRows(app, [Self.ids[0]])
      // The cursor blinks (~0.5 s on, ~0.5 s off): one screenshot can land in the off phase (seen on CI, iOS 26).
      // Capture frames back to back over ~1.2 s first (no pixel work in between, so the sampling stays dense),
      // then pass if any frame shows the accent inside the field, and that frame shows it nowhere else.
      let field = search.frame, window = app.windows.firstMatch.frame
      var frames: [CGImage] = []
      let end = Date().addingTimeInterval(1.2)
      repeat {
        frames.append(XCUIScreen.main.screenshot().image.cgImage!)
        Thread.sleep(forTimeInterval: 0.05)
      } while Date() < end
      snapshot("deck-search-focused\(look.name)", appearance: look.appearance)
      // Scan only the field per frame (cheap); then the whole screen of the frame that shows the cursor.
      let probes = frames.map { ColorProbe($0, pointWidth: window.width) }
      let lit = probes.first { !pinkPoints($0, in: field, theme: look.theme, appearance: look.appearance).isEmpty }
      XCTAssertNotNil(lit, "search cursor is not Theme.accent (no pink inside \(field) in \(frames.count) frames over 1.2 s)")
      let pink = pinkPoints(lit ?? probes[0], in: window, theme: look.theme, appearance: look.appearance)
      let outside = pink.filter { !field.insetBy(dx: -2, dy: -2).contains($0) }
      if let box = outside.first.map({ p in outside.reduce(CGRect(origin: p, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) } }) {
        XCTFail("pink outside the search field (\(outside.count) pt) in \(box), look \(look.theme)/\(look.appearance)")
      }
      app.terminate()
    }
  }

  // MARK: 009a pixel helpers

  /// Points (1pt grid) whose color is `Theme.accent` (#B8325A light, #ED6E8C dark/forest) within 45 per channel.
  @MainActor
  private func pinkPoints(_ probe: ColorProbe, in rect: CGRect, theme: String,
                          appearance: XCUIDevice.Appearance) -> [CGPoint] {
    let accent = (theme == "forest" || appearance == .dark) ? RGB(237, 110, 140) : RGB(184, 50, 90)
    var out: [CGPoint] = []
    var y = rect.minY.rounded(.up)
    while y < rect.maxY {
      var x = rect.minX.rounded(.up)
      while x < rect.maxX {
        for dx in [0.0, 0.34, 0.67] {  // the cursor is ~2pt wide: sample at sub-point steps horizontally
          let c = probe.color(at: CGPoint(x: x + dx, y: y))
          if c.isClose(to: accent, tolerance: 44), c.r > c.g + 60 {
            out.append(CGPoint(x: x, y: y)); break
          }
        }
        x += 1
      }
      y += 1
    }
    return out
  }

  /// Smallest max-channel distance to `ink` among the points of `rect`.
  @MainActor
  private func inkiest(_ probe: ColorProbe, in rect: CGRect, ink: RGB) -> Int {
    probe.colors(in: rect, step: 0.34).map { max(abs($0.r - ink.r), abs($0.g - ink.g), abs($0.b - ink.b)) }.min() ?? 255
  }

  // MARK: - Helpers

  @MainActor
  private func openDeck(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let button = el(app, "study.deck")
    XCTAssertTrue(button.waitFor(timeout: 10), "study.deck missing", file: file, line: line)
    button.tap()
    waitForDeckTitle(app, file: file, line: line)
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
      if id.hasPrefix("deck.row."), !id.hasSuffix(".due"), !id.hasSuffix(".state"), !id.lowercased().hasSuffix(".delete"), !id.hasSuffix(".edit"), !id.lowercased().hasSuffix(".contextdelete"), !id.hasSuffix(".photo"), !node.frame.isEmpty,
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
    var ids: [String] = []
    _ = poll(timeout: timeout) {
      ids = self.rowIDs(app)
      return ids == expected.map { $0.uppercased() }
    }
    XCTAssertEqual(ids, expected.map { $0.uppercased() }, "deck rows", file: file, line: line)
  }

  @MainActor
  private func waitUntil(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                         _ condition: () -> Bool) {
    XCTAssertTrue(poll(timeout: timeout, condition), "timed out waiting for: \(what)", file: file, line: line)
  }

  /// Text of an editor field, or "" when it only shows its placeholder.
  @MainActor
  private func fieldText(_ app: XCUIApplication, _ id: String) -> String {
    let value = el(app, id).value as? String ?? ""
    return Self.editorPlaceholders.contains(value) ? "" : value
  }

  private static let editorPlaceholders = ["Word or question", "Answer", "Front", "Back"]

  @MainActor
  private func replaceText(_ app: XCUIApplication, _ id: String, with text: String,
                           file: StaticString = #filePath, line: UInt = #line) {
    replaceText(el(app, id), with: text, placeholders: Self.editorPlaceholders, file: file, line: line)
  }

  @MainActor
  private func assertNewCardEditor(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    waitForSheet(app, "New card", file: file, line: line)
    XCTAssertEqual(fieldText(app, "editor.front"), "", "editor.front not empty", file: file, line: line)
    XCTAssertEqual(fieldText(app, "editor.back"), "", "editor.back not empty", file: file, line: line)
    waitUntil("editor.front focused on a new card", timeout: 5, file: file, line: line) {
      self.hasFocus(self.el(app, "editor.front"))
    }
    XCTAssertFalse(el(app, "editor.save").isEnabled, "editor.save enabled with empty fields", file: file, line: line)
    assertEditorChrome(app, file: file, line: line)
  }

  /// Spec 009b #1: native sheet. Inline nav title centred; `editor.close` in the leading slot, `editor.save` in the
  /// trailing slot, same line; Front above Back under the bar.
  @MainActor
  private func assertEditorChrome(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let window = app.windows.firstMatch.frame
    let bar = editorBar(app)
    XCTAssertTrue(bar.exists, "no editor navigation bar", file: file, line: line)
    let title = sheetTitle(app, bar.identifier).frame
    let save = el(app, "editor.save").frame, close = el(app, "editor.close").frame
    for id in ["editor.save", "editor.close"] {
      // Native iOS 26 toolbar glass buttons: system size (36pt frame, larger hit area), accepted by 009b QA.
      XCTAssertTrue(el(app, id).exists && el(app, id).isHittable, "\(id) missing or not hittable", file: file, line: line)
    }
    XCTAssertEqual(title.midX, window.midX, accuracy: 4, "inline title not centred: \(title)", file: file, line: line)
    XCTAssertLessThan(close.minX, window.width / 4, "editor.close not leading: \(close)", file: file, line: line)
    XCTAssertGreaterThan(save.maxX, window.width * 3 / 4, "editor.save not trailing: \(save)", file: file, line: line)
    XCTAssertEqual(save.midY, close.midY, accuracy: 1, "save/close not aligned", file: file, line: line)
    XCTAssertEqual(title.midY, close.midY, accuracy: 3, "title not on the buttons' line", file: file, line: line)
    XCTAssertEqual(el(app, "editor.save").label, "Save", "editor.save label", file: file, line: line)
    let front = el(app, "editor.front").frame, back = el(app, "editor.back").frame
    XCTAssertGreaterThanOrEqual(front.minY, max(title.maxY, close.maxY) - 1, "editor.front under the bar",
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

  /// Spec 009a #1-#3: large "Cards" title on the left, settings + add toolbar buttons top-right (above the title),
  /// the system search field under the title, rows under the search field.
  @MainActor
  private func assertDeckChrome(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let window = app.windows.firstMatch.frame
    let title = deckTitleText(app).frame, add = el(app, "deck.add").frame, gear = el(app, "deck.settings").frame
    let search = deckSearch(app).frame
    XCTAssertTrue(deckTitleText(app).exists, "no \"Cards\" text in the navigation bar", file: file, line: line)
    XCTAssertLessThan(title.minX, 30, "large title not left-aligned: \(title)", file: file, line: line)
    XCTAssertGreaterThanOrEqual(title.height, 34, "title not large: \(title)", file: file, line: line)
    XCTAssertGreaterThan(add.maxX, window.width - 30, "deck.add not right: \(add)", file: file, line: line)
    XCTAssertLessThan(gear.maxX, add.minX + 1, "deck.settings not left of deck.add", file: file, line: line)
    XCTAssertEqual(gear.midY, add.midY, accuracy: 1, "settings and add not on one line", file: file, line: line)
    XCTAssertLessThanOrEqual(max(add.maxY, gear.maxY), title.minY + 1, "toolbar not above the large title",
                             file: file, line: line)
    XCTAssertGreaterThanOrEqual(search.minY, title.maxY - 1, "search not under the title", file: file, line: line)
    XCTAssertGreaterThan(search.width, window.width * 0.6, "search field not full width: \(search)", file: file, line: line)
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
  /// (no separators, no list background). List rows can't be rendered in unit
  /// tests (`ImageRenderer` draws a List as a placeholder), so this stays here.
  @MainActor
  private func assertDeckColors(_ app: XCUIApplication, appearance: XCUIDevice.Appearance,
                                file: StaticString = #filePath, line: UInt = #line) {
    let p = Palette.of(appearance)
    let window = app.windows.firstMatch.frame
    let frames = rowIDs(app).map { row(app, $0).frame }
    guard frames.count >= 2 else { return XCTFail("need 2 rows for colour checks", file: file, line: line) }
    waitForColors(app, [
      ("row fill", CGPoint(x: frames[0].minX + 6, y: frames[0].midY), p.surface),
      ("gap between rows", CGPoint(x: frames[0].midX, y: (frames[0].maxY + frames[1].minY) / 2), p.background),
      ("left of a row", CGPoint(x: frames[0].minX / 2, y: frames[0].midY), p.background),
      ("below the rows", CGPoint(x: window.midX, y: frames.last!.maxY + 60), p.background),
      ("near the bottom edge", CGPoint(x: window.midX, y: window.maxY - 4), p.background),
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

// MARK: - Spec 009b: native editor sheet, discard protection

extension DeckUITests {
  /// 009b #2: with unsaved changes swipe-down doesn't dismiss and `editor.close` asks "Discard changes?";
  /// Keep editing leaves the text, Discard dismisses. Without changes (incl. whitespace-only, or an edit typed
  /// back to the original), `editor.close` and swipe-down dismiss at once.
  @MainActor
  func testEditor_discardProtection() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock)
    openDeck(app)
    waitForRows(app, Self.ids)

    // New card: typed text → swipe-down blocked → dialog → Keep editing → Discard.
    el(app, "deck.add").tap()
    waitForSheet(app, "New card")
    el(app, "editor.front").typeText("feline")
    for _ in 0..<2 {  // first drag may only drop the keyboard; nothing to poll for: the sheet must stay
      swipeSheetDown(app, from: editorBar(app))
      Thread.sleep(forTimeInterval: 0.8)
    }
    XCTAssertTrue(editorBar(app).exists, "swipe-down dismissed the editor with unsaved changes")
    XCTAssertEqual(fieldText(app, "editor.front"), "feline", "text lost after the blocked swipe")
    el(app, "editor.close").tap()
    let discard = el(app, "editor.discard")
    XCTAssertTrue(discard.waitFor(timeout: 3), "editor.discard not reachable by id")
    XCTAssertEqual(discard.label, "Discard")
    XCTAssertTrue(app.staticTexts["Discard changes?"].exists, "dialog title missing")
    snapshot("editor-discard", appearance: .light)
    // "Keep editing": by id / label if iOS shows it; on iOS 26+ the dialog is a popover without its cancel
    // button, so keeping the text means tapping outside it (see the 009b report).
    let keep = el(app, "editor.keepEditing")
    if keep.exists {
      keep.tap()
    } else if app.buttons["Keep editing"].exists {
      app.buttons["Keep editing"].tap()
    } else {
      app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.45)).tap()
    }
    waitForAbsence(discard, "dialog still shown after Keep editing")
    XCTAssertTrue(editorBar(app).exists, "Keep editing closed the editor")
    XCTAssertEqual(fieldText(app, "editor.front"), "feline", "Keep editing changed the text")
    discardEdits(app)
    waitForRows(app, Self.ids)

    // New card, whitespace only: no change → close dismisses without a dialog.
    el(app, "deck.add").tap()
    waitForSheet(app, "New card")
    el(app, "editor.front").typeText("   ")
    el(app, "editor.close").tap()
    waitForAbsence(editorBar(app), "whitespace-only new card asked to discard / stayed open")
    XCTAssertFalse(el(app, "editor.discard").exists || app.buttons["Discard"].exists, "dialog for whitespace only")

    // Edit card: change then type the original back → no change → swipe-down dismisses.
    row(app, Self.ids[2]).tap()
    waitForSheet(app, "Edit card")
    replaceText(app, "editor.back", with: Self.fixtures[2].back + " ")
    for _ in 0..<2 where editorBar(app).exists {  // first drag may only drop the keyboard
      swipeSheetDown(app, from: editorBar(app))
      _ = poll(timeout: 1.5) { !self.editorBar(app).exists }
    }
    waitForAbsence(editorBar(app), "edit sheet with only trailing whitespace added didn't swipe away")

    // Edit card: real change → close → Discard → row unchanged.
    row(app, Self.ids[2]).tap()
    waitForSheet(app, "Edit card")
    replaceText(app, "editor.back", with: "short-lived")
    discardEdits(app)
    XCTAssertTrue(rowText(app, Self.ids[2], Self.fixtures[2].back).exists, "row changed after Discard")
  }
}

extension XCTestCase {
  /// Confirmation-dialog button: by its id (spec 009b), else by label. Records which one matched in the log.
  @MainActor
  func dialogButton(_ app: XCUIApplication, _ id: String, _ label: String,
                    file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
    let byID = el(app, id)
    if byID.waitFor(timeout: 3) {
      XCTContext.runActivity(named: "dialog button \(id): found by id") { _ in }
      return byID
    }
    let byLabel = app.buttons.matching(identifier: label).firstMatch
    XCTAssertTrue(byLabel.waitFor(timeout: 2), "\(id) / '\(label)' missing", file: file, line: line)
    XCTContext.runActivity(named: "dialog button \(id): NOT reachable by id, fell back to label") { _ in }
    print("QA-FALLBACK: \(id) not reachable by id, used label '\(label)'")
    return byLabel
  }

  /// `editor.close` with unsaved changes → "Discard changes?" → Discard → editor gone (spec 009b #2).
  @MainActor
  func discardEdits(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    el(app, "editor.close").tap()
    dialogButton(app, "editor.discard", "Discard", file: file, line: line).tap()
    waitForAbsence(editorBar(app), "editor still open after Discard", file: file, line: line)
  }
}
