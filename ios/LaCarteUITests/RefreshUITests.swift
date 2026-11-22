import os
import XCTest

/// Spec 006 + 018: the app reloads by itself (scene becomes active, `next_due` reached) and has no pull-to-refresh.
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

  // MARK: - 018 #1, #2 (Study: no pull, no move)

  /// 018 #1, #2: a downward drag on a short card neither refreshes nor moves the card (mid-drag and after).
  @MainActor
  func testStudy_noPullOnCard() throws {
    XCUIDevice.shared.appearance = .light
    let (server, deck) = try startStub([card(Self.idA, "canine", "dog")])
    let app = launch(api: .live(server.url))
    assertFront(app, "canine", remaining: "1 to review")
    deck.add(card(Self.idB, "feline", "cat", minutes: 1))  // a refresh would show "2 to review"
    assertNoPull(app, server, from: el(app, "study.card"), watching: el(app, "study.front"),
                 routes: ["/cards/due", "/stats"], name: "study-no-pull-mid-drag")
    assertFront(app, "canine", remaining: "1 to review")
    snapshot("study-no-pull", appearance: .light)
    app.terminate()
    server.stop()
  }

  /// 018 #1, #2: the message states (caught up, no cards yet, offline) have no pull-to-refresh either, and the caught-up
  /// message doesn't move under the drag.
  @MainActor
  func testStudy_noPullOnMessages() throws {
    XCUIDevice.shared.appearance = .light
    // Caught up: the only card is due tomorrow (a 30 s auto-check can't fire during the 3 s watch).
    let (server, deck) = try startStub([card(Self.idA, "canine", "dog", minutes: 24 * 60, fromNow: true)])
    var app = launch(api: .live(server.url))
    waitForLabel(el(app, "study.message"), "All caught up")
    deck.add(card(Self.idB, "feline", "cat"))  // due now: a refresh would show it
    assertNoPull(app, server, from: el(app, "study.message"), watching: el(app, "study.message"),
                 routes: ["/cards/due", "/stats"], name: "study-caught-up-no-pull-mid-drag")
    waitForLabel(el(app, "study.message"), "All caught up")
    XCTAssertFalse(el(app, "study.front").exists, "caught up: a card showed after the drag")
    snapshot("study-caught-up-no-pull", appearance: .light)
    app.terminate()
    server.stop()

    // No cards yet.
    let (emptyServer, emptyDeck) = try startStub([])
    app = launch(api: .live(emptyServer.url))
    waitForLabel(el(app, "study.message"), "No cards yet")
    emptyDeck.add(card(Self.idA, "canine", "dog"))
    assertNoPull(app, emptyServer, from: el(app, "study.message"), watching: el(app, "study.message"),
                 routes: ["/cards/due", "/stats"], name: "study-empty-no-pull-mid-drag")
    waitForLabel(el(app, "study.message"), "No cards yet")
    snapshot("study-empty-no-pull", appearance: .light)
    app.terminate()
    emptyServer.stop()

    // Offline: the API answers 503 to everything.
    let down = StubAPIServer { _ in .init(status: 503, body: #"{"detail":"down"}"#) }
    try down.start()
    app = launch(api: .live(down.url))
    waitForLabel(el(app, "study.message"), "Can't reach your deck", timeout: 20)
    assertNoPull(app, down, from: el(app, "study.message"), watching: el(app, "study.message"),
                 routes: ["/cards/due", "/stats"], name: "study-offline-no-pull-mid-drag")
    waitForLabel(el(app, "study.message"), "Can't reach your deck")
    snapshot("study-offline-no-pull", appearance: .light)
    app.terminate()
    down.stop()
  }

  // MARK: - 018 #3 (Deck: no pull, no bounce)

  /// 018 #3: a downward drag on a row of a short list makes no `GET /notes`, shows no refresh control, and the list
  /// doesn't bounce (the row keeps its place relative to the sheet's toolbar; the sheet itself may follow the finger).
  @MainActor
  func testDeck_noPull() throws {
    XCUIDevice.shared.appearance = .light
    let (server, deck) = try startStub([card(Self.idA, "canine", "dog"), card(Self.idB, "feline", "cat", minutes: 1)])
    let app = launch(api: .live(server.url))
    openDeck(app)
    XCTAssertTrue(row(app, Self.idA).waitFor(timeout: 10), "canine row missing")
    deck.add(card(Self.idC, "raven", "blackbird", minutes: 2))  // a refresh would add this row
    let rowFrame = row(app, Self.idA).frame
    assertNoPull(app, server, from: row(app, Self.idA), watching: row(app, Self.idA), routes: ["/notes"],
                 name: "deck-no-pull-mid-drag", relativeTo: el(app, "deck.add"))
    XCTAssertTrue(deckTitle(app).exists, "the drag closed the deck sheet")
    XCTAssertFalse(row(app, Self.idC).exists, "raven row shown: the drag refreshed the list")
    XCTAssertEqual(row(app, Self.idA).frame.minY, rowFrame.minY, accuracy: 1, "row moved after the drag")
    snapshot("deck-no-pull", appearance: .light)
    app.terminate()
    server.stop()
  }

  // MARK: - 018 #12 (next_due reached → card shows by itself)

  /// 018 #12: caught up with one card due 8 s after the app's first request → the card shows by itself (no tap or
  /// drag), unrevealed, "1 to review", after it's due and within 7 s of it. The due time is anchored to the app's first
  /// request, not to the test's clock, so a slow launch can't make the card due before "All caught up" shows.
  @MainActor
  func testStudy_autoRefreshAtNextDue() throws {
    for appearance in [XCUIDevice.Appearance.light, .dark] {
      XCUIDevice.shared.appearance = appearance
      let deck = StubDeck([])
      let dueAt = OSAllocatedUnfairLock<Date?>(initialState: nil)
      let server = StubAPIServer { request in
        dueAt.withLock { due in
          guard due == nil else { return }
          let at = Date().addingTimeInterval(8)
          due = at
          deck.add(.init(id: Self.idA, front: "canine", back: "dog", due: at, createdAt: Self.base))
        }
        return deck.handle(request)
      }
      try server.start()
      let app = launch(api: .live(server.url))
      waitForLabel(el(app, "study.message"), "All caught up")
      XCTAssertTrue(el(app, "study.nextDue").waitFor(timeout: 5), "study.nextDue missing")
      XCTAssertFalse(el(app, "study.front").exists, "card shown before it is due")
      snapshot("study-auto-due-before", appearance: appearance)

      let due = try XCTUnwrap(dueAt.withLock { $0 }, "the app made no request")
      waitForLabel(el(app, "study.front"), "canine", timeout: max(due.addingTimeInterval(7).timeIntervalSinceNow, 0.1))
      XCTAssertLessThanOrEqual(Date().timeIntervalSince(due), 7.5, "card shown later than 7 s after it was due")
      XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(due), -0.5, "card shown before it was due")
      assertFront(app, "canine", remaining: "1 to review")
      XCTAssertFalse(el(app, "study.message").exists, "study.message still shown with the card")
      snapshot("study-auto-due", appearance: appearance)
      app.terminate()
      server.stop()
    }
  }

  // MARK: - Helpers

  /// Due `minutes` after 2026-01-01 (due now), or after the current time with `fromNow`.
  private func card(_ id: String, _ front: String, _ back: String, minutes: Double = 0,
                    fromNow: Bool = false) -> StubDeck.Card {
    let at = (fromNow ? Date() : Self.base).addingTimeInterval(minutes * 60)
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

  /// Topmost y (pt, 0.5 pt steps) in `rect` with dark text (light appearance), nil if none.
  private func inkTop(_ probe: ColorProbe, in rect: CGRect) -> CGFloat? {
    stride(from: rect.minY, to: min(rect.maxY, probe.size.height), by: 0.5).first { y in
      stride(from: rect.minX, to: rect.maxX, by: 0.5).contains { x in
        let c = probe.color(at: CGPoint(x: x, y: y))
        return c.r + c.g + c.b < 200
      }
    }
  }

  /// 018 #1–#3: drag down from `from` (held, with a mid-drag screenshot): `watching` doesn't move during the drag
  /// (relative to `relativeTo` when given, e.g. the sheet title, else to the screen) nor after it, no GET on `routes`
  /// within 3 s, and no activity indicator.
  @MainActor
  private func assertNoPull(_ app: XCUIApplication, _ server: StubAPIServer, from: XCUIElement, watching: XCUIElement,
                            routes: Set<String>, name: String, relativeTo anchor: XCUIElement? = nil,
                            file: StaticString = #filePath, line: UInt = #line) {
    func gets() -> Int { server.requests.filter { $0.method == "GET" && routes.contains(StubDeck.route($0.path)) }.count }
    let before = gets()
    let frame = watching.frame
    let anchorFrame = anchor?.frame
    let still = XCUIScreen.main.screenshot().image.cgImage
    let during = dragDownHoldingCapture(app, from: from, name: name, appearance: .light)
    if let anchorFrame {
      // The sheet may follow the finger (interactive dismiss, native): compare the row to the sheet's toolbar.
      // The anchor is a toolbar glyph: fixed in the sheet, so it moves only if the whole sheet follows the finger.
      let anchorRect = CGRect(x: anchorFrame.minX, y: anchorFrame.minY - 10, width: anchorFrame.width, height: 400)
      func offset(_ img: CGImage?) -> CGFloat? {
        guard let img else { return nil }
        let probe = ColorProbe(at3x: img)
        guard let t = inkTop(probe, in: anchorRect) else { return nil }
        let rowRect = CGRect(x: frame.minX, y: t + frame.minY - anchorFrame.minY - 40, width: frame.width * 0.5,
                             height: frame.height + 80)
        return inkTop(probe, in: rowRect).map { $0 - t }
      }
      let o1 = offset(still), o2 = offset(during)
      XCTAssertNotNil(o1, "\(name): no text found before the drag", file: file, line: line)
      XCTAssertNotNil(o2, "\(name): no text found mid-drag", file: file, line: line)
      if let o1, let o2 {
        // A rubber-band would pull the row down by tens of points; the dragged sheet itself shifts its content by a
        // few points (measured −3.5 pt on iOS 27), so allow 5 pt and never a downward move.
        XCTAssertTrue(o2 <= o1 + 1 && abs(o2 - o1) <= 5,
                      "\(name): the list moved under the drag (bounce): row−toolbar \(o1) → \(o2)", file: file, line: line)
      }
    } else {
      let changed = changedPoints(still, during, in: frame.insetBy(dx: -4, dy: -4))
      XCTAssertLessThanOrEqual(changed, 4, "\(name): content moved under the drag (\(changed) changed points)",
                               file: file, line: line)
    }
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      XCTAssertFalse(app.activityIndicators.firstMatch.exists, "\(name): activity indicator after the drag",
                     file: file, line: line)
      Thread.sleep(forTimeInterval: 0.5)
    }
    XCTAssertEqual(gets(), before, "\(name): GET \(routes.sorted()) after the drag: "
                   + server.requests.suffix(4).map { "\($0.method) \($0.path)" }.joined(separator: ", "),
                   file: file, line: line)
    XCTAssertEqual(watching.frame.minY, frame.minY, accuracy: 1, "\(name): moved after the drag: \(frame) → \(watching.frame)",
                   file: file, line: line)
  }
}
