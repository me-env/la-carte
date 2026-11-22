import XCTest

/// Spec 011: two rating buttons ("Forgot", "Got it") + a horizontal drag on the revealed card that draws a ring of
/// confidence dots and, on release, sends one of the four grades.
/// Drag unit: `f` = card-width fraction from the card's center (spec: +0.13 good, +0.22 easy, -0.13 hard,
/// -0.22 again, +0.04 cancel). Held states come from the DEBUG launch argument `-studySwipePreview " <f>"`.
final class RatingsUITests: XCTestCase {
  /// (file suffix, system appearance, `-theme` value). Forest forces its own dark palette.
  static let variants: [(name: String, appearance: XCUIDevice.Appearance, theme: String)] = [
    ("light", .light, "system"), ("dark", .dark, "system"), ("forest-dark", .light, "forest"),
  ]
  /// Held drag states (spec 019 #5, #6): (screenshot state, launch argument, f, ring value, left label, right label).
  static let held: [(state: String, arg: String, f: Double, grade: String, left: String, right: String)] = [
    ("again", "-studySwipePreview", -0.22, "Forgot", "Forgot", "Got it"),
    ("hard", "-studySwipePreview", -0.13, "Hard", "Hard", "Got it"),
    ("neutral", "-studySwipePreview", 0.04, "None", "Forgot", "Got it"),
    ("good", "-studySwipePreview", 0.13, "Got it", "Forgot", "Got it"),
    ("easy", "-studySwipePreview", 0.22, "Easy", "Forgot", "Easy"),
    ("easy-up", "-studySwipePreviewUp", 0.22, "Easy", "Forgot", "Easy"),
  ]
  static let mockFront = "serendipity", mockBack = "finding something good without looking for it"

  override func setUp() {
    continueAfterFailure = false
  }

  // MARK: - #1 two buttons (light, dark, forest)

  @MainActor
  func testRatings_twoButtons() {
    for v in Self.variants {
      XCUIDevice.shared.appearance = v.appearance
      let app = launch(api: .mock, theme: v.theme)
      waitForLabel(el(app, "study.front"), Self.mockFront)
      for id in ["study.rate.again", "study.rate.good", "study.rate.hard", "study.rate.easy"] {
        XCTAssertFalse(el(app, id).exists, "\(id) exists before reveal (\(v.name))")
      }
      el(app, "study.card").tap()
      waitForLabel(el(app, "study.back"), Self.mockBack)
      assertTwoButtons(app, context: v.name)
      XCTAssertFalse(ring(app).exists, "study.swipeRing shown at rest (\(v.name))")
      shot("study-revealed", v.name)
      app.terminate()
    }
  }

  // MARK: - 019 #5, #6 held drag (24-dot dial + row echo), light + dark + forest

  /// Held drags via `-studySwipePreview " <f>"` / `-studySwipePreviewUp " <f>"` (leading space so a negative value
  /// isn't read as a flag). Spec issues are collected and asserted at the end so every screenshot is still taken.
  @MainActor
  func testRatings_swipeHeldPreview() {
    var issues: [String] = []
    for v in Self.variants {
      XCUIDevice.shared.appearance = v.appearance
      for h in Self.held {
        let ctx = "\(v.name), \(h.state)"
        let app = launch(api: .mock, arguments: [h.arg, " \(h.f)"], theme: v.theme)
        waitForLabel(el(app, "study.front"), Self.mockFront)
        // canRate is false before reveal: the preview must not show a ring yet (011 #8).
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(ring(app).exists, "ring shown before reveal (\(ctx))")
        el(app, "study.reveal").tap()
        waitForLabel(el(app, "study.back"), Self.mockBack)
        let r = ring(app)
        XCTAssertTrue(r.waitFor(timeout: 5), "no ring element while held (\(ctx))")
        if r.identifier != "study.swipeRing" {
          issues.append("ring element identifier is '\(r.identifier)', not 'study.swipeRing' (\(ctx))")
        }
        XCTAssertEqual(r.label, "Rating", "ring label (\(ctx))")
        XCTAssertEqual(r.value as? String, h.grade, "ring value (\(ctx))")
        // Dots around the touch-down point (the card's centre) at radius R + 16 (R = 0.25 w); the ordered lattice
        // (Easy) is a full circle, scattered layouts drift up to 15 % radially (spec 019 #3).
        let card = cardArea(app).frame, radius = card.width * 0.25 + 16
        // The threshold pulse (1 → 1.3 → 1, 0.2 s) can be caught right after the dial appears: let it settle.
        _ = poll(timeout: 2) { r.frame.width <= 2 * radius * 1.15 + 20 }
        if abs(r.frame.midX - card.midX) > 12 || abs(r.frame.midY - card.midY) > 12 {
          issues.append(String(format: "dial centre off the card centre by (%.1f, %.1f) pt (%@)",
                               r.frame.midX - card.midX, r.frame.midY - card.midY, ctx))
        }
        if r.frame.width < 2 * radius * 0.95 || r.frame.width > 2 * radius * 1.15 + 20 {
          issues.append(String(format: "dial frame %.0f wide, expected ~%.0f (%@)", r.frame.width, 2 * radius, ctx))
        }
        // #6: the row echoes the target; ids and positions unchanged.
        let again = el(app, "study.rate.again"), good = el(app, "study.rate.good")
        XCTAssertTrue(again.exists && good.exists, "rating buttons gone while dragging (\(ctx))")
        waitForLabel(again, h.left)
        waitForLabel(good, h.right)
        XCTAssertLessThan(again.frame.maxX, good.frame.minX, "buttons swapped (\(ctx))")
        shot("study-drag-\(h.state)", v.name)
        app.terminate()
      }
    }
    XCTAssertTrue(issues.isEmpty, "spec 019 #3/#5:\n" + Set(issues).sorted().joined(separator: "\n"))
  }

  // MARK: - #2, #6 buttons and drags send the right grade (stub records bodies)

  @MainActor
  func testRatings_buttonsAndDragsSendGrade() throws {
    XCUIDevice.shared.appearance = .light
    let plan: [(action: String, rating: String)] = [
      ("forgot", "again"), ("gotit", "good"), ("+0.13", "good"), ("+0.22", "easy"), ("-0.13", "hard"), ("-0.22", "again"),
    ]
    let cards = plan.indices.map { i in
      StubDeck.Card(id: "0000000\(i)-1111-1111-1111-111111111111", front: "front \(i)", back: "back \(i)",
                    due: Date(timeIntervalSince1970: 1_767_225_600 + Double(i) * 60))
    }
    let (server, _) = try startReviewStub(cards)
    let app = launch(api: .live(server.url))
    for (i, step) in plan.enumerated() {
      waitForLabel(el(app, "study.front"), "front \(i)")
      waitForLabel(el(app, "study.remaining"), "\(plan.count - i) to review")
      XCTAssertTrue(el(app, "study.reveal").exists, "card \(i) not unrevealed")
      XCTAssertFalse(ring(app).exists, "ring on next card \(i)")
      el(app, "study.card").tap()
      waitForLabel(el(app, "study.back"), "back \(i)")
      switch step.action {
      case "forgot": el(app, "study.rate.again").tap()
      case "gotit": el(app, "study.rate.good").tap()
      default: drag(app, Double(step.action)!)
      }
      let post = try waitForPost(server, count: i + 1)
      XCTAssertEqual(post.path, "/cards/\(cards[i].id)/review", "step \(step.action)")
      let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(post.body.utf8)) as? [String: Any],
                               "body \(post.body)")
      XCTAssertEqual(Array(body.keys), ["rating"], "review body must only have `rating`: \(post.body)")
      XCTAssertEqual(body["rating"] as? String, step.rating, "\(step.action) sent \(post.body)")
    }
    waitForLabel(el(app, "study.message"), "No cards yet")  // the review stub deletes reviewed cards: the deck ends empty
    XCTAssertFalse(ring(app).exists)
    server.stop()
  }

  // MARK: - #7 dead zone, #8 unrevealed

  @MainActor
  func testRatings_deadZoneAndUnrevealedSendNothing() throws {
    for appearance in [XCUIDevice.Appearance.light, .dark] {
      XCUIDevice.shared.appearance = appearance
      let (server, _) = try startReviewStub([.init(id: "AAAAAAAA-1111-1111-1111-111111111111", front: "cat", back: "chat")])
      let app = launch(api: .live(server.url))
      waitForLabel(el(app, "study.front"), "cat")
      // #8: sideways drags on the unrevealed card: no review, no reveal, no ring.
      for f in [0.22, -0.22] {
        drag(app, f)
        XCTAssertTrue(el(app, "study.reveal").exists, "drag \(f) on the unrevealed card revealed it")
        XCTAssertFalse(el(app, "study.back").exists, "drag \(f) on the unrevealed card revealed it")
        XCTAssertFalse(ring(app).exists, "ring after drag \(f) on the unrevealed card")
      }
      snapshot("study-unrevealed-after-drag", appearance: appearance)
      // #7: dead-zone release on the revealed card.
      el(app, "study.card").tap()
      waitForLabel(el(app, "study.back"), "chat")
      for f in [0.04, -0.04] {
        drag(app, f)
        Thread.sleep(forTimeInterval: 0.5)
        waitForAbsence(ring(app), "ring still shown after a dead-zone release (\(f))")
        XCTAssertEqual(el(app, "study.back").label, "chat", "card no longer revealed after dead-zone release")
        assertTwoButtons(app, context: "after dead-zone \(f)")
      }
      snapshot("study-swipe-cancelled", appearance: appearance)
      XCTAssertEqual(server.requests.filter { $0.method == "POST" }.count, 0,
                     "dead-zone or unrevealed drag sent a review: \(server.requests.map(\.path))")
      app.terminate()
      server.stop()
    }
  }

  // MARK: - #9 editing

  @MainActor
  func testRatings_dragWhileEditingSendsNothing() throws {
    XCUIDevice.shared.appearance = .light
    let (server, _) = try startReviewStub([.init(id: "BBBBBBBB-1111-1111-1111-111111111111", front: "dog", back: "chien")])
    let app = launch(api: .live(server.url))
    waitForLabel(el(app, "study.front"), "dog")
    el(app, "study.card").tap()
    waitForLabel(el(app, "study.back"), "chien")
    el(app, "study.back").doubleTap()
    XCTAssertTrue(el(app, "study.backField").waitFor(timeout: 3), "double-tap did not open study.backField")
    for f in [0.22, -0.22] {
      drag(app, f)
      XCTAssertFalse(ring(app).exists, "ring shown while editing (\(f))")
    }
    snapshot("study-editing-after-drag", appearance: .light)
    XCTAssertEqual(server.requests.filter { $0.method == "POST" }.count, 0,
                   "drag while editing sent a review: \(server.requests.map { "\($0.method) \($0.path)" })")
    server.stop()
  }

  // MARK: - #10 long card: vertical scroll untouched (pull half dropped by spec 018)

  @MainActor
  func testRatings_longCardScroll() throws {
    continueAfterFailure = true  // report every long-card gesture, not only the first failing one
    XCUIDevice.shared.appearance = .light
    let back = "a long answer written on purpose to need scrolling at large text sizes: it goes on about the "
      + "menu and the map, the card and the deck, the word and its meaning, the front and the back, the question "
      + "and the answer, the day and the night, until at last, after all of that, it finally ends here: the end"
    let (server, _) = try startReviewStub([.init(id: "CCCCCCCC-1111-1111-1111-111111111111", front: "long", back: back)])
    let app = launch(api: .live(server.url), arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])  // long enough to scroll
    waitForLabel(el(app, "study.front"), "long")
    el(app, "study.card").tap()
    waitForLabel(el(app, "study.back"), back)
    let before = el(app, "study.back").frame
    el(app, "study.card").swipeUp()
    Thread.sleep(forTimeInterval: 0.5)
    let after = el(app, "study.back").frame
    XCTAssertGreaterThan(before.maxY, cardArea(app).frame.maxY + 1, "fixture doesn't overflow: nothing to scroll")
    XCTAssertLessThan(after.minY, before.minY - 5, "vertical drag did not scroll the back: \(before) → \(after)")
    XCTAssertLessThanOrEqual(after.maxY, cardArea(app).frame.maxY + 1, "end of the back not scrolled into view: \(after)")
    XCTAssertFalse(ring(app).exists, "ring after a vertical scroll")
    snapshot("study-long-scrolled", appearance: .light)
    XCTAssertEqual(server.requests.filter { $0.method == "POST" }.count, 0, "scroll sent a review")
    // 019 #2: at the end of the scroll, a vertical drag up is still the scroll view's (bounce), not a rating.
    let start = el(app, "study.card").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
    start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -250)), withVelocity: .slow,
                thenHoldForDuration: 0.1)
    Thread.sleep(forTimeInterval: 1)
    XCTAssertEqual(server.requests.filter { $0.method == "POST" }.count, 0,
                   "vertical drag up at the end of a long card sent a review: \(server.requests.last?.body ?? "")")
    // 019 #8: a near-vertical drag (dx = 0.3 |dy|, within 30°) still scrolls (back down) and doesn't rate.
    let mid = el(app, "study.back").frame
    drag(app, dx: 0.09, dy: 0.3)
    Thread.sleep(forTimeInterval: 0.8)
    XCTAssertGreaterThan(el(app, "study.back").frame.minY, mid.minY + 5, "near-vertical drag did not scroll")
    XCTAssertFalse(ring(app).exists, "ring after a near-vertical drag")
    XCTAssertEqual(server.requests.filter { $0.method == "POST" }.count, 0, "near-vertical drag sent a review")
    // A 45° up-right drag rates (projection 0.2 w · √2 ≈ 0.28 w → easy) without scrolling first.
    drag(app, dx: 0.2, dy: -0.2, hold: 0.4)
    let post = try waitForPost(server, count: 1)
    let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(post.body.utf8)) as? [String: Any])
    XCTAssertEqual(body["rating"] as? String, "easy", "45° drag on the long card sent \(post.body)")
    server.stop()
  }

  // MARK: - 019 #7 real drags on a fitting card: up, down, up-left

  /// Fitting card: a vertical drag starts the rating pan (no scroll view in the way). Up 0.22 w → easy,
  /// down 0.22 w → again, up-left (projection ~0) → nothing, card stays revealed and the row returns to rest.
  @MainActor
  func testRatings_realDragsAnyDirection() throws {
    XCUIDevice.shared.appearance = .light
    let plan: [(name: String, dx: Double, dy: Double, rating: String?)] = [
      ("up", 0, -0.22, "easy"), ("down", 0, 0.22, "again"), ("upleft", -0.2, -0.2, nil),
      ("upright", 0.1, -0.1, "good"), ("left", -0.22, 0, "again"),
    ]
    let cards = plan.indices.map { i in
      StubDeck.Card(id: "EEEEEEE\(i)-1111-1111-1111-111111111111", front: "front \(i)", back: "back \(i)",
                    due: Date(timeIntervalSince1970: 1_767_225_600 + Double(i) * 60))
    }
    let (server, _) = try startReviewStub(cards)
    let app = launch(api: .live(server.url))
    var posts = 0, i = 0
    for step in plan {
      waitForLabel(el(app, "study.front"), "front \(i)")
      if el(app, "study.reveal").exists { el(app, "study.card").tap() }
      waitForLabel(el(app, "study.back"), "back \(i)")
      drag(app, dx: step.dx, dy: step.dy)
      if let rating = step.rating {
        posts += 1
        let post = try waitForPost(server, count: posts)
        XCTAssertEqual(post.path, "/cards/\(cards[i].id)/review", "drag \(step.name)")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(post.body.utf8)) as? [String: Any])
        XCTAssertEqual(body["rating"] as? String, rating, "drag \(step.name) sent \(post.body)")
        i += 1
      } else {
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(server.requests.filter { $0.method == "POST" }.count, posts, "drag \(step.name) sent a review")
        XCTAssertEqual(el(app, "study.back").label, "back \(i)", "card not revealed after drag \(step.name)")
        waitForAbsence(ring(app), "dial still shown after drag \(step.name)")
        assertTwoButtons(app, context: "after drag \(step.name)")
        snapshot("study-drag-cancelled-\(step.name)", appearance: .light)
      }
    }
    server.stop()
  }

  // MARK: - #11 tap / double-tap regression

  @MainActor
  func testRatings_tapAndDoubleTapUnchanged() {
    for appearance in [XCUIDevice.Appearance.light, .dark] {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .mock)
      waitForLabel(el(app, "study.front"), Self.mockFront)
      el(app, "study.card").tap()
      waitForLabel(el(app, "study.back"), Self.mockBack)
      XCTAssertFalse(ring(app).exists, "ring after tap-to-reveal")
      el(app, "study.back").doubleTap()
      XCTAssertTrue(el(app, "study.backField").waitFor(timeout: 3), "double-tap no longer opens study.backField")
      XCTAssertFalse(ring(app).exists, "ring after double-tap")
      snapshot("study-doubletap-edit", appearance: appearance)
      app.terminate()
    }
  }

  // MARK: - #12 drag → review fails → retry

  @MainActor
  func testRatings_dragReviewFailureThenRetry() throws {
    XCUIDevice.shared.appearance = .light
    let card = StubJSON.card(id: "DDDDDDDD-1111-1111-1111-111111111111", front: "owl", back: "hibou")
    let server = StubAPIServer { request in
      if request.method == "POST" { return .init(status: 500, body: #"{"detail":"boom"}"#) }
      if request.path.hasPrefix("/cards/due") { return .init(body: StubJSON.cards([card])) }
      return .init(status: 404, body: "{}")
    }
    try server.start()
    let app = launch(api: .live(server.url))
    waitForLabel(el(app, "study.front"), "owl")
    el(app, "study.card").tap()
    waitForLabel(el(app, "study.back"), "hibou")
    drag(app, 0.13)
    waitForLabel(el(app, "study.message"), "Can't reach your deck", timeout: 20)
    XCTAssertFalse(ring(app).exists, "ring on the offline screen")
    snapshot("study-swipe-review-failed", appearance: .light)
    el(app, "study.retry").tap()
    waitForLabel(el(app, "study.front"), "owl")
    waitForLabel(el(app, "study.back"), "hibou")
    XCTAssertFalse(el(app, "study.reveal").exists, "retried card came back unrevealed")
    assertTwoButtons(app, context: "after retry")
    XCTAssertFalse(ring(app).exists, "ring after retry")
    snapshot("study-swipe-review-retried", appearance: .light)
    server.stop()
  }

  // Dynamic Type accessibility-size tests: deferred until before publishing (user rule).

  // MARK: - Helpers

  /// The ring: by its identifier, or by its accessibility label "Rating" (on this build its identifier is
  /// overridden by the card's `study.card`, so absence checks by identifier alone would pass vacuously).
  @MainActor
  private func ring(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier == 'study.swipeRing' OR label == 'Rating'")).firstMatch
  }

  /// The card's scroll view (`study.card`), not the ring that currently also carries that identifier.
  @MainActor
  private func cardArea(_ app: XCUIApplication) -> XCUIElement {
    app.scrollViews.matching(identifier: "study.card").firstMatch
  }

  /// Spec's drag: press at the card's center, move to `0.5 + f` of its width, release.
  @MainActor
  private func drag(_ app: XCUIApplication, _ f: Double) {
    let card = el(app, "study.card")
    card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .press(forDuration: 0.05, thenDragTo: card.coordinate(withNormalizedOffset: CGVector(dx: 0.5 + f, dy: 0.5)))
  }

  /// Real drag from the card's centre by `(dx, dy)` card widths (y down), then release.
  @MainActor
  private func drag(_ app: XCUIApplication, dx: Double, dy: Double, hold: TimeInterval = 0) {
    let card = el(app, "study.card"), w = card.frame.width
    let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let end = start.withOffset(CGVector(dx: dx * w, dy: dy * w))
    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: hold)
  }

  @MainActor
  private func assertTwoButtons(_ app: XCUIApplication, context: String, checkLeftRight: Bool = true,
                                file: StaticString = #filePath, line: UInt = #line) {
    let again = el(app, "study.rate.again"), good = el(app, "study.rate.good")
    XCTAssertTrue(again.waitFor(timeout: 3), "study.rate.again missing (\(context))", file: file, line: line)
    XCTAssertTrue(good.waitFor(timeout: 3), "study.rate.good missing (\(context))", file: file, line: line)
    XCTAssertEqual(again.label, "Forgot", file: file, line: line)
    XCTAssertEqual(good.label, "Got it", file: file, line: line)
    XCTAssertTrue(again.isEnabled && good.isEnabled, "rating buttons disabled (\(context))", file: file, line: line)
    XCTAssertTrue(again.isHittable && good.isHittable, "rating buttons not hittable (\(context))", file: file, line: line)
    XCTAssertFalse(el(app, "study.rate.hard").exists, "study.rate.hard exists (\(context))", file: file, line: line)
    XCTAssertFalse(el(app, "study.rate.easy").exists, "study.rate.easy exists (\(context))", file: file, line: line)
    if checkLeftRight {
      XCTAssertLessThan(again.frame.maxX, good.frame.minX, "Forgot not left of Got it (\(context))", file: file, line: line)
      XCTAssertEqual(again.frame.midY, good.frame.midY, accuracy: 1, "buttons not on one row (\(context))",
                     file: file, line: line)
    }
  }

  /// Screenshot named `<name>-<variant>` (variant: light, dark, forest).
  @MainActor
  private func shot(_ name: String, _ variant: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "\(name)-\(variant)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// StubDeck plus `POST /cards/{id}/review`: the reviewed card leaves the due list.
  private func startReviewStub(_ cards: [StubDeck.Card]) throws -> (StubAPIServer, StubDeck) {
    let deck = StubDeck(cards)
    let server = StubAPIServer { request in
      let route = StubDeck.route(request.path)
      if request.method == "POST", route.hasSuffix("/review") {
        let id = String(route.dropFirst("/cards/".count).dropLast("/review".count))
        guard let card = deck.cards.first(where: { $0.id.lowercased() == id.lowercased() }) else {
          return .init(status: 404, body: "{}")
        }
        deck.remove(id: id)
        return .init(body: StubDeck.json(card))
      }
      return deck.handle(request)
    }
    try server.start()
    return (server, deck)
  }

  private func waitForPost(_ server: StubAPIServer, count: Int, timeout: TimeInterval = 5) throws -> StubAPIServer.Request {
    let deadline = Date().addingTimeInterval(timeout)
    while server.requests.filter({ $0.method == "POST" }).count < count, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.1)
    }
    let posts = server.requests.filter { $0.method == "POST" }
    XCTAssertEqual(posts.count, count, "expected \(count) review POSTs, got \(posts.map(\.path))")
    return try XCTUnwrap(posts.last)
  }
}
