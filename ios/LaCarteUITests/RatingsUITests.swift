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
  /// AX-XL text and a pinned English-only language list: iOS raises the line height when the preferred languages
  /// include tall scripts (th, vi, ar…), which a simulator's default list does and CI's doesn't, so the long card
  /// overflowed locally and fitted on CI.
  static let longCardArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL",
                                  "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
  /// Overflows the card by ~5 lines at AX-XL with the pinned English line height (`longCardArguments`).
  static let longBack = "a long answer written on purpose to need scrolling at large text sizes: it goes on about the "
    + "menu and the map, the card and the deck, the word and its meaning, the front and the back, the question "
    + "and the answer, the day and the night, the sea and the shore, the road and the town, the rain and the sun, "
    + "until at last, after all of that, it finally ends here: the end"
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
        _ = poll(timeout: 2) { r.frame.width <= 2 * radius * 1.3 + 20 }
        if abs(r.frame.midX - card.midX) > 12 || abs(r.frame.midY - card.midY) > 12 {
          issues.append(String(format: "dial centre off the card centre by (%.1f, %.1f) pt (%@)",
                               r.frame.midX - card.midX, r.frame.midY - card.midY, ctx))
        }
        // The element's frame has room for the pulse (1.3×) and the release growth; the drawn dots are measured
        // on the screenshots (screen-sample dots).
        if r.frame.width < 2 * radius * 0.95 || r.frame.width > 2 * radius * 1.3 + 20 {
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
    let back = Self.longBack
    let (server, _) = try startReviewStub([.init(id: "CCCCCCCC-1111-1111-1111-111111111111", front: "long", back: back)])
    let app = launch(api: .live(server.url), arguments: Self.longCardArguments)
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

  // MARK: - 019 #8 angle sweep on a long (scrolling) card

  /// Long card at AX-XL text (it scrolls): a first movement within 30° of vertical (|dx| < 0.58 |dy|) is the scroll
  /// view's (no dial, no review); anything else is a rating drag in every direction. Vectors in card widths, y down.
  @MainActor
  func testRatings_longCardAngleSweep() throws {
    continueAfterFailure = true  // report every angle, not only the first failing one
    XCUIDevice.shared.appearance = .light
    let back = Self.longBack
    let plan: [(name: String, dx: Double, dy: Double, rating: String?)] = [
      ("near-vertical-up", 0.09, -0.3, nil),     // 17° from vertical: scrolls
      ("near-vertical-down", -0.09, 0.3, nil),   // 17° from vertical: scrolls back
      ("30deg", 0.3, -0.17, "easy"),             // 30° above horizontal
      ("40deg", 0.25, -0.21, "easy"),
      ("45deg", 0.2, -0.2, "easy"),
      ("45deg-slow", 0.12, -0.12, "good"),       // projection 0.17 w → good
      ("50deg", 0.2, -0.24, "easy"),
      ("55deg", 0.17, -0.24, "easy"),            // 35° from vertical: still a rating
      ("45deg-downleft", -0.2, 0.2, "again"),
    ]
    let cards = plan.indices.map { i in
      StubDeck.Card(id: "CCCCCCC\(i)-1111-1111-1111-111111111111", front: "long \(i)", back: back,
                    due: Date(timeIntervalSince1970: 1_767_225_600 + Double(i) * 60))
    }
    let (server, _) = try startReviewStub(cards)
    let app = launch(api: .live(server.url), arguments: Self.longCardArguments)
    var posts = 0, i = 0
    var results: [String] = []
    for step in plan {
      waitForLabel(el(app, "study.front"), "long \(i)")
      if el(app, "study.reveal").exists { el(app, "study.card").tap() }
      waitForLabel(el(app, "study.back"), back)
      XCTAssertGreaterThan(el(app, "study.back").frame.maxY, cardArea(app).frame.maxY - 40, "long card doesn't scroll")
      let before = el(app, "study.back").frame
      drag(app, dx: step.dx, dy: step.dy, hold: 0.4)
      let ringShown = ring(app).exists  // still held: the dial must be up for a rating drag
      if let rating = step.rating {
        posts += 1
        let deadline = Date().addingTimeInterval(4)
        while server.requests.filter({ $0.method == "POST" }).count < posts, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        let got = server.requests.filter { $0.method == "POST" }
        let sent = got.count >= posts ? ((try? JSONSerialization.jsonObject(with: Data(got[posts - 1].body.utf8))) as? [String: Any])?["rating"] as? String : nil
        results.append("\(step.name): dial \(ringShown), sent \(sent ?? "nothing")")
        XCTAssertEqual(sent, rating, "\(step.name) (\(step.dx), \(step.dy)) on the long card")
        if sent == nil { posts -= 1 } else { i += 1 }
      } else {
        Thread.sleep(forTimeInterval: 0.8)
        let moved = el(app, "study.back").frame.minY - before.minY
        results.append(String(format: "%@: dial %@, scrolled %.0f pt", step.name, ringShown ? "true" : "false", moved))
        XCTAssertFalse(ringShown, "\(step.name): dial during a near-vertical drag")
        XCTAssertGreaterThan(abs(moved), 5, "\(step.name): near-vertical drag did not scroll")
        XCTAssertEqual(server.requests.filter { $0.method == "POST" }.count, posts, "\(step.name) sent a review")
      }
      if step.name == "45deg" { snapshot("study-long-45deg-rated", appearance: .light) }
    }
    print("019 #8 sweep:\n" + results.joined(separator: "\n"))
    server.stop()
  }

  // MARK: - 019 §6 / #11 release reward: never delays the next card, a new drag still works

  /// Got it / Easy releases on fitting cards: the next card's front is on screen right away (the reward is an
  /// overlay), the dial is hidden from accessibility during the reward, and the next card rates normally.
  /// Timing is read from the recording (image-ops track); here the test checks order and outcome.
  @MainActor
  func testRatings_releaseRewardNextCardImmediate() throws {
    continueAfterFailure = true
    XCUIDevice.shared.appearance = .light
    let plan: [(dx: Double, dy: Double, rating: String)] = [
      (0, -0.13, "good"), (0, -0.22, "easy"), (0, 0.22, "again"), (0.22, 0, "easy"),
    ]
    let cards = plan.indices.map { i in
      StubDeck.Card(id: "DDDDDDD\(i)-1111-1111-1111-111111111111", front: "front \(i)", back: "back \(i)",
                    due: Date(timeIntervalSince1970: 1_767_225_600 + Double(i) * 60))
    }
    let (server, _) = try startReviewStub(cards)
    let app = launch(api: .live(server.url))
    for (i, step) in plan.enumerated() {
      waitForLabel(el(app, "study.front"), "front \(i)")
      el(app, "study.card").tap()
      waitForLabel(el(app, "study.back"), "back \(i)")
      let released = Date()
      drag(app, dx: step.dx, dy: step.dy)
      print(String(format: "019 reward: release %d (%@) at +%.2f s", i, step.rating, Date().timeIntervalSince(released)))
      if i == 0 || i == 1 { snapshot("study-release-\(step.rating)-overlay", appearance: .light) }
      // The reward overlay is hidden from accessibility: no "Rating" element once the finger is up.
      var seen: [String] = []
      let until = Date().addingTimeInterval(1.2)
      while Date() < until {
        let r = ring(app)
        if r.exists {
          seen.append(String(format: "+%.2f s id '%@' label '%@' value '%@' frame %@", Date().timeIntervalSince(released),
                             r.identifier, r.label, (r.value as? String) ?? "-", NSCoder.string(for: r.frame)))
        }
        Thread.sleep(forTimeInterval: 0.05)
      }
      XCTAssertTrue(seen.isEmpty, "dial in the accessibility tree after a \(step.rating) release:\n" + seen.joined(separator: "\n"))
      let post = try waitForPost(server, count: i + 1)
      let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(post.body.utf8)) as? [String: Any])
      XCTAssertEqual(body["rating"] as? String, step.rating, "release \(i)")
      if i + 1 < plan.count {
        XCTAssertTrue(poll(timeout: 1) { el(app, "study.front").label == "front \(i + 1)" },
                      "next card not shown within 1 s of a \(step.rating) release")
        print(String(format: "019 reward: next card %d seen at +%.2f s", i + 1, Date().timeIntervalSince(released)))
      }
    }
    server.stop()
  }

  /// 019 §6: a Got it / Easy release must not delay the next card. Alternates Got it and Easy drags and times, from
  /// the end of the drag call, how long until `study.front` shows the next card; Easy (0.6 s reward) must not be
  /// slower than Got it (0.5 s) or than a Forgot release (no reward). The last step drags again right after an Easy
  /// release (reveal + drag while the reward may still play): it must rate normally.
  @MainActor
  func testRatings_releaseTiming() throws {
    continueAfterFailure = true
    XCUIDevice.shared.appearance = .light
    let plan: [(dx: Double, dy: Double, rating: String)] = [
      (0, -0.13, "good"), (0, -0.22, "easy"), (0, 0.22, "again"), (0, -0.13, "good"), (0, -0.22, "easy"),
      (0, 0.22, "again"), (0, -0.13, "good"), (0, -0.22, "easy"), (0, 0.22, "again"),
    ]
    let cards = plan.indices.map { i in
      StubDeck.Card(id: "FFFFFFF\(i)-1111-1111-1111-111111111111", front: "front \(i)", back: "back \(i)",
                    due: Date(timeIntervalSince1970: 1_767_225_600 + Double(i) * 60))
    }
    let (server, _) = try startReviewStub(cards)
    let app = launch(api: .live(server.url))
    var lines: [String] = [], delays: [String: [Double]] = [:], lastRelease = Date()
    for (i, step) in plan.enumerated() {
      waitForLabel(el(app, "study.front"), "front \(i)")
      el(app, "study.card").tap()
      waitForLabel(el(app, "study.back"), "back \(i)")
      let start = Date()
      drag(app, dx: step.dx, dy: step.dy)
      let returned = Date().timeIntervalSince(start)
      let sincePrevious = i == 0 ? 0 : start.timeIntervalSince(lastRelease)  // previous release → this drag's start
      lastRelease = Date()
      var next = -1.0
      if i + 1 < plan.count {
        let front = el(app, "study.front")
        if poll(timeout: 3, { front.label == "front \(i + 1)" }) { next = Date().timeIntervalSince(start) - returned }
        delays[step.rating, default: []].append(next)
      }
      lines.append(String(format: "%d %@: drag starts %.2f s after the previous release · drag call %.2f s · next card seen +%.2f s after",
                          i, step.rating, sincePrevious, returned, next))
    }
    _ = try waitForPost(server, count: plan.count)
    let bodies = server.requests.filter { $0.method == "POST" }.map(\.body)
    for (i, step) in plan.enumerated() where i < bodies.count {
      XCTAssertTrue(bodies[i].contains("\"\(step.rating)\""), "release \(i) sent \(bodies[i]), expected \(step.rating)")
    }
    let avg = { (k: String) in (delays[k] ?? []).reduce(0, +) / Double(max(1, (delays[k] ?? []).count)) }
    lines.append(String(format: "mean next-card delay: good %.2f · easy %.2f · again %.2f s", avg("good"), avg("easy"), avg("again")))
    let report = XCTAttachment(string: lines.joined(separator: "\n"))
    report.name = "release-timing"
    report.lifetime = .keepAlways
    add(report)
    XCTAssertLessThan(avg("easy"), avg("again") + 0.15, "Easy release delays the next card:\n" + lines.joined(separator: "\n"))
    XCTAssertLessThan(avg("good"), avg("again") + 0.15, "Got it release delays the next card:\n" + lines.joined(separator: "\n"))
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
