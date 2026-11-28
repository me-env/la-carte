import XCTest

/// Spec 017 #15 "Answer alignment" (amends #6, #7, #13; 2026-11-28). Basic cards, revealed, layout D, light + dark:
/// the answer's alignment depends only on its own rendered lines (1–2 lines centred in the column, 3+ leading).
/// (a) Westphalia question (3+ lines, leading) + "The Peace of Westphalia" (1 line, mock-lengths): centred.
/// (b) Same question + a 2-line answer (stub): centred, each line centred.
/// (c) Same question + a 3+-line answer (stub): leading at the question's left edge, within its width (+6 pt).
/// (d) "mitochondria" (1 line, centred) + its 3+-line answer (mock-lengths): leading at the column's edge.
/// (e) Every case: the question's frame (and, when the lift is ≤ 40 pt, its pixels) is unchanged by the reveal (#13, #14).
/// (f) Person cards: `NotesUITests.testNotesStudy_personTextLayout` (014d), run alongside.
final class StudyAnswerAlignUITests: XCTestCase {
  static let westphalia = "Which treaty, signed in 1648, ended the Thirty Years' War and is often cited as the origin of "
    + "the modern state system?"
  static let oneLine = "The Peace of Westphalia"
  static let twoLines = "The Peace of Westphalia, signed in Osnabrück and Münster in 1648"
  static let threeLines = "The Peace of Westphalia: treaties signed in Osnabrück and Münster in 1648, which ended "
    + "the Thirty Years' War and the Eighty Years' War."

  override func setUp() {
    continueAfterFailure = true
  }

  @MainActor func testStudyAnswerAlign_light() throws { try run(.light) }
  @MainActor func testStudyAnswerAlign_dark() throws { try run(.dark) }

  @MainActor
  private func run(_ appearance: XCUIDevice.Appearance) throws {
    XCUIDevice.shared.appearance = appearance
    let mode = appearance == .dark ? "dark" : "light"

    // (a) and (d): mock-lengths (la mer → Westphalia → mitochondria).
    let app = launch(api: .mockLengths)
    var card = el(app, "study.card"), front = el(app, "study.front"), back = el(app, "study.back")
    waitForLabel(front, "la mer")
    el(app, "study.reveal").tap()
    waitForLabel(back, "the sea")
    Thread.sleep(forTimeInterval: 0.4)
    rateGood(app, next: Self.westphalia)

    var (q, a) = revealChecked(app, Self.oneLine, "a", mode)
    let oneLineHeight = a.height
    note("QA017-15 \(mode) a: card \(card.frame) front \(q) back \(a)")
    XCTAssertEqual(a.midX, card.frame.midX, accuracy: 1, "(a) 1-line answer not centred in study.card: \(a) in \(card.frame)")
    XCTAssertGreaterThan(a.minX, q.minX + 10, "(a) 1-line answer starts at the question's left edge: \(a) vs \(q)")
    assertLinesCentred(app, a, card.frame, lines: 1, "(a)")
    snapshot("study-answer-align-a-1line-back", appearance: appearance)
    rateGood(app, next: "mitochondria")

    (q, a) = revealChecked(app, nil, "d", mode)
    note("QA017-15 \(mode) d: card \(card.frame) front \(q) back \(a)")
    XCTAssertEqual(q.midX, card.frame.midX, accuracy: 1, "(d) 1-line question not centred: \(q)")
    XCTAssertGreaterThan(a.height, oneLineHeight * 2.5, "(d) fixture: answer not 3+ lines \(a) (one line = \(oneLineHeight))")
    XCTAssertEqual(a.minX, card.frame.minX, accuracy: 1, "(d) 3+-line answer not leading at the column's edge: \(a) in \(card.frame)")
    XCTAssertGreaterThan(a.width, q.width + 50, "(d) answer held to the question's width: \(a) vs \(q)")
    snapshot("study-answer-align-d-shortq-3lines-back", appearance: appearance)
    app.terminate()

    // (b) and (c): stub deck, the same question with a 2-line then a 3+-line answer.
    let base = Date(timeIntervalSince1970: 1_767_225_600)
    let stubCards = [Self.twoLines, Self.threeLines].enumerated().map { i, answer in
      StubDeck.Card(id: "A15A15A\(i)-0000-0000-0000-00000000000\(i)", front: Self.westphalia, back: answer,
                    due: base.addingTimeInterval(Double(i) * 60), createdAt: base.addingTimeInterval(Double(i) * 60))
    }
    let deck = StubDeck(stubCards)
    let server = StubAPIServer { request in
      let route = StubDeck.route(request.path)
      guard request.method == "POST", route.hasSuffix("/review") else { return deck.handle(request) }
      let id = String(route.dropFirst("/cards/".count).dropLast("/review".count))
      guard let found = deck.cards.first(where: { $0.id.lowercased() == id.lowercased() }) else {
        return .init(status: 404, body: "{}")
      }
      deck.remove(id: id)
      return .init(body: StubDeck.json(found))
    }
    try server.start()
    defer { server.stop() }
    let stub = launch(api: .live(server.url))
    card = el(stub, "study.card"); front = el(stub, "study.front"); back = el(stub, "study.back")
    waitForLabel(front, Self.westphalia)
    Thread.sleep(forTimeInterval: 0.6)

    (q, a) = revealChecked(stub, Self.twoLines, "b", mode)
    note("QA017-15 \(mode) b: card \(card.frame) front \(q) back \(a)")
    XCTAssertGreaterThan(a.height, oneLineHeight * 1.5, "(b) fixture: answer not 2 lines \(a) (one line = \(oneLineHeight))")
    XCTAssertLessThan(a.height, oneLineHeight * 2.5, "(b) fixture: answer not 2 lines \(a) (one line = \(oneLineHeight))")
    XCTAssertEqual(a.midX, card.frame.midX, accuracy: 1, "(b) 2-line answer not centred in study.card: \(a) in \(card.frame)")
    assertLinesCentred(stub, a, card.frame, lines: 2, "(b)")
    snapshot("study-answer-align-b-2lines-back", appearance: appearance)
    rateGood(stub, next: Self.westphalia)
    waitForLabel(front, Self.westphalia)
    XCTAssertTrue(poll(timeout: 5) { !back.exists }, "previous answer still shown")

    (q, a) = revealChecked(stub, Self.threeLines, "c", mode)
    note("QA017-15 \(mode) c: card \(card.frame) front \(q) back \(a)")
    XCTAssertGreaterThan(a.height, oneLineHeight * 2.5, "(c) fixture: answer not 3+ lines \(a) (one line = \(oneLineHeight))")
    XCTAssertEqual(a.minX, q.minX, accuracy: 1, "(c) 3+-line answer not at the question's left edge: \(a) vs \(q)")
    XCTAssertLessThanOrEqual(a.maxX, q.maxX + 6, "(c) 3+-line answer wider than the question: \(a) vs \(q)")
    snapshot("study-answer-align-c-3lines-back", appearance: appearance)
  }

  // MARK: - Helpers

  /// Reveals and checks (e): the question keeps its horizontal place and size; with a lift ≤ 40 pt its frame and
  /// pixels are identical, above it rises by exactly the lift (#14). Snapshots the front first. Returns the
  /// revealed (question, answer) frames.
  @MainActor
  private func revealChecked(_ app: XCUIApplication, _ answer: String?, _ name: String, _ mode: String)
    -> (CGRect, CGRect) {
    let front = el(app, "study.front"), back = el(app, "study.back")
    Thread.sleep(forTimeInterval: 0.4)
    let q = front.frame
    let before = XCUIScreen.main.screenshot().image.cgImage
    snapshot("study-answer-align-\(name)-front", appearance: mode == "dark" ? .dark : .light)
    el(app, "study.reveal").tap()
    if let answer { waitForLabel(back, answer) } else { XCTAssertTrue(back.waitFor(timeout: 5), "(\(name)) study.back missing") }
    XCTAssertTrue(el(app, "study.rate.good").waitFor(timeout: 3), "(\(name)) ratings missing")
    Thread.sleep(forTimeInterval: 0.6)  // lift and fade settled
    let qa = front.frame, a = back.frame
    let lift = (a.maxY - qa.minY - q.height) / 2
    XCTAssertEqual(qa.minX, q.minX, accuracy: 0.5, "(e/\(name)) question moved sideways \(q) → \(qa)")
    XCTAssertEqual(qa.width, q.width, accuracy: 0.5, "(e/\(name)) question resized \(q) → \(qa)")
    XCTAssertEqual(qa.height, q.height, accuracy: 0.5, "(e/\(name)) question resized \(q) → \(qa)")
    XCTAssertGreaterThanOrEqual(a.minY, qa.maxY - 1, "(\(name)) answer not below the question")
    if lift <= 40 {
      XCTAssertEqual(qa, q, "(e/\(name)) lift \(lift) ≤ 40 but the question moved \(q) → \(qa)")
      let changed = changedPoints(before, XCUIScreen.main.screenshot().image.cgImage, in: q)
      note("QA017-15 \(mode) \(name): lift \(lift), question changed points \(changed)")
      XCTAssertEqual(changed, 0, "(e/\(name)) \(changed) question pixels changed on reveal")
    } else {
      note("QA017-15 \(mode) \(name): lift \(lift), moved \(q.minY - qa.minY)")
      XCTAssertEqual(q.minY - qa.minY, lift, accuracy: 1, "(e/\(name)) lifted \(q.minY - qa.minY), expected \(lift)")
    }
    return (qa, a)
  }

  /// Each drawn line of the answer (ink bands in its frame) is centred on the card's centre (± 2 pt: glyph
  /// side bearings), and there are `lines` of them.
  @MainActor
  private func assertLinesCentred(_ app: XCUIApplication, _ a: CGRect, _ card: CGRect, lines: Int, _ what: String) {
    let probe = ColorProbe(screenOf: app)
    let bg = probe.color(at: CGPoint(x: card.minX + 2, y: a.minY))
    var bands: [(minX: CGFloat, maxX: CGFloat)] = []
    var inBand = false
    for y in stride(from: a.minY, to: a.maxY, by: 1.0 / 3) {
      let xs = stride(from: card.minX, to: card.maxX, by: 1.0 / 3)
        .filter { probe.color(at: CGPoint(x: $0, y: y)).distance(to: bg) > 60 }
      if let lo = xs.first, let hi = xs.last {
        if inBand, let last = bands.last {
          bands[bands.count - 1] = (min(last.minX, lo), max(last.maxX, hi))
        } else {
          bands.append((lo, hi))
        }
        inBand = true
      } else {
        inBand = false
      }
    }
    note("QA017-15 \(what) ink lines \(bands) card midX \(card.midX)")
    XCTAssertEqual(bands.count, lines, "\(what) expected \(lines) drawn line(s), found \(bands.count): \(bands)")
    for (i, b) in bands.enumerated() {
      XCTAssertEqual((b.minX + b.maxX) / 2, card.midX, accuracy: 2,
                     "\(what) line \(i + 1) ink \(b.minX)–\(b.maxX) not centred on \(card.midX)")
    }
  }

  @MainActor
  private func rateGood(_ app: XCUIApplication, next: String) {
    el(app, "study.rate.good").tap()
    waitForLabel(el(app, "study.front"), next)
    Thread.sleep(forTimeInterval: 0.5)  // fade-in done
  }

  private func note(_ line: String) {
    print(line)
    XCTContext.runActivity(named: line) { _ in }
  }
}
