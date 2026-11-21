import XCTest

/// Spec 001: Study session (home). Replaces spec 000's `testHome_*`.
/// Mock deck = `LA_CARTE_API=mock`: serendipity, la carte, ephemeral (all due, fixture order).
final class StudyUITests: XCTestCase {
  static let ratings = ["again", "hard", "good", "easy"]
  static let fixtures: [(front: String, back: String)] = [
    ("serendipity", "finding something good without looking for it"),
    ("la carte", "the menu — and the map"),
    ("ephemeral", "lasting a very short time"),
  ]

  override func setUp() {
    continueAfterFailure = false
  }

  // MARK: - Studying (criteria 1, 2, 3, 4, 8)

  /// #1 front centered + "3 to review", #3 no ratings before reveal, #2 tap card / reveal button,
  /// #4 rate → next card unrevealed + decrement, #8 corner buttons present and 44pt.
  @MainActor
  func testStudy_frontRevealRateNext() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock)

    // Front, unrevealed.
    assertFront(app, Self.fixtures[0].front, remaining: "3 to review")
    assertCornerButtons(app)
    snapshot("study-front", appearance: .light)
    let frontBefore = el(app, "study.front").frame

    // Reveal by tapping the card (middle area).
    el(app, "study.card").tap()
    assertRevealed(app, front: Self.fixtures[0].front, back: Self.fixtures[0].back)
    assertFrontDidNotMove(app, from: frontBefore)
    assertCornerButtons(app)
    snapshot("study-revealed", appearance: .light)

    // Rate → next card, unrevealed, remaining decrements.
    el(app, "study.rate.good").tap()
    assertFront(app, Self.fixtures[1].front, remaining: "2 to review")

    // Reveal with the "Show answer" button this time.
    let secondBefore = el(app, "study.front").frame
    XCTAssertGreaterThanOrEqual(el(app, "study.reveal").frame.height, 43.99,
                                "study.reveal hit area under 44pt: \(el(app, "study.reveal").frame)")
    el(app, "study.reveal").tap()
    assertRevealed(app, front: Self.fixtures[1].front, back: Self.fixtures[1].back)
    assertFrontDidNotMove(app, from: secondBefore)
    el(app, "study.rate.hard").tap()
    assertFront(app, Self.fixtures[2].front, remaining: "1 to review")
  }

  /// #4 + #5: rate every due card (each rating button once at least) → "All caught up" + "Next card in…".
  @MainActor
  func testStudy_rateAllToCaughtUp() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock)
    let plan = ["easy", "again", "good"]
    for (index, card) in Self.fixtures.enumerated() {
      assertFront(app, card.front, remaining: "\(3 - index) to review")
      el(app, index.isMultiple(of: 2) ? "study.card" : "study.reveal").tap()
      assertRevealed(app, front: card.front, back: card.back)
      el(app, "study.rate.\(plan[index])").tap()
    }
    assertCaughtUp(app, nextDuePrefix: "Next card in")
    assertCornerButtons(app)
    snapshot("study-caught-up", appearance: .light)
  }

  /// #8 + spec 002 #1/#7: `study.deck` opens the deck sheet, `study.add` opens the "New card" editor; closing
  /// either without changes leaves the session untouched.
  @MainActor
  func testStudy_cornerButtonsTappable() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock)
    assertFront(app, Self.fixtures[0].front, remaining: "3 to review")

    XCTAssertTrue(el(app, "study.deck").isHittable, "study.deck not hittable")
    el(app, "study.deck").tap()
    waitForLabel(el(app, "deck.title"), "Cards")
    swipeSheetDown(app, from: el(app, "deck.title"))
    waitForAbsence(el(app, "deck.title"), "deck sheet still open after swiping down")
    assertFront(app, Self.fixtures[0].front, remaining: "3 to review")

    XCTAssertTrue(el(app, "study.add").isHittable, "study.add not hittable")
    el(app, "study.add").tap()
    waitForLabel(el(app, "editor.title"), "New card")
    el(app, "editor.close").tap()
    waitForAbsence(el(app, "editor.title"), "editor still open after editor.close")
    assertFront(app, Self.fixtures[0].front, remaining: "3 to review")
  }

  // MARK: - Stub-API states (criteria 4, 5, 6, 7)

  /// #6: `/stats` with `next_due: null` → "All caught up" / "Your deck is empty".
  @MainActor
  func testStudy_emptyDeck() throws {
    let server = StubAPIServer { request in
      if request.path.hasPrefix("/cards/due") { return .init(body: "[]") }
      if request.path.hasPrefix("/stats") { return .init(body: StubJSON.stats(total: 0, nextDue: nil)) }
      return .init(status: 404, body: "{}")
    }
    try server.start()
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .live(server.url))
    assertCaughtUp(app, nextDueLabel: "Your deck is empty")
    assertCornerButtons(app)
    snapshot("study-empty", appearance: .light)
    server.stop()
  }

  /// #7: API unreachable → "Can't reach your deck" + retry; when the API comes back, retry reloads due cards.
  @MainActor
  func testStudy_offlineThenRetry() throws {
    XCUIDevice.shared.appearance = .light
    let card = StubJSON.card(id: "22222222-2222-2222-2222-222222222222", front: "gratitude", back: "thank you")
    let server = StubAPIServer { request in
      if request.path.hasPrefix("/cards/due") { return .init(body: StubJSON.cards([card])) }
      return .init(status: 404, body: "{}")
    }
    // Server not started yet: the port refuses connections.
    let app = launch(api: .live(server.url))
    assertOffline(app)
    snapshot("study-offline", appearance: .light)

    // Retry while still down → still offline (and still usable).
    el(app, "study.retry").tap()
    assertOffline(app)

    // API back → retry loads the due card.
    try server.start()
    el(app, "study.retry").tap()
    assertFront(app, "gratitude", remaining: "1 to review")
    XCTAssertFalse(el(app, "study.message").exists, "study.message still shown after a successful retry")
    XCTAssertFalse(el(app, "study.retry").exists, "study.retry still shown after a successful retry")
    snapshot("study-retry-recovered", appearance: .light)
    server.stop()
  }

  // MARK: - Dynamic Type (criterion 11)

  /// #11 at accessibility XL, three cards in one launch (rated in turn):
  /// 1. short card: readable, scaled, centered, ratings reachable;
  /// 2. long text wraps (multi-line), stays centered, nothing clipped. Card text stops growing at `.accessibility2`
  ///    and the card area scrolls if still too long: every line reachable, never drawn under the rating row;
  /// 3. text too long for one screen even when capped: the card area scrolls in place and the end is reachable.
  @MainActor
  func testStudy_accessibilityXL() throws {
    XCUIDevice.shared.appearance = .light
    let baseline = launch(api: .mock)
    XCTAssertTrue(el(baseline, "study.front").waitFor(timeout: 5))
    let baseHeight = el(baseline, "study.front").frame.height
    baseline.terminate()

    let long = (front: "the quick brown fox jumps over the lazy dog near the riverbank",
                back: "a sentence that uses every letter of the alphabet, often used to test typewriters and fonts")
    let veryLong = (front: "a very long prompt that keeps going so that even with the card text capped it cannot possibly fit",
                    back: "an equally long answer, several sentences long, written to overflow the card area at accessibility "
                      + "sizes so that the only way to read its final words is to scroll the card area up: the end")
    let ids = ["33333333-3333-3333-3333-333333333333", "44444444-4444-4444-4444-444444444444",
               "55555555-5555-5555-5555-555555555555"]
    let cards = zip(ids, [Self.fixtures[0], long, veryLong]).map { StubJSON.card(id: $0, front: $1.front, back: $1.back) }
    let server = StubAPIServer { request in
      if request.path.hasPrefix("/cards/due") { return .init(body: StubJSON.cards(cards)) }
      if request.method == "POST", let i = ids.firstIndex(where: { request.path == "/cards/\($0)/review" }) {
        return .init(body: cards[i])
      }
      return .init(status: 404, body: "{}")
    }
    try server.start()
    let app = launch(api: .live(server.url), arguments: accessibilityXLArguments)

    // 1. Short card.
    assertFront(app, Self.fixtures[0].front, remaining: "3 to review")
    var frontBefore = el(app, "study.front").frame
    el(app, "study.reveal").tap()
    assertRevealed(app, front: Self.fixtures[0].front, back: Self.fixtures[0].back)
    assertFrontDidNotMove(app, from: frontBefore)
    snapshot("study-xl", appearance: .light)
    assertTextsReadable(in: app)
    assertRatingRowUsable(app)
    XCTAssertGreaterThan(el(app, "study.front").frame.height, baseHeight * 1.3,
                         "study.front did not scale with Dynamic Type (height \(baseHeight) at default)")
    el(app, "study.rate.good").tap()

    // 2. Long text: wraps; the end of the back is reachable (already above the rating row, or after scrolling).
    assertFront(app, long.front, remaining: "2 to review")
    snapshot("study-xl-long-front", appearance: .light)
    let topRowBottom = max(el(app, "study.deck").frame.maxY, el(app, "study.remaining").frame.maxY)
    frontBefore = el(app, "study.front").frame
    XCTAssertGreaterThanOrEqual(frontBefore.minY, topRowBottom - 1,
                                "study.front starts under the top row before reveal: \(frontBefore)")
    el(app, "study.card").tap()
    assertRevealed(app, front: long.front, back: long.back)
    assertFrontDidNotMove(app, from: frontBefore)
    snapshot("study-xl-long", appearance: .light)
    var ratingTop = Self.ratings.map { el(app, "study.rate.\($0)").frame.minY }.min()!
    var cardFrame = el(app, "study.card").frame
    XCTAssertLessThanOrEqual(cardFrame.maxY, ratingTop + 1,
                             "study.card (text area) extends under the rating row: card \(cardFrame), ratings top \(ratingTop)")
    XCTAssertGreaterThanOrEqual(cardFrame.minY, topRowBottom - 1,
                                "study.card (text area) extends under the top row: \(cardFrame)")
    for id in ["study.front", "study.back"] {
      let f = el(app, id).frame
      XCTAssertGreaterThan(f.height, 100, "\(id) should wrap to several lines at XL: \(f)")
    }
    if el(app, "study.back").frame.maxY > ratingTop + 1 {
      for _ in 0..<4 where el(app, "study.back").frame.maxY > ratingTop + 1 {
        el(app, "study.card").swipeUp()
      }
      snapshot("study-xl-long-scrolled", appearance: .light)
    }
    var backEnd = el(app, "study.back").frame
    XCTAssertLessThanOrEqual(backEnd.maxY, ratingTop + 1,
                             "end of study.back unreachable: still under the rating row after scrolling: \(backEnd)")
    XCTAssertLessThanOrEqual(backEnd.maxY, cardFrame.maxY + 1, "end of study.back outside the card area: \(backEnd)")
    assertRatingRowUsable(app, checkBackAbove: false)
    assertRevealed(app, front: long.front, back: long.back)  // scrolling didn't un-reveal
    el(app, "study.rate.good").tap()

    // 3. Very long text: must scroll; the card area itself stays put.
    assertFront(app, veryLong.front, remaining: "1 to review")
    snapshot("study-xl-verylong-front", appearance: .light)
    frontBefore = el(app, "study.front").frame
    XCTAssertGreaterThanOrEqual(frontBefore.minY, topRowBottom - 1,
                                "study.front starts under the top row before reveal: \(frontBefore)")
    el(app, "study.reveal").tap()
    assertRevealed(app, front: veryLong.front, back: veryLong.back)
    assertFrontDidNotMove(app, from: frontBefore)
    snapshot("study-xl-verylong", appearance: .light)
    ratingTop = Self.ratings.map { el(app, "study.rate.\($0)").frame.minY }.min()!
    cardFrame = el(app, "study.card").frame
    XCTAssertLessThanOrEqual(cardFrame.maxY, ratingTop + 1,
                             "study.card extends under the rating row: card \(cardFrame), ratings top \(ratingTop)")
    XCTAssertGreaterThan(el(app, "study.back").frame.maxY, ratingTop,
                         "fixture not long enough to need scrolling; the scroll path is untested")
    for _ in 0..<6 where el(app, "study.back").frame.maxY > ratingTop + 1 {
      el(app, "study.card").swipeUp()
    }
    snapshot("study-xl-verylong-scrolled", appearance: .light)
    backEnd = el(app, "study.back").frame
    XCTAssertLessThanOrEqual(backEnd.maxY, min(ratingTop, cardFrame.maxY) + 1,
                             "end of study.back unreachable by scrolling: \(backEnd)")
    let cardAfter = el(app, "study.card").frame
    XCTAssertEqual(cardAfter.minY, cardFrame.minY, accuracy: 0.5, "the card area itself moved while scrolling")
    XCTAssertEqual(cardAfter.height, cardFrame.height, accuracy: 0.5, "the card area resized while scrolling")
    assertRatingRowUsable(app, checkBackAbove: false)
    XCTAssertFalse(el(app, "study.reveal").exists, "scrolling un-revealed the card")
    server.stop()
  }

  /// #11 + layout note: the card-text cap at `.accessibility2`. At AX5 the card text is the same size as at
  /// AX XL (capped), the rating row stays usable, and the fixture card still fits without overlap.
  @MainActor
  func testStudy_accessibilityXXXLCapped() {
    XCUIDevice.shared.appearance = .light
    let xl = launch(api: .mock, arguments: accessibilityXLArguments)
    XCTAssertTrue(el(xl, "study.front").waitFor(timeout: 5))
    let xlHeight = el(xl, "study.front").frame.height
    xl.terminate()

    let app = launch(api: .mock, arguments: ["-UIPreferredContentSizeCategoryName",
                                             "UICTContentSizeCategoryAccessibilityXXXL"])
    assertFront(app, Self.fixtures[0].front, remaining: "3 to review")
    XCTAssertEqual(el(app, "study.front").frame.height, xlHeight, accuracy: 1,
                   "card text not capped: front height at AX5 differs from AX XL (\(xlHeight))")
    let frontBefore = el(app, "study.front").frame
    el(app, "study.reveal").tap()
    assertRevealed(app, front: Self.fixtures[0].front, back: Self.fixtures[0].back)
    assertFrontDidNotMove(app, from: frontBefore)
    snapshot("study-xxxl", appearance: .light)
    assertTextsReadable(in: app)
    assertRatingRowUsable(app)
  }

  // MARK: - Live API (criterion 10)

  /// #10: scripts/e2e.sh seeds `greeting`/`hello` then `gratitude`/`thank you`. Reveal + rate good twice →
  /// "All caught up" + "Next card in…", and the API recorded both reviews.
  @MainActor
  func testStudy_revealRateToCaughtUp_liveAPI() throws {
    let url = try liveURL("LA_CARTE_API_URL")
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .live(url))
    assertFront(app, "greeting", remaining: "2 to review")
    snapshot("study-live-front", appearance: .light)
    el(app, "study.card").tap()
    assertRevealed(app, front: "greeting", back: "hello")
    el(app, "study.rate.good").tap()
    assertFront(app, "gratitude", remaining: "1 to review")
    el(app, "study.reveal").tap()
    assertRevealed(app, front: "gratitude", back: "thank you")
    el(app, "study.rate.good").tap()
    assertCaughtUp(app, nextDuePrefix: "Next card in")
    snapshot("study-live", appearance: .light)

    let stats = try getJSON(url + "/stats")
    XCTAssertEqual(stats["reviewed_today"] as? Int, 2, "API stats after the session: \(stats)")
    XCTAssertEqual(stats["due"] as? Int, 0, "API stats after the session: \(stats)")
    XCTAssertNotNil(stats["next_due"] as? String, "API stats after the session: \(stats)")
  }

  /// #6 against the real API: scripts/e2e.sh starts a second, unseeded API (`next_due: null`).
  @MainActor
  func testStudy_emptyDeck_liveAPI() throws {
    let url = try liveURL("LA_CARTE_EMPTY_API_URL")
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .live(url))
    assertCaughtUp(app, nextDueLabel: "Your deck is empty")
    snapshot("study-live-empty", appearance: .light)
  }

  // MARK: - Helpers

  @MainActor
  private func assertFront(_ app: XCUIApplication, _ front: String, remaining: String,
                           file: StaticString = #filePath, line: UInt = #line) {
    let frontEl = el(app, "study.front")
    waitForLabel(frontEl, front, file: file, line: line)
    waitForLabel(el(app, "study.remaining"), remaining, file: file, line: line)
    let window = app.windows.firstMatch.frame
    XCTAssertEqual(frontEl.frame.midX, window.midX, accuracy: 1, "study.front not centered: \(frontEl.frame)",
                   file: file, line: line)
    XCTAssertEqual(el(app, "study.remaining").frame.midX, window.midX, accuracy: 1,
                   "study.remaining not centered", file: file, line: line)
    XCTAssertFalse(el(app, "study.back").exists, "study.back visible before reveal", file: file, line: line)
    XCTAssertTrue(el(app, "study.reveal").waitFor(timeout: 5), "study.reveal missing", file: file, line: line)
    XCTAssertTrue(el(app, "study.reveal").isHittable, "study.reveal not hittable", file: file, line: line)
    XCTAssertEqual(el(app, "study.reveal").label, "Show answer", file: file, line: line)
    XCTAssertTrue(el(app, "study.card").exists, "study.card missing", file: file, line: line)
    for rating in Self.ratings {
      XCTAssertFalse(el(app, "study.rate.\(rating)").exists, "study.rate.\(rating) exists before reveal",
                     file: file, line: line)
    }
  }

  /// Layout note: "The front never moves on reveal" (the back's and rating row's space is reserved).
  @MainActor
  private func assertFrontDidNotMove(_ app: XCUIApplication, from before: CGRect,
                                     file: StaticString = #filePath, line: UInt = #line) {
    // Let the 0.25s fade settle, then compare.
    _ = el(app, "study.rate.easy").waitFor(timeout: 3)
    _ = poll(timeout: 2) { abs(el(app, "study.front").frame.minY - before.minY) < 0.5 }  // 0.25 s fade
    let after = el(app, "study.front").frame
    XCTAssertEqual(after.minY, before.minY, accuracy: 0.5, "study.front moved on reveal: \(before) → \(after)",
                   file: file, line: line)
    XCTAssertEqual(after.midX, before.midX, accuracy: 0.5, "study.front moved on reveal: \(before) → \(after)",
                   file: file, line: line)
    XCTAssertEqual(after.height, before.height, accuracy: 0.5, "study.front resized on reveal: \(before) → \(after)",
                   file: file, line: line)
  }

  @MainActor
  private func assertRevealed(_ app: XCUIApplication, front: String, back: String,
                              file: StaticString = #filePath, line: UInt = #line) {
    let backEl = el(app, "study.back")
    waitForLabel(backEl, back, timeout: 5, file: file, line: line)
    XCTAssertEqual(el(app, "study.front").label, front, file: file, line: line)
    XCTAssertGreaterThanOrEqual(backEl.frame.minY, el(app, "study.front").frame.maxY - 1,
                                "study.back not below study.front", file: file, line: line)
    let window = app.windows.firstMatch.frame
    XCTAssertEqual(backEl.frame.midX, window.midX, accuracy: 1, "study.back not centered: \(backEl.frame)",
                   file: file, line: line)
    waitForAbsence(el(app, "study.reveal"), timeout: 3, "study.reveal still shown after reveal", file: file, line: line)
    let labels = ["again": "Again", "hard": "Hard", "good": "Good", "easy": "Easy"]
    for rating in Self.ratings {
      let button = el(app, "study.rate.\(rating)")
      XCTAssertTrue(button.waitFor(timeout: 3), "study.rate.\(rating) missing", file: file, line: line)
      XCTAssertTrue(button.isEnabled, "study.rate.\(rating) disabled", file: file, line: line)
      XCTAssertEqual(button.label, labels[rating], file: file, line: line)
    }
  }

  @MainActor
  private func assertCaughtUp(_ app: XCUIApplication, nextDuePrefix: String? = nil, nextDueLabel: String? = nil,
                              timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
    waitForLabel(el(app, "study.message"), "All caught up", timeout: timeout, file: file, line: line)
    let nextDue = el(app, "study.nextDue")
    XCTAssertTrue(nextDue.waitFor(timeout: 5), "study.nextDue missing", file: file, line: line)
    if let nextDueLabel { waitForLabel(nextDue, nextDueLabel, file: file, line: line) }
    if let nextDuePrefix {
      XCTAssertTrue(nextDue.label.hasPrefix(nextDuePrefix), "study.nextDue = '\(nextDue.label)'", file: file, line: line)
    }
    let window = app.windows.firstMatch.frame
    XCTAssertEqual(el(app, "study.message").frame.midX, window.midX, accuracy: 1, "study.message not centered",
                   file: file, line: line)
    XCTAssertEqual(nextDue.frame.midX, window.midX, accuracy: 1, "study.nextDue not centered", file: file, line: line)
    XCTAssertGreaterThanOrEqual(nextDue.frame.minY, el(app, "study.message").frame.maxY - 1,
                                "study.nextDue not below study.message", file: file, line: line)
    for id in ["study.remaining", "study.card", "study.front", "study.reveal", "study.retry"]
      + Self.ratings.map({ "study.rate.\($0)" }) {
      XCTAssertFalse(el(app, id).exists, "\(id) exists in the caught-up state", file: file, line: line)
    }
  }

  @MainActor
  private func assertOffline(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    waitForLabel(el(app, "study.message"), "Can't reach your deck", timeout: 20, file: file, line: line)
    let retry = el(app, "study.retry")
    XCTAssertTrue(retry.waitFor(timeout: 5), "study.retry missing", file: file, line: line)
    XCTAssertTrue(retry.isHittable, "study.retry not hittable", file: file, line: line)
    // 44pt within half a point: XCUI reports 43.67 (131px @3x) for a 44pt circle at a fractional origin.
    XCTAssertGreaterThanOrEqual(retry.frame.width, 43.5, "study.retry too narrow: \(retry.frame)", file: file, line: line)
    XCTAssertGreaterThanOrEqual(retry.frame.height, 43.5, "study.retry too short: \(retry.frame)", file: file, line: line)
    XCTAssertGreaterThanOrEqual(retry.frame.minY, el(app, "study.message").frame.maxY - 1,
                                "study.retry not below study.message", file: file, line: line)
    let window = app.windows.firstMatch.frame
    XCTAssertEqual(retry.frame.midX, window.midX, accuracy: 1, "study.retry not centered", file: file, line: line)
    for id in ["study.remaining", "study.card", "study.front", "study.reveal", "study.nextDue"]
      + Self.ratings.map({ "study.rate.\($0)" }) {
      XCTAssertFalse(el(app, id).exists, "\(id) exists in the offline state", file: file, line: line)
    }
    assertCornerButtons(app, file: file, line: line)
  }

  /// #8: deck top-left, add top-right, 44pt, same top margin, `study.remaining` (if any) on the same line.
  @MainActor
  private func assertCornerButtons(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let deck = el(app, "study.deck"), add = el(app, "study.add")
    XCTAssertTrue(deck.waitFor(timeout: 5), "study.deck missing", file: file, line: line)
    XCTAssertTrue(add.exists, "study.add missing", file: file, line: line)
    let window = app.windows.firstMatch.frame
    for (id, b) in [("study.deck", deck), ("study.add", add)] {
      XCTAssertTrue(b.isHittable, "\(id) not hittable", file: file, line: line)
      XCTAssertEqual(b.frame.width, 44, accuracy: 1, "\(id) not 44pt wide: \(b.frame)", file: file, line: line)
      XCTAssertEqual(b.frame.height, 44, accuracy: 1, "\(id) not 44pt tall: \(b.frame)", file: file, line: line)
    }
    XCTAssertLessThan(deck.frame.midX, window.width / 4, "study.deck not top-left: \(deck.frame)", file: file, line: line)
    XCTAssertGreaterThan(add.frame.midX, window.width * 3 / 4, "study.add not top-right: \(add.frame)", file: file, line: line)
    XCTAssertLessThan(deck.frame.maxY, window.height / 5, "study.deck not at the top: \(deck.frame)", file: file, line: line)
    XCTAssertEqual(deck.frame.minY, add.frame.minY, accuracy: 0.5, "corner buttons not aligned", file: file, line: line)
    // Symmetric side margins.
    XCTAssertEqual(deck.frame.minX - window.minX, window.maxX - add.frame.maxX, accuracy: 1,
                   "corner buttons have unequal side margins", file: file, line: line)
    let remaining = el(app, "study.remaining")
    if remaining.exists {
      XCTAssertEqual(remaining.frame.midY, deck.frame.midY, accuracy: 2,
                     "study.remaining not on the corner-button line", file: file, line: line)
    }
  }

  @MainActor
  private func assertRatingRowUsable(_ app: XCUIApplication, checkBackAbove: Bool = true,
                                     file: StaticString = #filePath, line: UInt = #line) {
    let window = app.windows.firstMatch.frame
    let frames = Self.ratings.map { el(app, "study.rate.\($0)").frame }
    for (rating, f) in zip(Self.ratings, frames) {
      XCTAssertTrue(el(app, "study.rate.\(rating)").isHittable, "study.rate.\(rating) not hittable", file: file, line: line)
      XCTAssertTrue(window.contains(f), "study.rate.\(rating) outside the window: \(f)", file: file, line: line)
      XCTAssertGreaterThanOrEqual(f.height, 43.99, "study.rate.\(rating) hit area too short: \(f)", file: file, line: line)
      if checkBackAbove {
        XCTAssertGreaterThanOrEqual(f.minY, el(app, "study.back").frame.maxY - 1,
                                    "study.rate.\(rating) overlaps the back text", file: file, line: line)
      }
    }
    for (i, a) in frames.enumerated() {
      for b in frames[(i + 1)...] {
        let overlap = a.intersection(b)
        XCTAssertTrue(overlap.isNull || overlap.width < 1 || overlap.height < 1,
                      "rating buttons overlap: \(a) / \(b)", file: file, line: line)
      }
    }
  }

  private func liveURL(_ name: String) throws -> String {
    guard let url = ProcessInfo.processInfo.environment[name], !url.isEmpty else {
      throw XCTSkip("\(name) not set — run scripts/e2e.sh")
    }
    return url
  }

  private func getJSON(_ url: String) throws -> [String: Any] {
    var request = URLRequest(url: URL(string: url)!)
    if let token = ProcessInfo.processInfo.environment["LA_CARTE_API_TOKEN"] {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    var result: Data?
    let done = expectation(description: "GET \(url)")
    URLSession.shared.dataTask(with: request) { data, _, _ in
      result = data
      done.fulfill()
    }.resume()
    wait(for: [done], timeout: 10)
    let data = try XCTUnwrap(result, "no response from \(url)")
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
