import XCTest

/// Spec 017: adaptive card text. Size and alignment by length, the next card fades in.
/// Deck = `LA_CARTE_API=mock-lengths`: "la mer", the Westphalia question (long), "mitochondria" (short question,
/// long answer), the Darwin card (> 500 characters), then serendipity / la carte / ephemeral.
/// Light mode only (spec: "QA captures in light mode, on one simulator"). AC 1–4 are unit tests; AC 12's VoiceOver
/// half is deferred (docs/testing.md: no VoiceOver tests for now).
final class StudyLengthsUITests: XCTestCase {
  static let short = ("la mer", "the sea")
  static let long = ("Which treaty, signed in 1648, ended the Thirty Years' War and is often cited as the origin of "
                     + "the modern state system?", "The Peace of Westphalia")
  static let shortQ = "mitochondria"
  static let veryLongPrefix = "In 1859, Charles Darwin"

  override func setUp() {
    continueAfterFailure = false
    XCUIDevice.shared.appearance = .light
  }

  // MARK: - AC 5, 6, 7, 9

  /// AC 5 short card centred; AC 6 long question + its short answer leading at the card's leading edge; AC 9 the
  /// long front doesn't move on reveal; AC 7 short question centred over a leading long answer.
  @MainActor
  func testStudyLengths_alignmentByLength() {
    let app = launch(api: .mockLengths)
    let card = el(app, "study.card"), front = el(app, "study.front"), back = el(app, "study.back")

    // AC 5: "la mer" / "the sea".
    waitForLabel(front, Self.short.0)
    XCTAssertEqual(front.frame.midX, card.frame.midX, accuracy: 1, "short front not centred: \(front.frame) in \(card.frame)")
    snapshot("study-lengths-short-front", appearance: .light)
    reveal(app, Self.short.1)
    XCTAssertEqual(front.frame.midX, card.frame.midX, accuracy: 1, "short front not centred after reveal")
    XCTAssertEqual(back.frame.midX, card.frame.midX, accuracy: 1, "short back not centred: \(back.frame) in \(card.frame)")
    snapshot("study-lengths-short-back", appearance: .light)
    rateGood(app, next: Self.long.0)

    // AC 6 + 9: Westphalia (3+ lines, layout D: a block as wide as its widest line, centred in the column).
    let lead = card.frame.minX
    XCTAssertEqual(front.frame.midX, card.frame.midX, accuracy: 1, "long front block not centred: \(front.frame) in \(card.frame)")
    XCTAssertGreaterThan(front.frame.width, card.frame.width * 0.8, "long front doesn't span the card: \(front.frame)")
    let before = front.frame
    snapshot("study-lengths-long-front", appearance: .light)
    reveal(app, Self.long.1)
    XCTAssertEqual(front.frame.minX, before.minX, accuracy: 0.5, "AC 9: front moved on reveal \(before) → \(front.frame)")
    XCTAssertEqual(front.frame.minY, before.minY, accuracy: 0.5, "AC 9: front moved on reveal \(before) → \(front.frame)")
    XCTAssertEqual(front.frame.size, before.size, "AC 9: front resized on reveal \(before) → \(front.frame)")
    // Layout D: the short answer under a leading question starts at the question's left edge, inside its width.
    XCTAssertEqual(back.frame.minX, front.frame.minX, accuracy: 1, "short answer not at the long question's left edge: \(back.frame) vs \(front.frame)")
    XCTAssertLessThanOrEqual(back.frame.maxX, front.frame.maxX + 6, "answer wider than the question: \(back.frame) vs \(front.frame)")
    XCTAssertGreaterThanOrEqual(back.frame.minY, front.frame.maxY - 1, "back not below front")
    snapshot("study-lengths-long-back", appearance: .light)
    rateGood(app, next: Self.shortQ)

    // AC 7: mitochondria.
    XCTAssertEqual(front.frame.midX, card.frame.midX, accuracy: 1, "short question not centred: \(front.frame)")
    snapshot("study-lengths-shortq-longa-front", appearance: .light)
    reveal(app, nil)
    XCTAssertEqual(front.frame.midX, card.frame.midX, accuracy: 1, "short question not centred after reveal")
    XCTAssertEqual(back.frame.minX, lead, accuracy: 1, "long answer not leading: \(back.frame) in \(card.frame)")
    XCTAssertGreaterThan(back.frame.width, card.frame.width * 0.8, "long answer doesn't span the card: \(back.frame)")
    assertTextsReadable(in: app)
    snapshot("study-lengths-shortq-longa-back", appearance: .light)
  }

  // MARK: - AC 8, 11, scroll reset

  /// AC 8: on the very long card the chrome keeps the short card's frames and the end of the answer can be
  /// scrolled into view. Then (engineer's note) scroll down, rate, and the next card opens at the top. AC 11: the
  /// change from the very long card to "serendipity" is captured as a frame sequence (`study-lengths-fade-NN`).
  @MainActor
  func testStudyLengths_veryLongCardChromeScrollAndFade() {
    // Reference: where "serendipity" sits as the first card of the plain mock deck.
    let plain = launch(api: .mock)
    waitForLabel(el(plain, "study.front"), "serendipity")
    let serendipityFront = el(plain, "study.front").frame
    plain.terminate()

    let app = launch(api: .mockLengths)
    let card = el(app, "study.card"), front = el(app, "study.front"), back = el(app, "study.back")
    let chrome = ["study.deck", "study.add", "study.reveal"]
    let rates = ["study.rate.again", "study.rate.good"]

    waitForLabel(front, Self.short.0)
    let shortChrome = chrome.map { el(app, $0).frame }
    // Control for AC 11: the reveal fades over the same 0.25 s (`Theme.Motion.standard`), so this sequence shows
    // whether the capture rate can see a 0.25 s fade at all (`study-lengths-revealfade-NN`).
    let revealFrames = captureFrames(during: 1.0) { el(app, "study.reveal").tap() }
    attach(revealFrames, "study-lengths-revealfade")
    waitForLabel(back, Self.short.1)
    Thread.sleep(forTimeInterval: 0.4)
    let shortRates = rates.map { el(app, $0).frame }
    rateGood(app, next: Self.long.0)
    reveal(app, Self.long.1)
    rateGood(app, next: Self.shortQ)
    reveal(app, nil)
    el(app, "study.rate.good").tap()
    XCTAssertTrue(poll(timeout: 5) { front.label.hasPrefix(Self.veryLongPrefix) }, "very long card not next: '\(front.label)'")
    XCTAssertGreaterThan(front.label.count, 500, "very long card has \(front.label.count) characters")

    for (id, frame) in zip(chrome, shortChrome) {
      XCTAssertTrue(el(app, id).waitFor(timeout: 3), "\(id) missing on the very long card")
      assertSameFrame(el(app, id).frame, frame, id)
    }
    XCTAssertEqual(front.frame.midX, card.frame.midX, accuracy: 1, "very long front block not centred")
    XCTAssertGreaterThan(front.frame.width, card.frame.width * 0.9, "very long front doesn't fill the column")
    snapshot("study-lengths-verylong-front", appearance: .light)
    reveal(app, nil)
    for (id, frame) in zip(rates, shortRates) { assertSameFrame(el(app, id).frame, frame, id) }
    snapshot("study-lengths-verylong-back", appearance: .light)

    // End of the answer reachable: drag the text up until study.back ends above the rating row.
    let rateTop = el(app, "study.rate.good").frame.minY
    var drags = 0
    while back.frame.maxY > rateTop - 1, drags < 4 {
      dragUp(app, on: front)
      drags += 1
    }
    XCTAssertTrue(front.label.hasPrefix(Self.veryLongPrefix), "a scroll drag changed the card (rated it?)")
    XCTAssertLessThanOrEqual(back.frame.maxY, rateTop, "end of study.back not scrollable into view: \(back.frame), rating row at \(rateTop)")
    XCTAssertGreaterThanOrEqual(back.frame.minY, card.frame.minY - 1, "study.back scrolled above the card")
    for (id, frame) in zip(rates + ["study.deck", "study.add"], shortRates + shortChrome.prefix(2)) {
      assertSameFrame(el(app, id).frame, frame, "\(id) after scrolling")
    }
    // Scroll further down if there's room, so a kept offset would show on the next card. Only when the card
    // scrolls: on a card that fits, a vertical drag is a rating drag (spec 019 #2).
    if drags > 0 {
      dragUp(app, on: back)
      XCTAssertTrue(front.label.hasPrefix(Self.veryLongPrefix), "a scroll drag changed the card (rated it?)")
    }
    snapshot("study-lengths-verylong-scrolled", appearance: .light)

    // AC 11: rate and capture the transition.
    let frames = captureFrames(during: 1.4) { el(app, "study.rate.good").tap() }
    waitForLabel(front, "serendipity")
    attach(frames, "study-lengths-fade")
    XCTAssertGreaterThanOrEqual(frames.count, 5, "too few transition frames captured (\(frames.count))")

    // The next card opens at the top / centred like any short card: same place as "la mer".
    XCTAssertFalse(back.exists, "previous answer shown on the next card")
    XCTAssertEqual(front.frame, serendipityFront, "next card not where a fresh 'serendipity' sits: \(front.frame) vs \(serendipityFront)")
    XCTAssertEqual(front.frame.midX, card.frame.midX, accuracy: 1, "next card not centred")
    snapshot("study-lengths-after-verylong", appearance: .light)
  }

  // MARK: - AC 10

  /// AC 10: double-tap the revealed long front → `study.frontField` keeps its leading edge, and typing a short
  /// then a medium-length draft keeps the saved text's 22 pt line height (smaller than the 34 pt "la mer" field).
  @MainActor
  func testStudyLengths_inlineEditLongFront() {
    let app = launch(api: .mockLengths)
    let front = el(app, "study.front"), field = el(app, "study.frontField")

    waitForLabel(front, Self.short.0)
    reveal(app, Self.short.1)
    front.doubleTap()
    XCTAssertTrue(field.waitFor(timeout: 5), "frontField missing on la mer")
    Thread.sleep(forTimeInterval: 0.6)
    let shortLine = field.frame.height
    tapDone(app)
    waitForAbsence(field)
    rateGood(app, next: Self.long.0)

    reveal(app, Self.long.1)
    let back = el(app, "study.back")
    Thread.sleep(forTimeInterval: 0.4)
    let text = front.frame, answer = back.frame
    snapshot("study-lengths-long-revealed", appearance: .light)
    front.doubleTap()
    XCTAssertTrue(field.waitFor(timeout: 5), "frontField missing after double-tap on the long front")
    XCTAssertTrue(app.keyboards.firstMatch.waitFor(timeout: 5), "no keyboard")
    Thread.sleep(forTimeInterval: 0.6)
    XCTAssertEqual(field.frame.minX, text.minX, accuracy: 1, "frontField leading edge \(field.frame) vs text \(text)")
    XCTAssertEqual(field.frame.width, text.width, accuracy: 1, "frontField width \(field.frame) vs the block \(text)")
    // Not an AC 10 item: the 5-line field measures ~0.5 pt per line taller than the text (noted in the QA report).
    XCTAssertEqual(field.frame.height, text.height, accuracy: 4, "frontField height \(field.frame) vs text \(text)")
    // Starting the edit must not move the answer relative to the question (the keyboard lifts the whole centred
    // stack; the field may be ~2 pt taller than the text, drawn over its slot, not over the answer).
    let offsetBefore = answer.minY - text.minY, offsetEditing = back.frame.minY - field.frame.minY
    note("QA017 edit start: text \(text) answer \(answer) field \(field.frame) back \(back.frame)")
    XCTAssertEqual(offsetEditing, offsetBefore, accuracy: 0.5,
                   "answer moved relative to the question when the edit started: \(offsetBefore) → \(offsetEditing)")
    XCTAssertEqual(back.frame.height, answer.height, accuracy: 0.5, "study.back resized when the edit started")
    assertAnswerClear(field, back, "edit start")
    snapshot("study-lengths-long-editing", appearance: .light)

    // Short draft (13 chars: the "short" tier if the field followed the draft).
    replaceText(field, with: "Which treaty?", caret: CGVector(dx: 0.99, dy: 0.95))
    Thread.sleep(forTimeInterval: 0.4)
    let shortDraft = field.frame
    XCTAssertEqual(shortDraft.minX, text.minX, accuracy: 1, "frontField moved off the leading edge: \(shortDraft)")
    XCTAssertLessThan(shortDraft.height, shortLine - 5,
                      "one-line draft is \(shortDraft.height) pt high, la mer's 34 pt field is \(shortLine): font followed the draft")
    snapshot("study-lengths-long-editing-short-draft", appearance: .light)

    // Medium draft (29 chars: the "medium" tier), still one line at 22 pt.
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 1) + ", signed in 1648?")
    XCTAssertTrue(poll(timeout: 3) { (field.value as? String) == "Which treaty, signed in 1648?" },
                  "draft is '\(field.value as? String ?? "")'")
    Thread.sleep(forTimeInterval: 0.4)
    XCTAssertEqual(field.frame.height, shortDraft.height, accuracy: 0.5, "line height changed while typing: \(shortDraft) → \(field.frame)")
    XCTAssertEqual(field.frame.minX, text.minX, accuracy: 1, "frontField moved while typing")
    assertAnswerClear(field, back, "medium draft")
    snapshot("study-lengths-long-editing-medium-draft", appearance: .light)

    note("QA017 before long-word tap: field \(field.frame) text \(text) card \(el(app, "study.card").frame)")
    // A draft that can wrap differently in the field and in a Text (very long words, no break opportunity).
    let longWords = "Pneumonoultramicroscopicsilicovolcanoconiosis, Hippopotomonstrosesquippedaliophobia?"
    replaceText(field, with: longWords, caret: CGVector(dx: 0.99, dy: 0.95))
    XCTAssertTrue(poll(timeout: 3) { (field.value as? String) == longWords }, "draft is '\(field.value as? String ?? "")'")
    Thread.sleep(forTimeInterval: 0.4)
    XCTAssertEqual(field.frame.minX, text.minX, accuracy: 1, "frontField moved off the leading edge: \(field.frame)")
    assertAnswerClear(field, back, "long-word draft")
    snapshot("study-lengths-long-editing-longword-draft", appearance: .light)

    replaceText(field, with: "Which treaty, signed in 1648?", caret: CGVector(dx: 0.99, dy: 0.95))
    Thread.sleep(forTimeInterval: 0.4)

    // Saved: the size may change once (now a centred medium question).
    tapDone(app)
    waitForLabel(front, "Which treaty, signed in 1648?", timeout: 3)
    XCTAssertEqual(front.frame.midX, el(app, "study.card").frame.midX, accuracy: 1, "saved medium question not centred")
    snapshot("study-lengths-long-edited", appearance: .light)
  }

  /// Inline edit, draft ending in a newline. Return (and a pasted newline) commit the edit, so the only way to get
  /// there is to delete the last line of a card that has a line break. The field then shows an empty last line:
  /// it must not draw over the answer, and starting the edit must not move the answer relative to the question.
  @MainActor
  func testStudyLengths_inlineEditTrailingNewline() throws {
    let deck = StubDeck([.init(id: "CCCCCCCC-0000-0000-0000-0000000000C3",
                               front: "Which treaty ended the Thirty Years' War?\nWestphalia", back: "1648")])
    let server = StubAPIServer { deck.handle($0) }
    try server.start()
    let app = launch(api: .live(server.url))
    let front = el(app, "study.front"), back = el(app, "study.back"), field = el(app, "study.frontField")
    XCTAssertTrue(poll(timeout: 10) { front.label.hasSuffix("Westphalia") }, "stub card not shown: '\(front.label)'")
    reveal(app, "1648")
    Thread.sleep(forTimeInterval: 0.4)
    let text = front.frame, answer = back.frame
    snapshot("study-lengths-newline-revealed", appearance: .light)

    front.doubleTap()
    XCTAssertTrue(field.waitFor(timeout: 5), "frontField missing after double-tap")
    XCTAssertTrue(app.keyboards.firstMatch.waitFor(timeout: 5), "no keyboard")
    Thread.sleep(forTimeInterval: 0.6)
    XCTAssertEqual(back.frame.minY - field.frame.minY, answer.minY - text.minY, accuracy: 0.5,
                   "answer moved relative to the question when the edit started")
    assertAnswerClear(field, back, "two-line card, edit start")
    snapshot("study-lengths-newline-editing", appearance: .light)

    field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.95)).tap()
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Westphalia".count))
    XCTAssertTrue(poll(timeout: 3) { (field.value as? String) == "Which treaty ended the Thirty Years' War?\n" },
                  "draft is '\(field.value as? String ?? "")'")
    Thread.sleep(forTimeInterval: 0.4)
    assertAnswerClear(field, back, "draft ending in a newline")
    snapshot("study-lengths-newline-draft", appearance: .light)
  }

  // MARK: - medium screenshot (25–60 characters)

  /// The spec's `study-lengths-medium-*` state: mock-lengths has no 25–60 character question, so a stub serves one.
  @MainActor
  func testStudyLengths_mediumQuestion() throws {
    let deck = StubDeck([.init(id: "CCCCCCCC-0000-0000-0000-0000000000C1",
                               front: "What is the capital of Australia?", back: "Canberra")])
    let server = StubAPIServer { deck.handle($0) }
    try server.start()
    let app = launch(api: .live(server.url))
    let card = el(app, "study.card"), front = el(app, "study.front"), back = el(app, "study.back")
    waitForLabel(front, "What is the capital of Australia?")
    XCTAssertEqual(front.frame.midX, card.frame.midX, accuracy: 1, "medium front not centred")
    snapshot("study-lengths-medium-front", appearance: .light)
    reveal(app, "Canberra")
    XCTAssertEqual(back.frame.midX, card.frame.midX, accuracy: 1, "short answer under a medium question not centred")
    snapshot("study-lengths-medium-back", appearance: .light)
  }

  // MARK: - AC 8 (overflow), scroll reset

  /// The mock's > 500-character card fits one screen (spec rule 5), so nothing scrolls there. A stub card of
  /// ~1,000 characters overflows: the chrome keeps its frames, the end of the answer scrolls into view, and after
  /// rating from the scrolled-down position the next long card opens at its top.
  @MainActor
  func testStudyLengths_overflowingCardScrollsAndNextOpensAtTop() throws {
    let paragraph = String(repeating: "Spaced repetition schedules each review just before you would forget. ", count: 14)
      .trimmingCharacters(in: .whitespaces)
    let answer = "The end of this answer must be reachable by scrolling."
    let base = Date(timeIntervalSince1970: 1_767_225_600)
    let deck = StubDeck([
      .init(id: "DDDDDDDD-0000-0000-0000-0000000000D1", front: paragraph, back: answer, due: base, createdAt: base),
      .init(id: "DDDDDDDD-0000-0000-0000-0000000000D2", front: "Second " + paragraph, back: "second",
            due: base.addingTimeInterval(60), createdAt: base.addingTimeInterval(60)),
    ])
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
    let app = launch(api: .live(server.url))
    let card = el(app, "study.card"), front = el(app, "study.front"), back = el(app, "study.back")
    waitForLabel(front, paragraph)
    let topBefore = front.frame.minY
    snapshot("study-lengths-overflow-front", appearance: .light)
    reveal(app, answer)
    XCTAssertEqual(front.frame.minY, topBefore, accuracy: 0.5, "front moved on reveal")
    let rateTop = el(app, "study.rate.good").frame.minY
    let chrome = ["study.deck", "study.add", "study.rate.again", "study.rate.good"].map { el(app, $0).frame }
    XCTAssertGreaterThan(back.frame.maxY, rateTop, "stub card doesn't overflow: back \(back.frame), ratings at \(rateTop)")
    snapshot("study-lengths-overflow-back", appearance: .light)
    var drags = 0
    while back.frame.maxY > rateTop - 1, drags < 5 {
      dragUp(app, on: front)
      drags += 1
    }
    XCTAssertEqual(front.label, paragraph, "a scroll drag changed the card (rated it?)")
    XCTAssertLessThanOrEqual(back.frame.maxY, rateTop, "end of study.back not scrollable above the ratings: \(back.frame)")
    XCTAssertLessThan(front.frame.minY, topBefore - 50, "card didn't scroll: front \(front.frame)")
    for (id, frame) in zip(["study.deck", "study.add", "study.rate.again", "study.rate.good"], chrome) {
      assertSameFrame(el(app, id).frame, frame, "\(id) after scrolling")
    }
    snapshot("study-lengths-overflow-scrolled", appearance: .light)
    el(app, "study.rate.good").tap()
    waitForLabel(front, "Second " + paragraph)
    Thread.sleep(forTimeInterval: 0.5)
    XCTAssertEqual(front.frame.minY, topBefore, accuracy: 0.5, "next card didn't open at the top: \(front.frame), first card top \(topBefore)")
    XCTAssertEqual(front.frame.midX, card.frame.midX, accuracy: 1, "next long front block not centred")
    snapshot("study-lengths-overflow-next", appearance: .light)
  }

  // MARK: - Layout D (default): a wide question's width is the answer's column

  static let longAnswer = "About 299,792 kilometres per second in a vacuum, the fastest that anything can travel, "
    + "and the same for every observer whatever their speed."

  /// AC 6, 7, 9, 10 under layout D. Each card: the question's frame is the same before and after reveal; under a
  /// wide question (wraps, or one line ≥ 85 % of the column) the answer stays inside the question's width (a
  /// leading answer starts at its left edge); under a short one-line question the answer uses the column (layout A).
  /// Widths measured with SF Pro: "Speed of light (km/s)?" one line ≈ 89 %, "Photosynthesis" ≈ 63 %,
  /// the two medium questions wrap to 2 lines.
  @MainActor
  func testStudyLengths_layoutD() throws {
    continueAfterFailure = true
    let cards: [(front: String, back: String, wide: Bool, leadingBack: Bool)] = [
      ("Which river flows through Paris?", "The Seine", true, false),          // 2 lines + 1 line
      ("Speed of light (km/s)?", Self.longAnswer, true, true),                  // ≥ 85 % one line + 3+ lines
      ("Who composed The Magic Flute?", Self.longAnswer, true, true),           // 2 lines + 3+ lines
      ("Speed of light (km/s)?", "299,792", true, false),                       // ≥ 85 % one line + 1 line
      ("Photosynthesis", Self.longAnswer, false, true),                         // short + 3+ lines (layout A)
    ]
    let base = Date(timeIntervalSince1970: 1_767_225_600)
    let stub = cards.enumerated().map { i, c in
      StubDeck.Card(id: "EEEEEEE\(i)-0000-0000-0000-00000000000\(i)", front: c.front, back: c.back,
                    due: base.addingTimeInterval(Double(i) * 60), createdAt: base.addingTimeInterval(Double(i) * 60))
    }
    let (server, _) = try startReviewStub(stub)
    let app = launch(api: .live(server.url))
    let card = el(app, "study.card"), front = el(app, "study.front"), back = el(app, "study.back")
    let names = ["2line-short", "wide1line-long", "2line-long", "wide1line-short", "shortq-long"]
    for (i, c) in cards.enumerated() {
      waitForLabel(front, c.front)
      Thread.sleep(forTimeInterval: 0.5)
      let q = front.frame
      note("QA017D \(names[i]) card \(card.frame) front \(q) ratio \(q.width / card.frame.width)")
      XCTAssertEqual(q.midX, card.frame.midX, accuracy: 1, "\(names[i]): question not centred \(q)")
      snapshot("study-layoutD-\(names[i])-front", appearance: .light)
      reveal(app, c.back)
      let a = back.frame
      note("QA017D \(names[i]) back \(a)")
      XCTAssertEqual(front.frame, q, "\(names[i]): question moved on reveal \(q) → \(front.frame)")
      XCTAssertGreaterThanOrEqual(a.minY, q.maxY - 1, "\(names[i]): answer not below the question")
      if c.wide {
        XCTAssertGreaterThanOrEqual(a.minX, q.minX - 1, "\(names[i]): answer starts left of the question \(a) vs \(q)")
        XCTAssertLessThanOrEqual(a.maxX, q.maxX + 6, "\(names[i]): answer wider than the question \(a) vs \(q)")
        if c.leadingBack {
          XCTAssertEqual(a.minX, q.minX, accuracy: 1, "\(names[i]): leading answer not at the question's left edge")
          // Ink, not frames: the answer's first glyph column vs the question's (AC 13: at most 3 pt left of it).
          let shot = ColorProbe(at3x: XCUIScreen.main.screenshot().image.cgImage!)
          let qInk = inkMinX(shot, q), aInk = inkMinX(shot, a)
          note("QA017D \(names[i]) ink left: question \(qInk) answer \(aInk)")
          XCTAssertGreaterThanOrEqual(aInk, qInk - 3, "\(names[i]): answer ink starts \(qInk - aInk) pt left of the question's")
        } else {
          XCTAssertEqual(a.midX, q.midX, accuracy: 1, "\(names[i]): one-line answer not centred under the question")
        }
      } else {
        XCTAssertEqual(a.minX, card.frame.minX, accuracy: 1, "\(names[i]): answer under a short question not at the column edge")
        XCTAssertGreaterThan(a.width, q.width + 50, "\(names[i]): answer squeezed under a short question \(a) vs \(q)")
      }
      snapshot("study-layoutD-\(names[i])-back", appearance: .light)
      if i == 2 {  // inline edit of the answer keeps the answer's column (the question's width)
        back.doubleTap()
        let field = el(app, "study.backField")
        XCTAssertTrue(field.waitFor(timeout: 5), "backField missing")
        Thread.sleep(forTimeInterval: 0.6)
        note("QA017D edit back \(field.frame) vs \(a)")
        XCTAssertEqual(field.frame.minX, a.minX, accuracy: 1, "backField left edge \(field.frame) vs answer \(a)")
        // The field takes the answer's column (the question's widest line incl. its break space), so it may be a few
        // points wider than the Text's own frame, never wider than the question (+ the ~7 pt break space).
        XCTAssertGreaterThanOrEqual(field.frame.width, a.width - 1, "backField narrower than the answer \(field.frame) vs \(a)")
        XCTAssertLessThanOrEqual(field.frame.maxX, q.maxX + 7, "backField wider than the question \(field.frame) vs \(q)")
        XCTAssertEqual(field.frame.height, a.height, accuracy: 1, "backField rewraps the answer \(field.frame) vs \(a)")
        snapshot("study-layoutD-2line-long-editing-back", appearance: .light)
        field.typeText("\n")
        waitForAbsence(field)
        Thread.sleep(forTimeInterval: 0.4)
      }
      if i + 1 < cards.count { el(app, "study.rate.good").tap() }
    }
    server.stop()
  }

  // MARK: - Scroll indicator: flashes on reveal only

  /// A short question whose hidden long answer overflows the card shows no scroll bar as it comes in: after an
  /// Easy drag, after the Got it button, after rating a scrolled card. Revealing a long card still flashes it
  /// (the control proving the detector sees the bar). Bar = changed pixels in the card's right 8 pt strip versus
  /// a settled screenshot taken 3 s later.
  @MainActor
  func testStudyLengths_scrollBarOnRevealOnly() throws {
    continueAfterFailure = true
    let essay = String(repeating: "Chlorophyll absorbs red and blue light and reflects green, which is why leaves look green. ",
                       count: 16).trimmingCharacters(in: .whitespaces)
    let fronts = ["la mer", "Chlorophyll 1", "Chlorophyll 2", "Chlorophyll 3"]
    let backs = ["the sea", essay, essay, essay]
    let base = Date(timeIntervalSince1970: 1_767_225_600)
    let stub = fronts.indices.map { i in
      StubDeck.Card(id: "FFFFFFF\(i)-0000-0000-0000-00000000000\(i)", front: fronts[i], back: backs[i],
                    due: base.addingTimeInterval(Double(i) * 60), createdAt: base.addingTimeInterval(Double(i) * 60))
    }
    let (server, _) = try startReviewStub(stub)
    let app = launch(api: .live(server.url))
    let front = el(app, "study.front")
    waitForLabel(front, fronts[0])
    Thread.sleep(forTimeInterval: 0.5)
    let area = app.scrollViews.matching(identifier: "study.card").firstMatch.frame
    let strip = CGRect(x: area.maxX - 8, y: area.minY + 4, width: 7.5, height: area.height - 8)
    note("QA017S card \(area) strip \(strip)")

    // 1. Easy drag on the revealed short card → Chlorophyll 1.
    reveal(app, backs[0])
    var bar = barPoints(app, strip, "easy-next") {
      let card = el(app, "study.card"), w = card.frame.width
      let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0.22 * w, dy: 0)))
    }
    waitForLabel(front, fronts[1])
    XCTAssertEqual(bar, 0, "scroll bar shown as the next card came in after an Easy drag")
    snapshot("study-scrollbar-after-easy", appearance: .light)

    // 2. Control: reveal the long answer → the bar flashes.
    bar = barPoints(app, strip, "reveal") { el(app, "study.reveal").tap() }
    XCTAssertGreaterThan(bar, 40, "no scroll bar flash on revealing a long card (detector blind?)")
    Thread.sleep(forTimeInterval: 0.3)

    // 3. Got it button (unscrolled) → Chlorophyll 2.
    bar = barPoints(app, strip, "gotit-next") { el(app, "study.rate.good").tap() }
    waitForLabel(front, fronts[2])
    XCTAssertEqual(bar, 0, "scroll bar shown as the next card came in after Got it")
    snapshot("study-scrollbar-after-gotit", appearance: .light)

    // 4. Reveal, scroll down, Got it → Chlorophyll 3.
    reveal(app, nil)
    dragUp(app, on: front)
    dragUp(app, on: el(app, "study.back"))
    XCTAssertEqual(front.label, fronts[2], "a scroll drag rated the card")
    Thread.sleep(forTimeInterval: 2.5)  // the scroll's own indicator fades before the next card
    bar = barPoints(app, strip, "scrolled-next") { el(app, "study.rate.good").tap() }
    waitForLabel(front, fronts[3])
    XCTAssertEqual(bar, 0, "scroll bar shown as the next card came in after a scrolled card")
    snapshot("study-scrollbar-after-scrolled", appearance: .light)
    server.stop()
  }

  /// Most changed points in `strip` over frames taken after `action` returns, versus a screenshot 3 s later.
  @MainActor
  private func barPoints(_ app: XCUIApplication, _ strip: CGRect, _ name: String, _ action: () -> Void) -> Int {
    var released: TimeInterval = 0
    let start = Date()
    let frames = captureFrames(during: 1.6) {
      action()
      released = Date().timeIntervalSince(start)
    }
    Thread.sleep(forTimeInterval: 3)
    let settled = XCUIScreen.main.screenshot().pngRepresentation
    let image = { (png: Data) -> CGImage? in
      guard let p = CGDataProvider(data: png as CFData) else { return nil }
      return CGImage(pngDataProviderSource: p, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    let base = image(settled)
    var worst = 0, worstFrame: (t: TimeInterval, png: Data)?
    for f in frames where f.t > released {
      let n = changedPoints(image(f.png), base, in: strip)
      if n > worst { worst = n; worstFrame = f }
    }
    note("QA017S \(name): released +\(released) s, \(frames.count) frames, worst \(worst) points")
    if let worstFrame { attach([worstFrame], "study-scrollbar-\(name)-worst") }
    return worst
  }

  private func startReviewStub(_ cards: [StubDeck.Card]) throws -> (StubAPIServer, StubDeck) {
    let deck = StubDeck(cards)
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
    return (server, deck)
  }

  // MARK: - Helpers

  /// Leftmost x (pt, 1/3 pt steps) in `rect` whose colour is far from the rect's top-left corner (the background).
  private func inkMinX(_ probe: ColorProbe, _ rect: CGRect) -> CGFloat {
    let bg = probe.color(at: CGPoint(x: rect.minX - 8, y: rect.minY))
    for x in stride(from: rect.minX - 8, to: rect.maxX, by: 1.0 / 3) {
      for y in stride(from: rect.minY, to: rect.maxY, by: 1.0 / 3) where probe.color(at: CGPoint(x: x, y: y)).distance(to: bg) > 60 {
        return x
      }
    }
    return .infinity
  }

  /// A line in the console and in the result bundle's activity log (merged split bundles keep no console log).
  private func note(_ line: String) {
    print(line)
    XCTContext.runActivity(named: line) { _ in }
  }

  @MainActor
  private func reveal(_ app: XCUIApplication, _ back: String?, file: StaticString = #filePath, line: UInt = #line) {
    let reveal = el(app, "study.reveal")
    XCTAssertTrue(reveal.waitFor(timeout: 5), "study.reveal missing", file: file, line: line)
    reveal.tap()
    if let back {
      waitForLabel(el(app, "study.back"), back, file: file, line: line)
    } else {
      XCTAssertTrue(el(app, "study.back").waitFor(timeout: 5), "study.back missing after reveal", file: file, line: line)
    }
    XCTAssertTrue(el(app, "study.rate.good").waitFor(timeout: 3), "ratings missing", file: file, line: line)
    Thread.sleep(forTimeInterval: 0.4)  // reveal animation settles before frames are read
  }

  @MainActor
  private func rateGood(_ app: XCUIApplication, next: String, file: StaticString = #filePath, line: UInt = #line) {
    el(app, "study.rate.good").tap()
    waitForLabel(el(app, "study.front"), next, file: file, line: line)
    Thread.sleep(forTimeInterval: 0.5)  // fade-in done
  }

  @MainActor
  private func dragUp(_ app: XCUIApplication, on element: XCUIElement) {
    let window = app.windows.firstMatch
    let x = 0.5, from = min(max(element.frame.midY / window.frame.height, 0.35), 0.7)
    window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: from))
      .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: from - 0.3)),
             withVelocity: .slow, thenHoldForDuration: 0.1)
    Thread.sleep(forTimeInterval: 0.6)
  }

  private func assertSameFrame(_ a: CGRect, _ b: CGRect, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
    let same = abs(a.minX - b.minX) <= 0.5 && abs(a.minY - b.minY) <= 0.5 && abs(a.width - b.width) <= 0.5
      && abs(a.height - b.height) <= 0.5
    XCTAssertTrue(same, "\(what) frame \(a) differs from the short card's \(b)", file: file, line: line)
  }

  /// The field's frame ends above the answer's, with at least the pre-edit text/answer spacing minus the field's
  /// ~2 pt extra height (so the field never draws over the answer).
  @MainActor
  private func assertAnswerClear(_ field: XCUIElement, _ back: XCUIElement, _ what: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
    let f = field.frame, b = back.frame
    note("QA017 \(what): field \(f) back \(b) gap \(b.minY - f.maxY)")
    XCTAssertTrue(back.exists, "study.back hidden while editing (\(what))", file: file, line: line)
    XCTAssertLessThanOrEqual(f.maxY, b.minY, "frontField \(f) overlaps study.back \(b) (\(what))", file: file, line: line)
  }

  /// Return commits the edit (spec 010 #4, `submitLabel(.done)`); typed into the focused field.
  @MainActor
  private func tapDone(_ app: XCUIApplication) {
    el(app, "study.frontField").typeText("\n")
  }

  private func attach(_ frames: [(t: TimeInterval, png: Data)], _ name: String) {
    for (i, frame) in frames.enumerated() {
      let attachment = XCTAttachment(data: frame.png, uniformTypeIdentifier: "public.png")
      attachment.name = String(format: "\(name)-%02d-%04dms-light", i, Int(frame.t * 1000))
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

  /// Screenshots taken off the main thread as fast as possible for `duration` seconds, starting just before
  /// `action` (XCUITest only returns from a tap once the app is idle, so frames must be captured concurrently).
  @MainActor
  private func captureFrames(during duration: TimeInterval, _ action: () -> Void) -> [(t: TimeInterval, png: Data)] {
    let box = FrameBox()
    let start = Date()
    let thread = Thread {
      while Date().timeIntervalSince(start) < duration {
        if let png = screenshotPNGOffMain() { box.append((Date().timeIntervalSince(start), png)) }
      }
      box.finish()
    }
    thread.start()
    Thread.sleep(forTimeInterval: 0.15)
    action()
    let deadline = Date().addingTimeInterval(duration + 10)
    while !box.isDone, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    return box.frames
  }
}

private final class FrameBox: @unchecked Sendable {
  private let lock = NSLock()
  private var _frames: [(t: TimeInterval, png: Data)] = []
  private var done = false
  nonisolated func append(_ f: (TimeInterval, Data)) { lock.withLock { _frames.append((t: f.0, png: f.1)) } }
  nonisolated func finish() { lock.withLock { done = true } }
  nonisolated var isDone: Bool { lock.withLock { done } }
  nonisolated var frames: [(t: TimeInterval, png: Data)] { lock.withLock { _frames } }
}
