import XCTest

/// Spec 006: pull-to-refresh on Study and Deck + reload when the scene becomes active.
/// "Stub" = `StubAPIServer` + `StubDeck`; the test adds/removes cards on it to simulate an agent (MCP).
final class RefreshUITests: XCTestCase {
  static let ratings = ["again", "hard", "good", "easy"]
  static let appearances: [XCUIDevice.Appearance] = [.light, .dark]
  static let base = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01: due now
  static let idA = "AAAAAAAA-0000-0000-0000-000000000001"
  static let idB = "BBBBBBBB-0000-0000-0000-000000000002"
  static let idC = "CCCCCCCC-0000-0000-0000-000000000003"

  override func setUp() {
    continueAfterFailure = false
  }

  // MARK: - #1, #7 (caught up), #11

  /// #1: caught up → agent adds a card → pull on the caught-up message → card front, unrevealed, "1 to review".
  /// The caught-up content stays on screen while the reload is in flight (no blank loading state).
  /// #11: no blue pixel while the spinner is showing.
  @MainActor
  func testStudy_pullToRefreshWhenCaughtUp() throws {
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let (server, deck) = try startStub([])
      let app = launch(api: .live(server.url))
      waitForLabel(el(app, "study.message"), "All caught up")
      assertCenteredMessage(app, "study.message")
      snapshot("study-caught-up-before-refresh", appearance: appearance)

      deck.add(card(Self.idA, "chien", "dog"))
      deck.readDelay = 5
      // Reload in flight (captured mid-refresh): the caught-up text is still drawn (quiet reload), spinner not blue.
      let inFlight = pullToRefreshCapturing(app, from: el(app, "study.message"), name: "study-refresh-spinner",
                                            appearance: appearance)
      assertInkVisible(inFlight, appearance, "caught-up text during the refresh (blank loading state?)")
      assertNoBlue(inFlight, "study refresh spinner")

      waitForLabel(el(app, "study.front"), "chien", timeout: 20)
      assertFront(app, "chien", remaining: "1 to review")
      snapshot("study-after-refresh", appearance: appearance)
      app.terminate()
      server.stop()
    }
  }

  // MARK: - #2, #7 (offline)

  /// #2: API down → offline; API back → pulling on `study.message` leaves the offline state.
  @MainActor
  func testStudy_pullToRefreshWhenOffline() throws {
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let deck = StubDeck([card(Self.idA, "merci", "thank you")])
      let server = StubAPIServer(handler: deck.handle)
      // Not started: the port refuses connections.
      let app = launch(api: .live(server.url))
      waitForLabel(el(app, "study.message"), "Can't reach your deck", timeout: 20)
      XCTAssertTrue(el(app, "study.retry").exists, "study.retry missing offline")
      assertCenteredMessage(app, "study.message")
      snapshot("study-offline-before-refresh", appearance: appearance)

      // Pull while still down → still offline.
      pullToRefresh(app, from: el(app, "study.message"))
      waitForLabel(el(app, "study.message"), "Can't reach your deck", timeout: 20)

      try server.start()
      pullToRefresh(app, from: el(app, "study.message"))
      assertFront(app, "merci", remaining: "1 to review")
      XCTAssertFalse(el(app, "study.retry").exists, "study.retry still shown after a successful pull")
      snapshot("study-offline-after-refresh", appearance: appearance)
      app.terminate()
      server.stop()
    }
  }

  // MARK: - #7 (studying)

  /// #7: in studying, a pull on the (short) card reloads, does not reveal, and the front still doesn't move on reveal.
  @MainActor
  func testStudy_pullToRefreshWhileStudying() throws {
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let (server, deck) = try startStub([card(Self.idA, "chien", "dog")])
      let app = launch(api: .live(server.url))
      assertFront(app, "chien", remaining: "1 to review")
      let frontBefore = el(app, "study.front").frame

      deck.add(card(Self.idB, "chat", "cat", minutes: 1))
      deck.readDelay = 5
      let inFlight = pullToRefreshCapturing(app, from: el(app, "study.card"), name: "study-card-refresh-spinner",
                                            appearance: appearance)
      assertInkVisible(inFlight, appearance, "card front during the refresh (blank loading state?)")
      assertNoBlue(inFlight, "study card refresh spinner")

      waitForLabel(el(app, "study.remaining"), "2 to review", timeout: 20)
      deck.readDelay = 0
      assertFront(app, "chien", remaining: "2 to review")
      XCTAssertFalse(el(app, "study.back").exists, "pulling revealed the card")
      Thread.sleep(forTimeInterval: 0.5)
      let frontAfter = el(app, "study.front").frame
      XCTAssertEqual(frontAfter.minY, frontBefore.minY, accuracy: 0.5,
                     "study.front did not settle back after the pull: \(frontBefore) → \(frontAfter)")
      snapshot("study-card-after-refresh", appearance: appearance)

      el(app, "study.card").tap()
      assertRevealed(app, front: "chien", back: "dog")
      Thread.sleep(forTimeInterval: 0.5)
      XCTAssertEqual(el(app, "study.front").frame.minY, frontBefore.minY, accuracy: 0.5,
                     "study.front moved on reveal after a refresh")
      app.terminate()
      server.stop()
    }
  }

  /// #7: the whole card area is the pull surface, not just the text: a pull starting in the empty top part of
  /// `study.card` (well above the short front) also refreshes, and does not reveal.
  @MainActor
  func testStudy_pullFromEmptyCardArea() throws {
    XCUIDevice.shared.appearance = .light
    let (server, deck) = try startStub([card(Self.idA, "chien", "dog")])
    let app = launch(api: .live(server.url))
    assertFront(app, "chien", remaining: "1 to review")
    let card = el(app, "study.card").frame, front = el(app, "study.front").frame
    let startY = card.minY + 40
    XCTAssertLessThan(startY, front.minY - 100, "fixture: start point not clear of the text")
    deck.add(self.card(Self.idB, "chat", "cat", minutes: 1))
    let window = app.windows.firstMatch
    let h = window.frame.height
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY / h))
      .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: (startY + 350) / h)))
    waitForLabel(el(app, "study.remaining"), "2 to review")
    assertFront(app, "chien", remaining: "2 to review")
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
    waitForLabel(el(app, "study.message"), "All caught up")

    // #5
    deck.add(card(Self.idA, "chien", "dog"))
    backgroundAndReactivate(app)
    assertFront(app, "chien", remaining: "1 to review")
    snapshot("study-foreground-caught-up", appearance: .light)

    // #3 same first id → stays revealed, remaining updates.
    el(app, "study.reveal").tap()
    assertRevealed(app, front: "chien", back: "dog")
    deck.add(card(Self.idB, "chat", "cat", minutes: 1))
    backgroundAndReactivate(app)
    waitForLabel(el(app, "study.remaining"), "2 to review")
    assertRevealed(app, front: "chien", back: "dog")
    snapshot("study-foreground-revealed", appearance: .light)

    // #3 first card changed (reviewed/deleted elsewhere) → new first card, unrevealed.
    deck.remove(id: Self.idA)
    backgroundAndReactivate(app)
    assertFront(app, "chat", remaining: "1 to review")
    snapshot("study-foreground-changed", appearance: .light)
    server.stop()
  }

  // MARK: - #8

  /// #8: "No cards yet" → agent adds → pull on `deck.message` → row appears. Then with a query: rows stay during
  /// the reload, the reload uses the query, the field keeps its text.
  @MainActor
  func testDeck_pullToRefresh() throws {
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let (server, deck) = try startStub([])
      let app = launch(api: .live(server.url))
      openDeck(app)
      waitForLabel(el(app, "deck.message"), "No cards yet")
      assertCenteredMessage(app, "deck.message")
      snapshot("deck-empty-before-refresh", appearance: appearance)

      deck.add(card(Self.idA, "chien", "dog"))
      pullToRefresh(app, from: el(app, "deck.message"))
      XCTAssertTrue(el(app, "deck.title").waitForExistence(timeout: 2), "the pull closed the deck sheet")
      XCTAssertTrue(row(app, Self.idA).waitForExistence(timeout: 10), "deck.row.<chien> missing after the pull")
      XCTAssertFalse(el(app, "deck.message").exists, "deck.message still shown with a row")
      snapshot("deck-after-refresh", appearance: appearance)

      // With a query.
      el(app, "deck.search").tap()
      el(app, "deck.search").typeText("ch")
      Thread.sleep(forTimeInterval: 1)  // debounce
      XCTAssertTrue(row(app, Self.idA).waitForExistence(timeout: 5))
      deck.add(card(Self.idB, "chat", "cat", minutes: 1))
      deck.add(card(Self.idC, "merle", "blackbird", minutes: 2))
      deck.readDelay = 5
      let before = server.requests.count
      let inFlight = pullToRefreshCapturing(app, from: row(app, Self.idA), name: "deck-refresh-spinner",
                                            appearance: appearance)
      // In flight: the chien row still drawn (visual review), only one row before the response.
      assertInkVisible(inFlight, appearance, "existing row during the refresh")
      assertNoBlue(inFlight, "deck refresh spinner")
      XCTAssertTrue(el(app, "deck.title").exists, "the pull closed the deck sheet")
      XCTAssertTrue(row(app, Self.idB).waitForExistence(timeout: 20), "chat row missing after the pull with a query")
      XCTAssertTrue(row(app, Self.idA).exists, "chien row gone after the pull")
      XCTAssertFalse(row(app, Self.idC).exists, "merle (not matching 'ch') shown: the refresh ignored the query")
      XCTAssertEqual(el(app, "deck.search").value as? String, "ch", "search field lost its text")
      let gets = server.requests.dropFirst(before).filter { $0.method == "GET" && StubDeck.route($0.path) == "/cards" }
      XCTAssertFalse(gets.isEmpty, "no GET /cards after the pull")
      for g in gets {
        XCTAssertEqual(StubDeck.queryItems(g.path)["query"], "ch", "refresh GET \(g.path) without the query")
      }
      snapshot("deck-after-refresh-query", appearance: appearance)
      app.terminate()
      server.stop()
    }
  }

  // MARK: - #9

  /// #9: deck open → add → Home → reactivate → new row. Study, under the sheet, refreshed too (rule: Study
  /// refreshes on foreground even under a sheet; a deck refresh sends no `deckChanged`).
  @MainActor
  func testDeck_foregroundReload() throws {
    XCUIDevice.shared.appearance = .light
    let (server, deck) = try startStub([])
    let app = launch(api: .live(server.url))
    waitForLabel(el(app, "study.message"), "All caught up")
    openDeck(app)
    waitForLabel(el(app, "deck.message"), "No cards yet")

    deck.add(card(Self.idA, "chien", "dog"))
    backgroundAndReactivate(app)
    XCTAssertTrue(row(app, Self.idA).waitForExistence(timeout: 10), "new row missing after reactivating")
    snapshot("deck-foreground", appearance: .light)

    swipeSheetDown(app, from: el(app, "deck.title"))
    waitForAbsence(el(app, "deck.title"))
    assertFront(app, "chien", remaining: "1 to review")
    server.stop()
  }

  // MARK: - #11 forest

  /// #11 (forest): spinner visible mid-pull, not blue, on Study and Deck.
  @MainActor
  func testStudy_refreshSpinnerForest() throws {
    XCUIDevice.shared.appearance = .light
    let (server, deck) = try startStub([card(Self.idA, "chien", "dog")])
    let app = launch(api: .live(server.url), theme: "forest")
    assertFront(app, "chien", remaining: "1 to review")
    deck.readDelay = 5
    let study = pullToRefreshCapturing(app, from: el(app, "study.card"), name: "study-refresh-forest",
                                       appearance: .light)
    assertNoBlue(study, "forest study spinner")
    deck.readDelay = 0

    openDeck(app)
    XCTAssertTrue(row(app, Self.idA).waitForExistence(timeout: 10))
    deck.readDelay = 5
    let deckShot = pullToRefreshCapturing(app, from: row(app, Self.idA), name: "deck-refresh-forest",
                                          appearance: .light)
    XCTAssertTrue(el(app, "deck.title").exists, "the pull closed the deck sheet")
    assertNoBlue(deckShot, "forest deck spinner")
    server.stop()
  }

  // MARK: - #12 live API

  /// #12: seeded bonjour/merci. Study "2 to review" → deck → POST chien/dog → pull list → chien row;
  /// close deck → pull study → "3 to review", front still bonjour. Deletes chien afterwards.
  @MainActor
  func testStudy_pullToRefresh_liveAPI() throws {
    guard let url = ProcessInfo.processInfo.environment["LA_CARTE_API_URL"], !url.isEmpty else {
      throw XCTSkip("LA_CARTE_API_URL not set — run scripts/e2e.sh")
    }
    addTeardownBlock { [self] in try? self.deleteLiveCards(url, front: "chien") }
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .live(url))
    assertFront(app, "bonjour", remaining: "2 to review")
    openDeck(app)
    let anyRow = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'deck.row.'"))
      .firstMatch
    XCTAssertTrue(anyRow.waitForExistence(timeout: 10), "no seeded rows")

    let created = try XCTUnwrap(liveRequest(url + "/cards", method: "POST", body: #"{"front":"chien","back":"dog"}"#))
    let chien = try XCTUnwrap(try JSONSerialization.jsonObject(with: created) as? [String: Any])
    let chienID = try XCTUnwrap(chien["id"] as? String, "POST /cards: \(chien)")
    XCTAssertFalse(row(app, chienID).exists, "chien shown before any refresh")

    pullToRefresh(app, from: anyRow)
    XCTAssertTrue(row(app, chienID).waitForExistence(timeout: 10), "chien row missing after pulling the list")
    snapshot("deck-refresh-live", appearance: .light)

    swipeSheetDown(app, from: el(app, "deck.title"))
    waitForAbsence(el(app, "deck.title"))
    assertFront(app, "bonjour", remaining: "2 to review")
    pullToRefresh(app, from: el(app, "study.card"))
    assertFront(app, "bonjour", remaining: "3 to review")
    snapshot("study-refresh-live", appearance: .light)

    try deleteLiveCards(url, front: "chien")
    let cards = try liveCards(url)
    XCTAssertEqual(Set(cards.compactMap { $0["front"] as? String }), ["bonjour", "merci"], "deck not left as seeded")
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
    XCTAssertTrue(button.waitForExistence(timeout: 10), "study.deck missing", file: file, line: line)
    button.tap()
    waitForLabel(el(app, "deck.title"), "Cards", file: file, line: line)
  }

  @MainActor
  private func assertFront(_ app: XCUIApplication, _ front: String, remaining: String,
                           file: StaticString = #filePath, line: UInt = #line) {
    waitForLabel(el(app, "study.front"), front, file: file, line: line)
    waitForLabel(el(app, "study.remaining"), remaining, file: file, line: line)
    XCTAssertFalse(el(app, "study.back").exists, "study.back visible: card should be unrevealed", file: file, line: line)
    XCTAssertTrue(el(app, "study.reveal").waitForExistence(timeout: 3), "study.reveal missing", file: file, line: line)
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
      XCTAssertTrue(b.waitForExistence(timeout: 3), "study.rate.\(rating) missing", file: file, line: line)
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

  /// #11 / design system "no default blue tint": no saturated blue pixel anywhere on screen.
  @MainActor
  private func assertNoBlue(_ image: CGImage?, _ context: String,
                            file: StaticString = #filePath, line: UInt = #line) {
    guard let image else { return XCTFail("\(context): no screenshot", file: file, line: line) }
    let window = CGRect(x: 0, y: 0, width: CGFloat(image.width) / 3, height: CGFloat(image.height) / 3)  // @3x
    let pixels = Pixels(image, pointWidth: window.width)
    var blue: [(CGPoint, (Int, Int, Int))] = []
    var y: CGFloat = 0
    while y < window.height {
      var x: CGFloat = 0
      while x < window.width {
        let c = pixels.color(at: CGPoint(x: x, y: y))
        if c.2 > c.0 + 60, c.2 > c.1 + 30 { blue.append((CGPoint(x: x, y: y), c)) }
        x += 1
      }
      y += 1
    }
    XCTAssertTrue(blue.isEmpty, "\(context): \(blue.count) blue pixels, e.g. \(blue.prefix(3))", file: file, line: line)
  }

  /// Text in the ink colour is drawn somewhere in the content area (y 130–760pt): the screen isn't blank.
  @MainActor
  private func assertInkVisible(_ image: CGImage?, _ appearance: XCUIDevice.Appearance, _ context: String,
                                file: StaticString = #filePath, line: UInt = #line) {
    guard let image else { return XCTFail("\(context): no screenshot", file: file, line: line) }
    let ink = appearance == .dark ? (242, 242, 240) : (28, 28, 28)
    let width = CGFloat(image.width) / 3  // @3x
    let pixels = Pixels(image, pointWidth: width)
    var count = 0
    for y in stride(from: 130.0, to: 760.0, by: 1.0) {
      for x in stride(from: 0.0, to: width, by: 1.0) {
        let c = pixels.color(at: CGPoint(x: x, y: y))
        if abs(c.0 - ink.0) < 20, abs(c.1 - ink.1) < 20, abs(c.2 - ink.2) < 20 { count += 1 }
      }
    }
    XCTAssertGreaterThan(count, 30, "\(context): no ink-coloured text in the content area", file: file, line: line)
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
