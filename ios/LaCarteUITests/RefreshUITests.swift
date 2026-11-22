import XCTest

/// Spec 006: pull-to-refresh on Study and Deck + reload when the scene becomes active.
/// "Stub" = `StubAPIServer` + `StubDeck`; the test adds/removes cards on it to simulate an agent (MCP).
final class RefreshUITests: XCTestCase {
  static let ratings = ["again", "good"]  // spec 011
  static let base = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01: due now
  static let idA = "AAAAAAAA-0000-0000-0000-000000000001"
  static let idB = "BBBBBBBB-0000-0000-0000-000000000002"
  static let idC = "CCCCCCCC-0000-0000-0000-000000000003"

  override func setUp() {
    continueAfterFailure = false
  }

  // MARK: - #7 (studying)

  /// #7: in studying, a pull on the (short) card reloads, does not reveal, and the front still doesn't move on reveal.
  @MainActor
  func testStudy_pullToRefreshWhileStudying() throws {
    XCUIDevice.shared.appearance = .dark
    let (server, deck) = try startStub([card(Self.idA, "canine", "dog")])
    let app = launch(api: .live(server.url))
    assertFront(app, "canine", remaining: "1 to review")
    let frontBefore = el(app, "study.front").frame

    deck.add(card(Self.idB, "feline", "cat", minutes: 1))
    deck.readDelay = 5
    let inFlight = pullToRefreshCapturing(app, from: el(app, "study.card"), name: "study-card-refresh-spinner",
                                          appearance: .dark)
    assertInkVisible(inFlight, ink: Palette.dark.ink, "card front during the refresh (blank loading state?)")
    assertNoBlue(inFlight, "study card refresh spinner")

    waitForLabel(el(app, "study.remaining"), "2 to review", timeout: 20)
    deck.readDelay = 0
    assertFront(app, "canine", remaining: "2 to review")
    XCTAssertFalse(el(app, "study.back").exists, "pulling revealed the card")
    _ = poll(timeout: 3) { abs(el(app, "study.front").frame.minY - frontBefore.minY) < 0.5 }  // settles after the pull
    let frontAfter = el(app, "study.front").frame
    XCTAssertEqual(frontAfter.minY, frontBefore.minY, accuracy: 0.5,
                   "study.front did not settle back after the pull: \(frontBefore) → \(frontAfter)")
    snapshot("study-card-after-refresh", appearance: .dark)

    el(app, "study.card").tap()
    assertRevealed(app, front: "canine", back: "dog")
    _ = poll(timeout: 2) { abs(el(app, "study.front").frame.minY - frontBefore.minY) < 0.5 }  // 0.25 s fade
    XCTAssertEqual(el(app, "study.front").frame.minY, frontBefore.minY, accuracy: 0.5,
                   "study.front moved on reveal after a refresh")
    app.terminate()
    server.stop()
  }

  /// #7: the whole card area is the pull surface, not just the text: a pull starting in the empty top part of
  /// `study.card` (well above the short front) also refreshes, and does not reveal.
  @MainActor
  func testStudy_pullFromEmptyCardArea() throws {
    XCUIDevice.shared.appearance = .light
    let (server, deck) = try startStub([card(Self.idA, "canine", "dog")])
    let app = launch(api: .live(server.url))
    assertFront(app, "canine", remaining: "1 to review")
    let card = el(app, "study.card").frame, front = el(app, "study.front").frame
    let startY = card.minY + 40
    XCTAssertLessThan(startY, front.minY - 100, "fixture: start point not clear of the text")
    deck.add(self.card(Self.idB, "feline", "cat", minutes: 1))
    let window = app.windows.firstMatch
    let h = window.frame.height
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY / h))
      .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: (startY + 350) / h)))
    waitForLabel(el(app, "study.remaining"), "2 to review")
    assertFront(app, "canine", remaining: "2 to review")
    snapshot("study-pull-card-top", appearance: .light)
    server.stop()
  }

  // MARK: - #3, #5 (foreground)

  /// #5: caught up → add → Home → reactivate → card shown. #3: revealed, add a second card → foreground →
  /// still revealed with "2 to review"; first card removed elsewhere → foreground → new first card unrevealed.
  @MainActor
  func testStudy_foregroundReload() throws {
    XCUIDevice.shared.appearance = .light
    let (server, deck) = try startStub([])
    let app = launch(api: .live(server.url))
    waitForLabel(el(app, "study.message"), "No cards yet")  // an empty deck (audit 2026-11-22 P0-5)

    // #5
    deck.add(card(Self.idA, "canine", "dog"))
    backgroundAndReactivate(app)
    assertFront(app, "canine", remaining: "1 to review")
    snapshot("study-foreground-caught-up", appearance: .light)

    // #3 same first id → stays revealed, remaining updates.
    el(app, "study.reveal").tap()
    assertRevealed(app, front: "canine", back: "dog")
    deck.add(card(Self.idB, "feline", "cat", minutes: 1))
    backgroundAndReactivate(app)
    waitForLabel(el(app, "study.remaining"), "2 to review")
    assertRevealed(app, front: "canine", back: "dog")
    snapshot("study-foreground-revealed", appearance: .light)

    // #3 first card changed (reviewed/deleted elsewhere) → new first card, unrevealed.
    deck.remove(id: Self.idA)
    backgroundAndReactivate(app)
    assertFront(app, "feline", remaining: "1 to review")
    snapshot("study-foreground-changed", appearance: .light)
    server.stop()
  }

  // MARK: - #8

  /// #8: "No cards yet" → agent adds → pull on `deck.message` → row appears. Then with a query: rows stay during
  /// the reload, the reload uses the query, the field keeps its text.
  @MainActor
  func testDeck_pullToRefresh() throws {
    XCUIDevice.shared.appearance = .light
    let (server, deck) = try startStub([])
    let app = launch(api: .live(server.url))
    openDeck(app)
    waitForLabel(el(app, "deck.message"), "No cards yet")
    assertCenteredMessage(app, "deck.message")
    snapshot("deck-empty-before-refresh", appearance: .light)

    deck.add(card(Self.idA, "canine", "dog"))
    // Pull from just under the search field: the message sits low in the 009a empty state, and a drag starting
    // there is too short to trigger the refresh.
    let window = app.windows.firstMatch
    let top = deckSearch(app).frame.maxY + 30, h = window.frame.height
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: top / h))
      .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: (top + 400) / h)))
    XCTAssertTrue(deckTitle(app).waitFor(timeout: 2), "the pull closed the deck sheet")
    XCTAssertTrue(row(app, Self.idA).waitFor(timeout: 10), "deck.row.<canine> missing after the pull")
    XCTAssertFalse(el(app, "deck.message").exists, "deck.message still shown with a row")
    snapshot("deck-after-refresh", appearance: .light)

    // With a query.
    deckSearch(app).tap()
    deckSearch(app).typeText("ine")
    // Debounce: wait for the search request (the old fixed 1 s sleep); the checks below fail if it never came.
    _ = poll(timeout: 3) { server.requests.contains { StubDeck.queryItems($0.path)["query"] == "ine" } }
    XCTAssertTrue(row(app, Self.idA).waitFor(timeout: 5))
    deck.add(card(Self.idB, "feline", "cat", minutes: 1))
    deck.add(card(Self.idC, "raven", "blackbird", minutes: 2))
    deck.readDelay = 5
    let before = server.requests.count
    let inFlight = pullToRefreshCapturing(app, from: row(app, Self.idA), name: "deck-refresh-spinner",
                                          appearance: .light)
    // In flight: the canine row still drawn (visual review), only one row before the response.
    assertInkVisible(inFlight, ink: Palette.light.ink, "existing row during the refresh")
    // The system keyboard (still up from the search) has a blue Search key: only check above it.
    let keyboardTop = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY : app.windows.firstMatch.frame.maxY
    assertNoBlue(inFlight.flatMap { $0.cropping(to: CGRect(x: 0, y: 0, width: $0.width, height: Int(keyboardTop * 3))) },
                 "deck refresh spinner")
    XCTAssertTrue(deckTitle(app).exists, "the pull closed the deck sheet")
    XCTAssertTrue(row(app, Self.idB).waitFor(timeout: 20), "feline row missing after the pull with a query")
    XCTAssertTrue(row(app, Self.idA).exists, "canine row gone after the pull")
    XCTAssertFalse(row(app, Self.idC).exists, "raven (not matching 'ine') shown: the refresh ignored the query")
    XCTAssertEqual(deckSearch(app).value as? String, "ine", "search field lost its text")
    let gets = server.requests.dropFirst(before).filter { $0.method == "GET" && StubDeck.route($0.path) == "/notes" }
    XCTAssertFalse(gets.isEmpty, "no GET /notes after the pull (spec 014c: the deck lists notes)")
    for g in gets {
      XCTAssertEqual(StubDeck.queryItems(g.path)["query"], "ine", "refresh GET \(g.path) without the query")
    }
    snapshot("deck-after-refresh-query", appearance: .light)
    app.terminate()
    server.stop()
  }

  // MARK: - #11 forest

  /// #11 (forest): spinner visible mid-pull, not blue, on Study and Deck.
  @MainActor
  func testStudy_refreshSpinnerForest() throws {
    XCUIDevice.shared.appearance = .light
    let (server, deck) = try startStub([card(Self.idA, "canine", "dog")])
    let app = launch(api: .live(server.url), theme: "forest")
    assertFront(app, "canine", remaining: "1 to review")
    deck.readDelay = 5
    let study = pullToRefreshCapturing(app, from: el(app, "study.card"), name: "study-refresh-forest",
                                       appearance: .light)
    assertNoBlue(study, "forest study spinner")
    deck.readDelay = 0

    openDeck(app)
    XCTAssertTrue(row(app, Self.idA).waitFor(timeout: 10))
    deck.readDelay = 5
    let deckShot = pullToRefreshCapturing(app, from: row(app, Self.idA), name: "deck-refresh-forest",
                                          appearance: .light)
    XCTAssertTrue(deckTitle(app).exists, "the pull closed the deck sheet")
    assertNoBlue(deckShot, "forest deck spinner")
    server.stop()
  }

  // MARK: - #12 live API

  /// #12: seeded greeting/gratitude. Study "2 to review" → deck → POST canine/dog → pull list → canine row;
  /// close deck → pull study → "3 to review", front still greeting. Deletes canine afterwards.
  @MainActor
  func testStudy_pullToRefresh_liveAPI() throws {
    guard let url = ProcessInfo.processInfo.environment["LA_CARTE_API_URL"], !url.isEmpty else {
      throw XCTSkip("LA_CARTE_API_URL not set — run scripts/e2e.sh")
    }
    addTeardownBlock { [self] in try? self.deleteLiveCards(url, front: "canine") }
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .live(url))
    assertFront(app, "greeting", remaining: "2 to review")
    openDeck(app)
    let anyRow = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'deck.row.'"))
      .firstMatch
    XCTAssertTrue(anyRow.waitFor(timeout: 10), "no seeded rows")

    let created = try XCTUnwrap(liveRequest(url + "/cards", method: "POST", body: #"{"front":"canine","back":"dog"}"#))
    let canine = try XCTUnwrap(try JSONSerialization.jsonObject(with: created) as? [String: Any])
    // Spec 014c: deck rows are notes, keyed by the card's `note_id`.
    let canineID = try XCTUnwrap(canine["note_id"] as? String ?? canine["id"] as? String, "POST /cards: \(canine)")
    XCTAssertFalse(row(app, canineID).exists, "canine shown before any refresh")

    pullToRefresh(app, from: anyRow)
    XCTAssertTrue(row(app, canineID).waitFor(timeout: 10), "canine row missing after pulling the list")
    snapshot("deck-refresh-live", appearance: .light)

    swipeSheetDown(app, from: deckTitle(app))
    waitForAbsence(deckTitle(app))
    assertFront(app, "greeting", remaining: "2 to review")
    pullToRefresh(app, from: el(app, "study.card"))
    assertFront(app, "greeting", remaining: "3 to review")
    snapshot("study-refresh-live", appearance: .light)

    try deleteLiveCards(url, front: "canine")
    let cards = try liveCards(url)
    XCTAssertEqual(Set(cards.compactMap { $0["front"] as? String }), ["greeting", "gratitude"], "deck not left as seeded")
  }

  // MARK: - Helpers

  private func card(_ id: String, _ front: String, _ back: String, minutes: Double = 0) -> StubDeck.Card {
    let at = Self.base.addingTimeInterval(minutes * 60)
    return .init(id: id, front: front, back: back, due: at, createdAt: at)
  }

  private func startStub(_ cards: [StubDeck.Card]) throws -> (StubAPIServer, StubDeck) {
    let deck = StubDeck(cards)
    let server = StubAPIServer(handler: deck.handle)
    try server.start()
    return (server, deck)
  }

  @MainActor
  private func row(_ app: XCUIApplication, _ id: String) -> XCUIElement { el(app, "deck.row.\(id.uppercased())") }

  @MainActor
  private func openDeck(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let button = el(app, "study.deck")
    XCTAssertTrue(button.waitFor(timeout: 10), "study.deck missing", file: file, line: line)
    button.tap()
    waitForDeckTitle(app, file: file, line: line)
  }

  @MainActor
  private func assertFront(_ app: XCUIApplication, _ front: String, remaining: String,
                           file: StaticString = #filePath, line: UInt = #line) {
    waitForLabel(el(app, "study.front"), front, file: file, line: line)
    waitForLabel(el(app, "study.remaining"), remaining, file: file, line: line)
    XCTAssertFalse(el(app, "study.back").exists, "study.back visible: card should be unrevealed", file: file, line: line)
    XCTAssertTrue(el(app, "study.reveal").waitFor(timeout: 3), "study.reveal missing", file: file, line: line)
    for rating in Self.ratings {
      XCTAssertFalse(el(app, "study.rate.\(rating)").exists, "study.rate.\(rating) shown before reveal",
                     file: file, line: line)
    }
  }

  @MainActor
  private func assertRevealed(_ app: XCUIApplication, front: String, back: String,
                              file: StaticString = #filePath, line: UInt = #line) {
    waitForLabel(el(app, "study.back"), back, timeout: 5, file: file, line: line)
    XCTAssertEqual(el(app, "study.front").label, front, file: file, line: line)
    XCTAssertFalse(el(app, "study.reveal").exists, "study.reveal shown on a revealed card", file: file, line: line)
    for rating in Self.ratings {
      let b = el(app, "study.rate.\(rating)")
      XCTAssertTrue(b.waitFor(timeout: 3), "study.rate.\(rating) missing", file: file, line: line)
      XCTAssertTrue(b.isEnabled, "study.rate.\(rating) disabled", file: file, line: line)
    }
  }

  /// The message is centered horizontally and roughly vertically in the window (the pull wrapper keeps it centered).
  @MainActor
  private func assertCenteredMessage(_ app: XCUIApplication, _ id: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
    let window = app.windows.firstMatch.frame
    let f = el(app, id).frame
    XCTAssertEqual(f.midX, window.midX, accuracy: 1, "\(id) not centered horizontally: \(f)", file: file, line: line)
    XCTAssertEqual(f.midY, window.midY, accuracy: window.height * 0.15, "\(id) not vertically centered: \(f)",
                   file: file, line: line)
  }

  // MARK: Live API helpers

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

  private func deleteLiveCards(_ url: String, front: String) throws {
    for card in try liveCards(url) where card["front"] as? String == front {
      _ = liveRequest(url + "/cards/\(card["id"] as? String ?? "")", method: "DELETE")
    }
  }
}
