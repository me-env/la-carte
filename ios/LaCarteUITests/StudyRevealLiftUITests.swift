import XCTest

/// Spec 017 "Reveal lift" + AC 14 (amends AC 9 and 13). A basic card's question that would sit more than 40 pt
/// (`Theme.Spacing.xl`) above the card's centre before reveal starts centred in `study.card` and rises on reveal to
/// its place in the centred pair (or the top, when the pair overflows). Up to 40 pt nothing moves.
/// `lift = (pairHeight − questionHeight) / 2` when the pair fits; `(cardHeight − questionHeight) / 2` when it overflows;
/// 0 when the question alone overflows. Light + dark, a stub deck (fresh per appearance).
/// Reduce Motion: XCUITest can't switch it on for the app (LogoUITests note); covered by the render test
/// `ScreenColorTests.questionStaysPut` (QA report).
final class StudyRevealLiftUITests: XCTestCase {
  static let fourLines = "A large body of salt water that covers much of the earth's surface, smaller than an ocean "
    + "and often partly enclosed by land, like the Mediterranean."
  static let twoLines = "A large body of salt water, smaller than an ocean."
  static let eightLines = "A large body of salt water that covers much of the earth's surface. It is smaller than an "
    + "ocean and often partly enclosed by land, like the Mediterranean, the Baltic or the Caribbean. Seas are home "
    + "to coral reefs, kelp forests and countless fish, and they shape the climate of the coasts around them, "
    + "warming winters and cooling summers."
  static let mediumQuestion = "Which sea lies between Europe and Africa and connects to the Atlantic Ocean through "
    + "the narrow Strait of Gibraltar, west of Italy and Greece?"
  static let overflowingAnswer = String(repeating: "The Mediterranean is almost enclosed by land: Europe to the north, "
    + "Africa to the south and Asia to the east. ", count: 14).trimmingCharacters(in: .whitespaces)
  static let overflowingQuestion = String(repeating: "Spaced repetition schedules each review just before you would "
    + "forget. ", count: 14).trimmingCharacters(in: .whitespaces)

  struct Case { let name: String; let front: String; let back: String }
  static let cases: [Case] = [
    .init(name: "q1a4", front: "la mer", back: fourLines),
    .init(name: "q1a2", front: "la mer", back: twoLines),
    .init(name: "q1a8", front: "la mer", back: eightLines),
    .init(name: "qAloneOverflows", front: overflowingQuestion, back: "the end"),
    .init(name: "pairOverflows", front: mediumQuestion, back: overflowingAnswer),
  ]

  override func setUp() {
    continueAfterFailure = true
  }

  @MainActor func testStudyRevealLift_light() throws { try run(.light) }
  @MainActor func testStudyRevealLift_dark() throws { try run(.dark) }

  @MainActor
  private func run(_ appearance: XCUIDevice.Appearance) throws {
    XCUIDevice.shared.appearance = appearance
    let base = Date(timeIntervalSince1970: 1_767_225_600)
    let stub = Self.cases.enumerated().map { i, c in
      StubDeck.Card(id: "F17F17F\(i)-0000-0000-0000-00000000000\(i)", front: c.front, back: c.back,
                    due: base.addingTimeInterval(Double(i) * 60), createdAt: base.addingTimeInterval(Double(i) * 60))
    }
    let deck = StubDeck(stub)
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
    defer { server.stop() }
    let app = launch(api: .live(server.url))
    let card = el(app, "study.card"), front = el(app, "study.front"), back = el(app, "study.back")
    var topOfContent: CGFloat?
    let mode = appearance == .dark ? "dark" : "light"

    for (i, c) in Self.cases.enumerated() {
      waitForLabel(front, c.front)
      Thread.sleep(forTimeInterval: 0.8)  // fade-in and measurements settled
      let box = card.frame, q = front.frame
      let inkBefore = inkRows(ColorProbe(screenOf: app), x: q.minX...q.maxX, y: box.minY...box.maxY)
      note("QA017L \(mode) \(c.name) card \(box) front \(q) ink \(inkBefore)")
      snapshot("study-lift-\(c.name)-front", appearance: appearance)

      if c.name == "q1a4", appearance == .light {
        // A frame sequence of one lift (critically damped: the question only rises, never overshoots).
        let frames = captureFrames(during: 0.9) { el(app, "study.reveal").tap() }
        for (n, f) in frames.enumerated() where n % 2 == 0 {
          let a = XCTAttachment(data: f.png, uniformTypeIdentifier: "public.png")
          a.name = String(format: "study-lift-q1a4-frame-%02d-%04dms-light", n, Int(f.t * 1000))
          a.lifetime = .keepAlways
          add(a)
        }
        waitForLabel(back, c.back)
        Thread.sleep(forTimeInterval: 0.6)
      } else {
        reveal(app, c.back)
      }
      let qa = front.frame, a = back.frame
      let inkAfter = inkRows(ColorProbe(screenOf: app), x: q.minX...q.maxX, y: qa.minY - 2...qa.maxY + 2)
      note("QA017L \(mode) \(c.name) after: front \(qa) back \(a) ink \(inkAfter)")
      snapshot("study-lift-\(c.name)-back", appearance: appearance)

      // Horizontal place and size never change.
      XCTAssertEqual(qa.minX, q.minX, accuracy: 0.5, "\(c.name): question moved sideways \(q) → \(qa)")
      XCTAssertEqual(qa.width, q.width, accuracy: 0.5, "\(c.name): question resized \(q) → \(qa)")
      XCTAssertEqual(qa.height, q.height, accuracy: 0.5, "\(c.name): question resized \(q) → \(qa)")
      let pair = a.maxY - qa.minY, moved = q.minY - qa.minY
      let pairFits = pair <= box.height + 0.5
      if c.name == "pairOverflows" { XCTAssertFalse(pairFits, "fixture: the pair should overflow the card (pair \(pair))") }
      let expected = q.height >= box.height ? 0 : (pairFits ? (pair - q.height) / 2 : (box.height - q.height) / 2)
      note("QA017L \(mode) \(c.name): pair \(pair) fits \(pairFits) expected lift \(expected) moved \(moved)")

      switch c.name {
      case "q1a2":
        XCTAssertLessThanOrEqual(expected, 40, "fixture: 2-line answer should give lift ≤ 40, got \(expected)")
        XCTAssertEqual(qa, q, "\(c.name): lift ≤ 40 pt but the question moved \(q) → \(qa)")
      case "qAloneOverflows":
        XCTAssertGreaterThan(q.height, box.height, "fixture: the question alone should overflow the card")
        XCTAssertEqual(qa, q, "\(c.name): the question alone overflows (lift 0) but it moved \(q) → \(qa)")
        topOfContent = q.minY
      default:
        XCTAssertGreaterThan(expected, 40, "fixture \(c.name): expected a lift > 40, got \(expected)")
        // Before reveal: centred in study.card (± 1 pt).
        XCTAssertEqual(q.midY, box.midY, accuracy: 1, "\(c.name): question not centred before reveal \(q) in \(box)")
        // After reveal: today's place (the pair centred, or the top when it overflows), reached by the lift.
        XCTAssertEqual(moved, expected, accuracy: 1, "\(c.name): lifted \(moved) pt, expected \(expected)")
        if pairFits {
          XCTAssertEqual((qa.minY + a.maxY) / 2, box.midY, accuracy: 1, "\(c.name): revealed pair not centred")
        } else {
          let top = try XCTUnwrap(topOfContent, "qAloneOverflows runs first and gives the content's top")
          XCTAssertEqual(qa.minY, top, accuracy: 0.5, "\(c.name): overflowing pair doesn't end at the top (no scroll)")
          XCTAssertGreaterThan(a.maxY, box.maxY, "fixture: the pair should overflow the card")
        }
        // The ink moves with the frame (the offset is drawn, not just reported).
        if let b = inkBefore, let f = inkAfter {
          XCTAssertEqual(b.lowerBound - f.lowerBound, moved, accuracy: 1, "\(c.name): ink moved \(b) → \(f), frame \(moved)")
        }
      }
      if c.name == "pairOverflows" {  // the end of the answer still scrolls into view
        let rateTop = el(app, "study.rate.good").frame.minY
        for _ in 0..<6 where back.frame.maxY > rateTop - 1 { dragUp(app) }
        XCTAssertLessThanOrEqual(back.frame.maxY, rateTop, "end of the overflowing answer not reachable: \(back.frame)")
        snapshot("study-lift-pairOverflows-scrolled", appearance: appearance)
      }
      if i + 1 < Self.cases.count {
        el(app, "study.rate.good").tap()
      }
    }
  }

  // MARK: - Helpers

  /// First and last rows (pt, 1/3 pt steps) in the rect with ink, far from the card's background (sampled at
  /// the left edge of the screen, level with the rect's top).
  private func inkRows(_ probe: ColorProbe, x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) -> ClosedRange<CGFloat>? {
    let bg = probe.color(at: CGPoint(x: 4, y: y.lowerBound))
    var first: CGFloat?, last: CGFloat?
    for row in stride(from: y.lowerBound, through: y.upperBound, by: 1.0 / 3) {
      let hit = stride(from: x.lowerBound, through: x.upperBound, by: 1.0 / 3)
        .contains { probe.color(at: CGPoint(x: $0, y: row)).distance(to: bg) > 60 }
      if hit { first = first ?? row; last = row }
    }
    guard let first, let last else { return nil }
    return first...last
  }

  private func note(_ line: String) {
    print(line)
    XCTContext.runActivity(named: line) { _ in }
  }

  @MainActor
  private func reveal(_ app: XCUIApplication, _ back: String) {
    el(app, "study.reveal").tap()
    waitForLabel(el(app, "study.back"), back)
    XCTAssertTrue(el(app, "study.rate.good").waitFor(timeout: 3), "ratings missing")
    Thread.sleep(forTimeInterval: 0.6)  // lift (0.35 s) and fade settled
  }

  @MainActor
  private func dragUp(_ app: XCUIApplication) {
    let window = app.windows.firstMatch
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
      .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)),
             withVelocity: .slow, thenHoldForDuration: 0.1)
    Thread.sleep(forTimeInterval: 0.6)
  }

  /// Screenshots taken off the main thread as fast as possible for `duration` s, starting just before `action`.
  @MainActor
  private func captureFrames(during duration: TimeInterval, _ action: () -> Void) -> [(t: TimeInterval, png: Data)] {
    let box = LiftFrameBox()
    let start = Date()
    let thread = Thread {
      while Date().timeIntervalSince(start) < duration {
        if let png = screenshotPNGOffMain() { box.append((Date().timeIntervalSince(start), png)) }
      }
      box.finish()
    }
    thread.start()
    Thread.sleep(forTimeInterval: 0.1)
    action()
    let deadline = Date().addingTimeInterval(duration + 10)
    while !box.isDone, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    return box.frames
  }
}

private final class LiftFrameBox: @unchecked Sendable {
  private let lock = NSLock()
  private var _frames: [(t: TimeInterval, png: Data)] = []
  private var done = false
  nonisolated func append(_ f: (TimeInterval, Data)) { lock.withLock { _frames.append((t: f.0, png: f.1)) } }
  nonisolated func finish() { lock.withLock { done = true } }
  nonisolated var isDone: Bool { lock.withLock { done } }
  nonisolated var frames: [(t: TimeInterval, png: Data)] { lock.withLock { _frames } }
}
