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
  static let appearances: [XCUIDevice.Appearance] = [.light, .dark]

  override func setUp() {
    continueAfterFailure = false
  }

  // MARK: - #1 list, #12 swipe-down close

  /// #1: `study.deck` → "Cards", one row per card in API order, due/state meta line, front + back preview,
  /// styled like ref 04 (surface rows, radius 12, 8pt gap, no separators, background behind). #12: swipe down closes.
  @MainActor
  func testDeck_openFromStudy() {
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .mock)
      openDeck(app)
      waitForRows(app, Self.ids)
      for (i, id) in Self.ids.enumerated() {
        assertRow(app, id, front: Self.fixtures[i].front, back: Self.fixtures[i].back, due: "Due now", state: "new")
      }
      assertDeckChrome(app)
      assertRowSpacing(app)
      assertDeckColors(app, appearance: appearance)
      snapshot("deck", appearance: appearance)

      // #12: swipe down closes the sheet, back to study.
      swipeSheetDown(app, from: deckTitle(app))
      waitForAbsence(deckTitle(app), "deck sheet still open after swiping down")
      waitForLabel(el(app, "study.front"), Self.fixtures[0].front)
      app.terminate()
    }
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
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .mock)
      openDeck(app)
      waitForRows(app, Self.ids)
      let search = deckSearch(app)
      search.tap()
      search.typeText("ser")
      waitForRows(app, [Self.ids[0]])
      snapshot("deck-search", appearance: appearance)
      search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3))
      waitForRows(app, Self.ids)
      app.terminate()
    }
  }

  /// #2: the filter goes through `GET /cards?query=` after a debounce: typing "ser" quickly sends one query,
  /// "ser" (no "s" / "se"), and nothing is sent before 0.3s after the last keystroke.
  @MainActor
  func testDeck_searchDebounced() throws {
    XCUIDevice.shared.appearance = .light
    let (server, _) = try startStubDeck()
    let app = launch(api: .live(server.url))
    openDeck(app)
    waitForRows(app, stubOrder)
    let search = deckSearch(app)
    search.tap()
    let typed = Date()
    search.typeText("ser")
    // How long the 3 keystrokes took: on a slow runner a gap between two of them can exceed the 0.3s debounce,
    // and then an intermediate "s"/"se" query is correct behaviour, not a bug.
    let typing = Date().timeIntervalSince(typed)
    waitUntil("GET /cards?query=ser sent") { self.searchQueries(server).last == "ser" }
    waitForRows(app, [Self.ids[0]])
    let queries = searchQueries(server)
    if typing < 0.3 {
      XCTAssertEqual(queries, ["ser"], "typed in \(typing)s: expected a single debounced query 'ser', got \(queries)")
    } else {
      XCTAssertTrue(queries.allSatisfy { "ser".hasPrefix($0) } && queries.count <= 3 && Set(queries).count == queries.count,
                    "typed in \(typing)s: expected at most one query per prefix of 'ser', got \(queries)")
    }
    let first = server.requests.first { StubDeck.queryItems($0.path)["query"] == "ser" }
    XCTAssertGreaterThanOrEqual(first.map { $0.time.timeIntervalSince(typed) } ?? 0, 0.3,
                                "query sent less than 0.3s after typing started")
    server.stop()
  }

  // MARK: - #3 messages

  /// #3: empty deck → "No cards yet".
  @MainActor
  func testDeck_emptyDeck() throws {
    let deck = StubDeck([])
    let server = StubAPIServer(handler: deck.handle)
    try server.start()
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .live(server.url))
      openDeck(app)
      waitForLabel(el(app, "deck.message"), "No cards yet")
      waitForRows(app, [])
      snapshot("deck-empty", appearance: appearance)
      app.terminate()
    }
    server.stop()
  }

  /// #3: failed load → "Can't reach your deck".
  @MainActor
  func testDeck_loadFailed() {
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .live(unreachableAPIURL))
      waitForLabel(el(app, "study.message"), "Can't reach your deck", timeout: 20)
      openDeck(app)
      waitForLabel(el(app, "deck.message"), "Can't reach your deck", timeout: 20)
      waitForRows(app, [])
      snapshot("deck-offline", appearance: appearance)
      app.terminate()
    }
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
    XCTAssertTrue(delete.waitForExistence(timeout: 3), "no deck.row.<id>.delete after swiping left")
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

  /// #4: confirming calls `DELETE /cards/{id}`.
  @MainActor
  func testDeck_swipeToDeleteCallsAPI() throws {
    XCUIDevice.shared.appearance = .light
    let (server, deck) = try startStubDeck()
    let app = launch(api: .live(server.url))
    openDeck(app)
    waitForRows(app, stubOrder)
    swipeAndDelete(app, Self.ids[1])
    waitForRows(app, stubOrder.filter { $0 != Self.ids[1] }, timeout: 1.5)
    waitUntil("DELETE /cards/\(Self.ids[1]) sent") {
      server.requests.contains { $0.method == "DELETE" && $0.path.lowercased() == "/cards/\(Self.ids[1])" }
    }
    XCTAssertEqual(deck.cards.count, 2)
    server.stop()
  }

  /// #4 (dark): the Delete action stays system red in dark mode too.
  @MainActor
  func testDeck_swipeToDeleteDark() {
    XCUIDevice.shared.appearance = .dark
    let app = launch(api: .mock)
    openDeck(app)
    waitForRows(app, Self.ids)
    row(app, Self.ids[1]).swipeLeft()
    let delete = deleteAction(app, Self.ids[1])
    XCTAssertTrue(delete.waitForExistence(timeout: 3), "no deck.row.<id>.delete after swiping left")
    assertSystemRed(app, delete)
    snapshot("deck-swipe", appearance: .dark)
  }

  /// #4: a successful delete while searching reloads with the current query, so the list still matches the field.
  @MainActor
  func testDeck_deleteReloadsWithQuery() throws {
    XCUIDevice.shared.appearance = .light
    let (server, deck) = try startStubDeck()
    let app = launch(api: .live(server.url))
    openDeck(app)
    waitForRows(app, stubOrder)
    let search = deckSearch(app)
    search.tap()
    search.typeText("a")  // "la carte" and "ephemeral" match, "serendipity" doesn't
    waitForRows(app, [Self.ids[1], Self.ids[2]])
    swipeAndDelete(app, Self.ids[2])
    waitForRows(app, [Self.ids[1]], timeout: 3)
    waitUntil("GET /cards?query=a after the DELETE") {
      let reqs = server.requests
      guard let d = reqs.firstIndex(where: { $0.method == "DELETE" }) else { return false }
      return reqs[(d + 1)...].contains { StubDeck.route($0.path) == "/cards" && StubDeck.queryItems($0.path)["query"] == "a" }
    }
    let reqs = server.requests
    let d = reqs.firstIndex { $0.method == "DELETE" } ?? reqs.endIndex
    let unfiltered = reqs[d...].filter { StubDeck.route($0.path) == "/cards" && (StubDeck.queryItems($0.path)["query"] ?? "").isEmpty }
    XCTAssertTrue(unfiltered.isEmpty, "unfiltered GET /cards after the delete: \(reqs.map(\.path))")
    waitForRows(app, [Self.ids[1]])
    XCTAssertEqual(deck.cards.count, 2)
    snapshot("deck-delete-while-searching", appearance: .light)
    server.stop()
  }

  /// #4: a failing DELETE → the list is reloaded from the API, so the row comes back.
  @MainActor
  func testDeck_deleteFailureReloads() throws {
    XCUIDevice.shared.appearance = .light
    let (server, deck) = try startStubDeck()
    deck.writeStatus = 500
    let app = launch(api: .live(server.url))
    openDeck(app)
    waitForRows(app, stubOrder)
    swipeAndDelete(app, Self.ids[1])
    waitUntil("DELETE sent") { server.requests.contains { $0.method == "DELETE" } }
    waitForRows(app, stubOrder)
    let deleteIndex = server.requests.firstIndex { $0.method == "DELETE" }!
    XCTAssertTrue(server.requests[(deleteIndex + 1)...].contains { $0.method == "GET" && StubDeck.route($0.path) == "/cards" },
                  "no GET /cards after the failed DELETE: \(server.requests.map { "\($0.method) \($0.path)" })")
    snapshot("deck-delete-failed", appearance: .light)
    server.stop()
  }

  // MARK: - #5 edit

  /// #5: tapping a row → "Edit card" prefilled; changing the back + save → dismissed, row shows the new back.
  @MainActor
  func testDeck_editRow() {
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .mock)
      openDeck(app)
      waitForRows(app, Self.ids)
      row(app, Self.ids[2]).tap()
      waitForLabel(el(app, "editor.title"), "Edit card")
      XCTAssertEqual(fieldText(app, "editor.front"), Self.fixtures[2].front)
      XCTAssertEqual(fieldText(app, "editor.back"), Self.fixtures[2].back)
      assertEditorChrome(app)
      snapshot("editor-edit", appearance: appearance)
      replaceText(app, "editor.back", with: "short-lived")
      XCTAssertTrue(el(app, "editor.save").isEnabled)
      el(app, "editor.save").tap()
      waitForAbsence(el(app, "editor.title"), "editor still open after saving")
      waitUntil("row shows the new back") { self.rowText(app, Self.ids[2], "short-lived").exists }
      XCTAssertFalse(rowText(app, Self.ids[2], Self.fixtures[2].back).exists, "old back still shown")
      waitForRows(app, Self.ids)  // replaced in place
      snapshot("deck-after-edit", appearance: appearance)
      app.terminate()
    }
  }

  /// #5: save calls `PATCH /cards/{id}` with the new back.
  @MainActor
  func testDeck_editRowCallsPATCH() throws {
    XCUIDevice.shared.appearance = .light
    let (server, deck) = try startStubDeck()
    let app = launch(api: .live(server.url))
    openDeck(app)
    waitForRows(app, stubOrder)
    row(app, Self.ids[2]).tap()
    waitForLabel(el(app, "editor.title"), "Edit card")
    replaceText(app, "editor.back", with: "short-lived")
    el(app, "editor.save").tap()
    waitForAbsence(el(app, "editor.title"), "editor still open after saving")
    let patches = server.requests.filter { $0.method == "PATCH" }
    XCTAssertEqual(patches.map { $0.path.lowercased() }, ["/cards/\(Self.ids[2])"])
    XCTAssertTrue(patches.first?.body.contains("short-lived") ?? false, "PATCH body: \(patches.first?.body ?? "nil")")
    XCTAssertEqual(deck.cards.first { $0.id == Self.ids[2] }?.back, "short-lived")
    waitUntil("row shows the new back") { self.rowText(app, Self.ids[2], "short-lived").exists }
    server.stop()
  }

  // MARK: - #6 add from deck, #8 save disabled

  /// #6: `deck.add` → "New card", empty fields, front focused; #8 save disabled while a field is empty
  /// (after trimming); saving puts the new row at the top.
  @MainActor
  func testDeck_addFromDeck() {
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .mock)
      openDeck(app)
      waitForRows(app, Self.ids)
      el(app, "deck.add").tap()
      assertNewCardEditor(app)
      snapshot("editor-new", appearance: appearance)
      el(app, "editor.front").typeText("feline")
      XCTAssertFalse(el(app, "editor.save").isEnabled, "editor.save enabled with an empty back")
      el(app, "editor.back").tap()
      el(app, "editor.back").typeText("   ")
      XCTAssertFalse(el(app, "editor.save").isEnabled, "editor.save enabled with a whitespace-only back")
      el(app, "editor.back").typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "cat")
      XCTAssertTrue(el(app, "editor.save").isEnabled, "editor.save disabled with front + back filled")
      if appearance == .light { snapshot("editor-filled", appearance: .light) }
      el(app, "editor.save").tap()
      waitForAbsence(el(app, "editor.title"), "editor still open after saving")
      waitUntil("new row at the top") { self.rowIDs(app).count == 4 }
      let top = rowIDs(app)[0]
      XCTAssertFalse(Self.ids.contains(top), "new card is not the top row: \(rowIDs(app))")
      assertRow(app, top, front: "feline", back: "cat", due: "Due now", state: "new")
      XCTAssertEqual(Array(rowIDs(app).dropFirst()), Self.ids)
      snapshot("deck-after-add", appearance: appearance)
      app.terminate()
    }
  }

  /// #6 + #8: saving sends `POST /cards`; while it is in flight `editor.save` is disabled.
  @MainActor
  func testDeck_addCallsPOSTAndDisablesSaveInFlight() throws {
    XCUIDevice.shared.appearance = .light
    let (server, deck) = try startStubDeck()
    deck.writeDelay = 3
    let app = launch(api: .live(server.url))
    openDeck(app)
    waitForRows(app, stubOrder)
    el(app, "deck.add").tap()
    assertNewCardEditor(app)
    el(app, "editor.front").typeText("feline")
    el(app, "editor.back").tap()
    el(app, "editor.back").typeText("cat")
    el(app, "editor.save").tap()
    XCTAssertTrue(el(app, "editor.title").exists, "editor closed before the save finished")
    XCTAssertFalse(el(app, "editor.save").isEnabled, "editor.save enabled while the save is in flight")
    snapshot("editor-saving", appearance: .light)
    waitForAbsence(el(app, "editor.title"), timeout: 10, "editor still open after the save finished")
    let posts = server.requests.filter { $0.method == "POST" }
    XCTAssertEqual(posts.map(\.path), ["/cards"])
    XCTAssertTrue(posts[0].body.contains("\"feline\"") && posts[0].body.contains("\"cat\""), "POST body: \(posts[0].body)")
    waitUntil("new row at the top") { self.rowIDs(app).count == 4 }
    XCTAssertTrue(rowText(app, rowIDs(app)[0], "feline").exists, "new card is not the top row")
    server.stop()
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
      XCTAssertTrue(el(app, "study.rate.good").waitForExistence(timeout: 3))
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

  // MARK: - #9 save error, #10 close

  /// #9: a failing save keeps the editor open with the text and shows `editor.error`.
  @MainActor
  func testEditor_saveFailureKeepsText() throws {
    let (server, deck) = try startStubDeck()
    deck.writeStatus = 500
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .live(server.url))
      waitForLabel(el(app, "study.front"), Self.fixtures[0].front)
      el(app, "study.add").tap()
      assertNewCardEditor(app)
      el(app, "editor.front").typeText("feline")
      el(app, "editor.back").tap()
      el(app, "editor.back").typeText("cat")
      el(app, "editor.save").tap()
      waitForLabel(el(app, "editor.error"), "Couldn't save. Check your connection.")
      XCTAssertTrue(el(app, "editor.title").exists, "editor closed after a failed save")
      XCTAssertEqual(fieldText(app, "editor.front"), "feline")
      XCTAssertEqual(fieldText(app, "editor.back"), "cat")
      waitUntil("editor.save re-enabled after the failure") { self.el(app, "editor.save").isEnabled }
      let error = el(app, "editor.error").frame
      XCTAssertGreaterThanOrEqual(error.minY, el(app, "editor.back").frame.maxY - 1, "editor.error not under the fields")
      snapshot("editor-error", appearance: appearance)
      app.terminate()
    }
    server.stop()
  }

  /// #10: `editor.close` dismisses without calling the API (new card from study and deck, edit from deck).
  @MainActor
  func testEditor_closeWithoutSaving() throws {
    XCUIDevice.shared.appearance = .light
    let (server, deck) = try startStubDeck()
    let app = launch(api: .live(server.url))
    waitForLabel(el(app, "study.front"), Self.fixtures[0].front)
    // New card from study.
    el(app, "study.add").tap()
    assertNewCardEditor(app)
    el(app, "editor.front").typeText("feline")
    el(app, "editor.close").tap()
    waitForAbsence(el(app, "editor.title"), "editor still open after editor.close")
    // New card from the deck.
    openDeck(app)
    waitForRows(app, stubOrder)
    el(app, "deck.add").tap()
    assertNewCardEditor(app)
    el(app, "editor.front").typeText("feline")
    el(app, "editor.back").tap()
    el(app, "editor.back").typeText("cat")
    el(app, "editor.close").tap()
    waitForAbsence(el(app, "editor.title"), "editor still open after editor.close")
    waitForRows(app, stubOrder)
    // Edit, then close.
    row(app, Self.ids[2]).tap()
    waitForLabel(el(app, "editor.title"), "Edit card")
    replaceText(app, "editor.back", with: "short-lived")
    el(app, "editor.close").tap()
    waitForAbsence(el(app, "editor.title"), "editor still open after editor.close")
    XCTAssertTrue(rowText(app, Self.ids[2], Self.fixtures[2].back).exists, "row lost its back after closing")
    Thread.sleep(forTimeInterval: 1)
    let writes = server.requests.filter { ["POST", "PATCH", "DELETE"].contains($0.method) }
    XCTAssertTrue(writes.isEmpty, "closing the editor called the API: \(writes.map { "\($0.method) \($0.path)" })")
    XCTAssertEqual(deck.cards.count, 3)
    server.stop()
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
    waitForLabel(el(app, "editor.title"), "Edit card")
    replaceText(app, "editor.front", with: "la carta")
    el(app, "editor.save").tap()
    waitForAbsence(el(app, "editor.title"))
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
    waitForAbsence(el(app, "editor.title"))
    swipeSheetDown(app, from: deckTitle(app))
    waitForAbsence(deckTitle(app))
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
    XCTAssertTrue(row(app, Self.ids[0]).waitForExistence(timeout: 10))
    snapshot("deck-xl", appearance: .light)
    XCTAssertGreaterThan(row(app, Self.ids[0]).frame.height, baseHeight * 1.3, "rows did not scale with Dynamic Type")
    assertTextsReadable(in: app, ignoring: ["study."])
    let window = app.windows.firstMatch.frame
    for (id, e) in [("Cards title", deckTitleText(app)), ("deck.add", el(app, "deck.add")),
                    ("deck.settings", el(app, "deck.settings")), ("search field", deckSearch(app))] {
      XCTAssertTrue(window.contains(e.frame), "\(id) outside the window at XL: \(e.frame)")
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
    XCTAssertTrue(el(app, "study.front").waitForExistence(timeout: 10) || el(app, "study.message").exists)
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
    swipeSheetDown(app, from: deckTitle(app))
    waitForAbsence(deckTitle(app))
    openDeck(app)
    waitUntil("2 rows after reopening") { self.rowIDs(app).count == 2 }
    XCTAssertFalse(row(app, felineID).exists, "feline row back after reopening the deck")
    snapshot("deck-live-after-delete", appearance: .light)
    XCTAssertFalse(try liveCards(url).contains { $0["front"] as? String == "feline" }, "feline still in the API")
  }

  // MARK: - Spec 009a: native deck

  /// Launch argument pair forcing Dynamic Type to AX5 (the largest accessibility size).
  static let ax5Arguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
  /// (theme argument, device appearance, screenshot suffix): light, dark, forest.
  static let looks: [(theme: String, appearance: XCUIDevice.Appearance, name: String)] = [
    ("system", .light, ""), ("system", .dark, ""), ("forest", .light, "-forest"),
  ]

  /// 009a #1: a large "Cards" navigation title on the left that collapses to an inline, centered title when the
  /// list scrolls (light, dark, forest).
  @MainActor
  func testDeck_largeTitleCollapsesOnScroll() throws {
    let base = Date(timeIntervalSince1970: 1_767_225_600)
    let deck = StubDeck((1...24).map { i in
      .init(id: String(format: "bbbbbbbb-0000-0000-0000-%012d", i), front: "word \(i)", back: "answer \(i)",
            createdAt: base.addingTimeInterval(-Double(i) * 60))
    })
    let server = StubAPIServer(handler: deck.handle)
    try server.start()
    for look in Self.looks {
      XCUIDevice.shared.appearance = look.appearance
      let app = launch(api: .live(server.url), theme: look.theme)
      openDeck(app)
      waitUntil("rows loaded") { self.rowIDs(app).count >= 5 }
      let window = app.windows.firstMatch.frame
      let large = deckTitleText(app).frame
      XCTAssertLessThan(large.minX, 30, "large title not on the left: \(large)")
      XCTAssertGreaterThanOrEqual(large.height, 34, "title not large before scrolling: \(large)")
      snapshot("deck-large-title\(look.name)", appearance: look.appearance)
      let start = row(app, rowIDs(app)[2]).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      start.press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
      waitUntil("title collapsed to inline") {
        let f = self.deckTitleText(app).frame
        return f.height < 30 && abs(f.midX - window.midX) < 20
      }
      XCTAssertTrue(deckTitle(app).exists, "navigation bar gone after scrolling")
      snapshot("deck-collapsed\(look.name)", appearance: look.appearance)
      app.terminate()
    }
    server.stop()
  }

  /// 009a #2: `deck.settings` (gearshape) and `deck.add` (plus) are toolbar buttons tinted ink, never pink; they open
  /// Settings and the "New card" editor.
  @MainActor
  func testDeck_toolbarButtons() {
    for look in Self.looks {
      XCUIDevice.shared.appearance = look.appearance
      let app = launch(api: .mock, theme: look.theme)
      openDeck(app)
      waitForRows(app, Self.ids)
      assertDeckChrome(app)
      let ink = Self.ink(look.theme == "forest" ? "forest" : look.appearance == .dark ? "dark" : "light")
      let pixels = Pixels(XCUIScreen.main.screenshot(), pointWidth: app.windows.firstMatch.frame.width)
      for id in ["deck.settings", "deck.add"] {
        let f = el(app, id).frame
        XCTAssertTrue(pinkPoints(pixels, in: f, theme: look.theme, appearance: look.appearance).isEmpty, "\(id) is pink")
        let glyph = inkiest(pixels, in: f.insetBy(dx: f.width * 0.25, dy: f.height * 0.25), ink: ink)
        XCTAssertLessThan(glyph, 60, "\(id) glyph not ink \(ink) (closest distance \(glyph))")
      }
      el(app, "deck.settings").tap()
      XCTAssertTrue(el(app, "settings.title").waitForExistence(timeout: 5), "deck.settings did not open Settings")
      snapshot("deck-settings-open\(look.name)", appearance: look.appearance)
      el(app, "settings.close").tap()
      waitForAbsence(el(app, "settings.title"))
      el(app, "deck.add").tap()
      waitForLabel(el(app, "editor.title"), "New card")
      el(app, "editor.close").tap()
      waitForAbsence(el(app, "editor.title"))
      app.terminate()
    }
  }

  /// 009a #3: the system search field filters ("ser" → serendipity) and its clear button brings every row back.
  @MainActor
  func testDeck_searchClearButton() {
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .mock)
      openDeck(app)
      waitForRows(app, Self.ids)
      let search = deckSearch(app)
      XCTAssertEqual(search.placeholderValue, "Search", "search prompt")
      search.tap()
      search.typeText("ser")
      waitForRows(app, [Self.ids[0]])
      let clear = search.buttons.firstMatch
      XCTAssertTrue(clear.waitForExistence(timeout: 3), "no clear button in the search field")
      clear.tap()
      waitForRows(app, Self.ids)
      snapshot("deck-search-cleared", appearance: appearance)
      app.terminate()
    }
  }

  /// 009a #4: no matches → the system search empty state (`ContentUnavailableView.search`), light, dark, forest.
  @MainActor
  func testDeck_noMatchesSystemSearchState() {
    for look in Self.looks {
      XCUIDevice.shared.appearance = look.appearance
      let app = launch(api: .mock, theme: look.theme)
      openDeck(app)
      waitForRows(app, Self.ids)
      deckSearch(app).tap()
      deckSearch(app).typeText("zzz")
      waitForRows(app, [])
      // The system view has no identifier of ours: its title is "No Results for “zzz”".
      let title = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'zzz'")).firstMatch
      XCTAssertTrue(title.waitForExistence(timeout: 5), "no ContentUnavailableView.search title mentioning the query")
      snapshot("deck-no-matches\(look.name)", appearance: look.appearance)
      app.terminate()
    }
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
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .mock)
      openDeck(app)
      waitForRows(app, Self.ids)
      row(app, Self.ids[2]).press(forDuration: 1)
      let edit = el(app, "deck.row.\(Self.ids[2].uppercased()).edit")
      let delete = el(app, "deck.row.\(Self.ids[2].uppercased()).contextDelete")
      XCTAssertTrue(edit.waitForExistence(timeout: 3), "no deck.row.<id>.edit after a long press")
      XCTAssertTrue(delete.exists, "no deck.row.<id>.contextDelete after a long press")
      XCTAssertEqual(edit.label, "Edit")
      XCTAssertEqual(delete.label, "Delete")
      XCTAssertLessThan(edit.frame.midY, delete.frame.midY, "Edit not above Delete")
      snapshot("deck-context-menu", appearance: appearance)
      edit.tap()
      waitForLabel(el(app, "editor.title"), "Edit card")
      XCTAssertEqual(fieldText(app, "editor.front"), Self.fixtures[2].front)
      el(app, "editor.close").tap()
      waitForAbsence(el(app, "editor.title"))

      row(app, Self.ids[1]).press(forDuration: 1)
      let delete1 = el(app, "deck.row.\(Self.ids[1].uppercased()).contextDelete")
      XCTAssertTrue(delete1.waitForExistence(timeout: 3), "no contextDelete on the second long press")
      delete1.tap()
      waitForRows(app, [Self.ids[0], Self.ids[2]], timeout: 3)
      app.terminate()
    }
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
      Thread.sleep(forTimeInterval: 0.6)  // cursor blink: take the shot while it's drawn (checked below)
      var pink: [CGPoint] = []
      var field = CGRect.zero
      // The cursor blinks: retry until it's drawn once, so "no pink at all" can't pass by accident.
      for _ in 0..<8 {
        let pixels = Pixels(XCUIScreen.main.screenshot(), pointWidth: app.windows.firstMatch.frame.width)
        field = search.frame
        pink = pinkPoints(pixels, in: app.windows.firstMatch.frame, theme: look.theme, appearance: look.appearance)
        if pink.contains(where: { field.contains($0) }) { break }
        Thread.sleep(forTimeInterval: 0.25)
      }
      snapshot("deck-search-focused\(look.name)", appearance: look.appearance)
      XCTAssertTrue(pink.contains { field.contains($0) }, "search cursor is not Theme.accent (no pink inside \(field))")
      let outside = pink.filter { !field.insetBy(dx: -2, dy: -2).contains($0) }
      if let box = outside.first.map({ p in outside.reduce(CGRect(origin: p, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) } }) {
        XCTFail("pink outside the search field (\(outside.count) pt) in \(box), look \(look.theme)/\(look.appearance)")
      }
      app.terminate()
    }
  }

  /// 009a #9: at AX5, long rows don't clip (one line, truncated inside the row), the title and toolbar stay in the
  /// window, every interactive element keeps its id. Empty state too.
  @MainActor
  func testDeck_ax5LongRows() throws {
    XCUIDevice.shared.appearance = .light
    let long = "an extraordinarily long front that will never fit on a single line at the largest text size"
    let deck = StubDeck([
      .init(id: "cccccccc-0000-0000-0000-000000000001", front: long, back: long + " (back)", state: "review",
            due: Date().addingTimeInterval(3 * 86_400 + 3_600)),
      .init(id: "cccccccc-0000-0000-0000-000000000002", front: "cat", back: "feline",
            createdAt: Date(timeIntervalSince1970: 1_767_225_000)),
    ])
    let server = StubAPIServer(handler: deck.handle)
    try server.start()
    let app = launch(api: .live(server.url), arguments: Self.ax5Arguments)
    openDeck(app)
    let ids = ["CCCCCCCC-0000-0000-0000-000000000001", "CCCCCCCC-0000-0000-0000-000000000002"]
    waitForRows(app, ids)
    snapshot("deck-ax5", appearance: .light)
    let window = app.windows.firstMatch.frame
    for (name, e) in [("Cards title", deckTitleText(app)), ("deck.add", el(app, "deck.add")),
                      ("deck.settings", el(app, "deck.settings")), ("search field", deckSearch(app))] {
      XCTAssertTrue(e.exists, "\(name) missing at AX5")
      XCTAssertTrue(window.contains(e.frame), "\(name) outside the window at AX5: \(e.frame)")
    }
    XCTAssertFalse(deckTitleText(app).frame.intersects(el(app, "deck.add").frame), "title overlaps deck.add at AX5")
    assertTextsReadable(in: app, ignoring: ["study."])
    for id in ids {
      let r = row(app, id).frame
      XCTAssertTrue(window.insetBy(dx: -0.5, dy: 0).contains(CGRect(x: r.minX, y: window.midY, width: r.width, height: 1)),
                    "row \(id) wider than the window at AX5: \(r)")
      for suffix in ["due", "state"] {
        let e = el(app, "deck.row.\(id).\(suffix)")
        if e.frame.maxY < window.maxY {  // on screen
          XCTAssertTrue(r.insetBy(dx: -0.5, dy: -0.5).contains(e.frame), "deck.row.\(id).\(suffix) outside its row at AX5")
        }
      }
      for t in row(app, id).staticTexts.allElementsBoundByIndex where t.frame.maxY < window.maxY {
        XCTAssertTrue(r.insetBy(dx: -0.5, dy: -0.5).contains(t.frame), "'\(t.label)' \(t.frame) outside its row \(r) at AX5")
      }
    }
    // Context menu ids survive AX5.
    row(app, ids[1]).press(forDuration: 1)
    XCTAssertTrue(el(app, "deck.row.\(ids[1]).edit").waitForExistence(timeout: 3), "no edit id in the menu at AX5")
    XCTAssertTrue(el(app, "deck.row.\(ids[1]).contextDelete").exists, "no contextDelete id in the menu at AX5")
    snapshot("deck-context-menu-ax5", appearance: .light)
    app.terminate()

    // Empty state at AX5.
    let empty = StubAPIServer(handler: StubDeck([]).handle)
    try empty.start()
    let app2 = launch(api: .live(empty.url), arguments: Self.ax5Arguments)
    openDeck(app2)
    waitForLabel(el(app2, "deck.message"), "No cards yet")
    XCTAssertTrue(window.contains(el(app2, "deck.message").frame), "deck.message clipped at AX5")
    snapshot("deck-empty-ax5", appearance: .light)
    empty.stop()
    server.stop()
  }

  // MARK: 009a pixel helpers

  static func ink(_ look: String) -> (Int, Int, Int) {
    switch look {
    case "dark": (242, 242, 240)
    case "forest": (238, 242, 236)
    default: (28, 28, 28)
    }
  }

  /// Points (1pt grid) whose color is `Theme.accent` (#B8325A light, #ED6E8C dark/forest) within 45 per channel.
  @MainActor
  private func pinkPoints(_ pixels: Pixels, in rect: CGRect, theme: String,
                          appearance: XCUIDevice.Appearance) -> [CGPoint] {
    let accent = (theme == "forest" || appearance == .dark) ? (237, 110, 140) : (184, 50, 90)
    var out: [CGPoint] = []
    var y = rect.minY.rounded(.up)
    while y < rect.maxY {
      var x = rect.minX.rounded(.up)
      while x < rect.maxX {
        for dx in [0.0, 0.34, 0.67] {  // the cursor is ~2pt wide: sample at sub-point steps horizontally
          let c = pixels.color(at: CGPoint(x: x + dx, y: y))
          if abs(c.0 - accent.0) < 45, abs(c.1 - accent.1) < 45, abs(c.2 - accent.2) < 45, c.0 > c.1 + 60 {
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
  private func inkiest(_ pixels: Pixels, in rect: CGRect, ink: (Int, Int, Int)) -> Int {
    var best = 255
    var y = rect.minY
    while y < rect.maxY {
      var x = rect.minX
      while x < rect.maxX {
        let c = pixels.color(at: CGPoint(x: x, y: y))
        best = min(best, max(abs(c.0 - ink.0), abs(c.1 - ink.1), abs(c.2 - ink.2)))
        x += 0.34
      }
      y += 0.34
    }
    return best
  }

  // MARK: - Helpers

  /// The stub sorts by created_at desc, and …01 is the newest: rows read …01, …02, …03 like the mock.
  var stubOrder: [String] { Self.ids }

  /// Non-empty `query` values of the `GET /cards` requests the stub received, in order.
  private func searchQueries(_ server: StubAPIServer) -> [String] {
    server.requests
      .filter { $0.method == "GET" && StubDeck.route($0.path) == "/cards" }
      .compactMap { StubDeck.queryItems($0.path)["query"] }
      .filter { !$0.isEmpty }
  }

  private func startStubDeck() throws -> (StubAPIServer, StubDeck) {
    let base = Date(timeIntervalSince1970: 1_767_225_600)
    let deck = StubDeck(zip(Self.ids, Self.fixtures).enumerated().map { i, pair in
      .init(id: pair.0, front: pair.1.front, back: pair.1.back, createdAt: base.addingTimeInterval(-Double(i) * 60))
    })
    let server = StubAPIServer(handler: deck.handle)
    try server.start()
    return (server, deck)
  }

  @MainActor
  private func openDeck(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let button = el(app, "study.deck")
    XCTAssertTrue(button.waitForExistence(timeout: 10), "study.deck missing", file: file, line: line)
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
    XCTAssertTrue(delete.waitForExistence(timeout: 3), "no deck.row.\(id).delete after swiping left", file: file, line: line)
    delete.tap()
  }

  /// The swipe action is filled with the system destructive red (not ink, not a token).
  @MainActor
  private func assertSystemRed(_ app: XCUIApplication, _ action: XCUIElement,
                               file: StaticString = #filePath, line: UInt = #line) {
    let window = app.windows.firstMatch.frame
    let pixels = Pixels(XCUIScreen.main.screenshot(), pointWidth: window.width)
    let f = action.frame
    let c = pixels.color(at: CGPoint(x: f.midX, y: f.minY + f.height * 0.2))
    XCTAssertTrue(c.0 > 200 && c.1 < 110 && c.2 < 110, "Delete action fill \(c) at \(f) is not system red",
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
      if id.hasPrefix("deck.row."), !id.hasSuffix(".due"), !id.hasSuffix(".state"), !id.lowercased().hasSuffix(".delete"), !id.hasSuffix(".edit"), !id.lowercased().hasSuffix(".contextdelete"), !node.frame.isEmpty,
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
    XCTAssertTrue(row.waitForExistence(timeout: 5), "deck.row.\(id) missing", file: file, line: line)
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
  /// (no separators, no list background), the search field sits on `surface`.
  @MainActor
  private func assertDeckColors(_ app: XCUIApplication, appearance: XCUIDevice.Appearance,
                                file: StaticString = #filePath, line: UInt = #line) {
    let background = appearance == .dark ? (26, 26, 26) : (249, 250, 245)
    let surface = appearance == .dark ? (37, 37, 37) : (255, 255, 255)
    let window = app.windows.firstMatch.frame
    let pixels = Pixels(XCUIScreen.main.screenshot(), pointWidth: window.width)
    let frames = rowIDs(app).map { row(app, $0).frame }
    guard frames.count >= 2 else { return XCTFail("need 2 rows for colour checks", file: file, line: line) }
    func check(_ name: String, _ p: CGPoint, _ expected: (Int, Int, Int)) {
      let c = pixels.color(at: p)
      let ok = abs(c.0 - expected.0) <= 4 && abs(c.1 - expected.1) <= 4 && abs(c.2 - expected.2) <= 4
      XCTAssertTrue(ok, "\(name) at \(p) is \(c), expected \(expected)", file: file, line: line)
    }
    check("row fill", CGPoint(x: frames[0].minX + 6, y: frames[0].midY), surface)
    check("gap between rows", CGPoint(x: frames[0].midX, y: (frames[0].maxY + frames[1].minY) / 2), background)
    check("left of a row", CGPoint(x: frames[0].minX / 2, y: frames[0].midY), background)
    check("below the rows", CGPoint(x: window.midX, y: frames.last!.maxY + 60), background)
    check("near the bottom edge", CGPoint(x: window.midX, y: window.maxY - 4), background)
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

/// RGB sampling of a screenshot at point coordinates.
struct Pixels {
  private let data: [UInt8]
  private let width: Int
  private let height: Int
  private let scale: CGFloat

  init(_ screenshot: XCUIScreenshot, pointWidth: CGFloat) {
    self.init(screenshot.image.cgImage!, pointWidth: pointWidth)
  }

  init(_ cg: CGImage, pointWidth: CGFloat) {
    width = cg.width
    height = cg.height
    scale = CGFloat(cg.width) / pointWidth
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    data = buffer
  }

  func color(at point: CGPoint) -> (Int, Int, Int) {
    let x = min(max(Int(point.x * scale), 0), width - 1), y = min(max(Int(point.y * scale), 0), height - 1)
    let i = (y * width + x) * 4
    return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
  }
}
