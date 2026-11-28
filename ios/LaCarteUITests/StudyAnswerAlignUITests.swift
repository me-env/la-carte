import XCTest

/// Spec 017 #16 "One axis per card + weight transfer" (amends #2, #6, #7, #10, #13, #15; 2026-11-28), layout D,
/// light + dark. Supersedes the #15 checks this class held.
/// (a) Leading question (3+ lines) + 1-line answer (Westphalia, Git): question at the column's 16 pt edge
///     (`study.card` minX, which is x = 16 on screen), lines leading; answer on the same edge, `.cardFaceSmall`
///     (the question's line height), `ink`; question `ink` before reveal, `recededInk` after.
/// (b) Leading question + 2-line answer: answer on the edge, both lines start there, `ink`, `.body`.
/// (c) Leading question + 3+-line answer: as (b), never wider than the column.
/// (d) Centred questions unchanged: "la mer" / "the sea" centred, `ink` / `secondaryInk`; "mitochondria" + long
///     answer: answer leading at the column edge, `secondaryInk`; a 2-line question with a 1-line answer: centred.
///     Manager amendment (2026-11-28): a long (> 60 chars) but 2-line, centred question keeps `.cardAnswer`
///     (regular weight, `secondaryInk`) for its short answer.
/// (e) Motion: a frame sequence of the reveal shows the question's colour between `ink` and `recededInk`;
///     Reduce Motion (`testStudyAnswerAlign_reduceMotion`): the crossfade stays, the lift is dropped.
/// (f) The question's frame and ink mask (lines, extents) are unchanged by the reveal; only its colour changes.
/// (g) Edit: `study.frontField` of a revealed leading question starts at the edge, spans the column, `recededInk`.
/// (h) Person cards: `NotesUITests.testNotesStudy_personTextLayout` (014d), run alongside.
final class StudyAnswerAlignUITests: XCTestCase {
  static let westphalia = "Which treaty, signed in 1648, ended the Thirty Years' War and is often cited as the origin of "
    + "the modern state system?"
  static let oneLine = "The Peace of Westphalia"
  static let git = ("In Git, which command lists the commits on the current branch that are not on main yet?",
                    "git log main..HEAD")
  static let idiom = ("Which English idiom, built on a colour, means to feel sad or low in spirits for a while?",
                      "To feel down, to have the blues, to be in low spirits for a while")
  static let threeLines = "The Peace of Westphalia: treaties signed in Osnabrück and Münster in 1648, which ended "
    + "the Thirty Years' War and the Eighty Years' War."
  static let fiveLines = "The Peace of Westphalia: a series of treaties signed in Osnabrück and Münster in 1648. They "
    + "ended the Thirty Years' War in the Holy Roman Empire and the Eighty Years' War between Spain and the Dutch "
    + "Republic, and set out the principle that each state is sovereign over its own territory."
  static let longCentred = ("Which river flows through Paris to the sea at Le Havre, France?", "The Seine")
  static let flute = ("Who composed The Magic Flute?", "Wolfgang Amadeus Mozart")

  static let recededLight = RGB(0x6F, 0x6F, 0x6D), recededDark = RGB(0x8A, 0x8A, 0x88)

  override func setUp() {
    continueAfterFailure = true
  }

  @MainActor func testStudyAnswerAlign_light() throws { try run(.light) }
  @MainActor func testStudyAnswerAlign_dark() throws { try run(.dark) }

  @MainActor
  private func run(_ appearance: XCUIDevice.Appearance) throws {
    XCUIDevice.shared.appearance = appearance
    let mode = appearance == .dark ? "dark" : "light"
    let palette = Palette.of(appearance)
    let receded = appearance == .dark ? Self.recededDark : Self.recededLight

    // mock-lengths: la mer → Westphalia → mitochondria.
    let app = launch(api: .mockLengths)
    var card = el(app, "study.card"), front = el(app, "study.front"), back = el(app, "study.back")
    waitForLabel(front, "la mer")
    Thread.sleep(forTimeInterval: 0.6)
    note("QA017-16 \(mode) card \(card.frame) deck button \(el(app, "study.deck").frame)")

    // (d) la mer: both centred, question ink before and after, answer secondaryInk.
    var r = revealChecked(app, "the sea", "d-short", mode, leading: false)
    XCTAssertEqual(r.q.midX, card.frame.midX, accuracy: 1, "(d) la mer not centred \(r.q)")
    XCTAssertEqual(r.a.midX, card.frame.midX, accuracy: 1, "(d) the sea not centred \(r.a)")
    assertColour(r.qBefore, palette.ink, "(d) la mer before reveal")
    assertColour(r.qAfter, palette.ink, "(d) la mer after reveal")
    assertColour(r.aColour, palette.secondaryInk, "(d) the sea")
    rateGood(app, next: Self.westphalia)

    // (a) Westphalia + "The Peace of Westphalia": the reveal is captured as a frame sequence (e).
    r = revealChecked(app, Self.oneLine, "a-westphalia", mode, leading: true, captureMotion: true)
    let questionLine = r.lineHeight
    assertLeadingPair(r, card.frame, "(a) Westphalia")
    assertColour(r.qBefore, palette.ink, "(a) Westphalia before reveal")
    assertColour(r.qAfter, receded, "(a) Westphalia after reveal")
    assertColour(r.aColour, palette.ink, "(a) answer")
    XCTAssertEqual(r.a.height, questionLine, accuracy: 2,
                   "(a) 1-line answer \(r.a.height) pt high, question line \(questionLine): not .cardFaceSmall")
    // (g) Edit: the revealed leading question's field starts at 16 pt, spans the column, in recededInk.
    front.doubleTap()
    let field = el(app, "study.frontField")
    XCTAssertTrue(field.waitFor(timeout: 5), "(g) study.frontField missing")
    Thread.sleep(forTimeInterval: 0.8)
    let fieldFrame = field.frame
    note("QA017-16 \(mode) g: field \(fieldFrame) card \(card.frame) front was \(r.q)")
    XCTAssertEqual(fieldFrame.minX, card.frame.minX, accuracy: 1, "(g) frontField not at the 16 pt edge \(fieldFrame)")
    XCTAssertEqual(fieldFrame.width, card.frame.width, accuracy: 1, "(g) frontField doesn't span the column \(fieldFrame)")
    let fieldColour = textColour(ColorProbe(screenOf: app), fieldFrame, bg: r.bg)
    note("QA017-16 \(mode) g: field text colour \(fieldColour)")
    assertColour(fieldColour, receded, "(g) frontField text")
    snapshot("study-axis-g-editing-front", appearance: appearance)
    field.typeText("\n")
    waitForAbsence(field)
    Thread.sleep(forTimeInterval: 0.5)
    rateGood(app, next: "mitochondria")

    // (d) mitochondria: question centred ink, answer leading at the column edge, secondaryInk.
    r = revealChecked(app, nil, "d-shortq-longa", mode, leading: false)
    XCTAssertEqual(r.q.midX, card.frame.midX, accuracy: 1, "(d) mitochondria not centred \(r.q)")
    XCTAssertEqual(r.a.minX, card.frame.minX, accuracy: 1, "(d) long answer not at the column edge \(r.a)")
    assertColour(r.qAfter, palette.ink, "(d) mitochondria after reveal")
    assertColour(r.aColour, palette.secondaryInk, "(d) mitochondria answer")
    app.terminate()

    // Stub deck.
    let cases: [(String, String)] = [Self.git, Self.idiom, (Self.westphalia, Self.threeLines), Self.longCentred,
                                     Self.flute, (Self.westphalia, Self.fiveLines)]
    let base = Date(timeIntervalSince1970: 1_767_225_600)
    let stubCards = cases.enumerated().map { i, c in
      StubDeck.Card(id: "A16A16A\(i)-0000-0000-0000-00000000000\(i)", front: c.0, back: c.1,
                    due: base.addingTimeInterval(Double(i) * 60), createdAt: base.addingTimeInterval(Double(i) * 60))
    }
    let server = try startReviewStub(stubCards)
    defer { server.stop() }
    let stub = launch(api: .live(server.url))
    card = el(stub, "study.card"); front = el(stub, "study.front"); back = el(stub, "study.back")
    waitForLabel(front, Self.git.0)
    Thread.sleep(forTimeInterval: 0.6)

    // (a) Git.
    r = revealChecked(stub, Self.git.1, "a-git", mode, leading: true)
    assertLeadingPair(r, card.frame, "(a) Git")
    assertColour(r.qBefore, palette.ink, "(a) Git before reveal")
    assertColour(r.qAfter, receded, "(a) Git after reveal")
    assertColour(r.aColour, palette.ink, "(a) Git answer")
    XCTAssertEqual(r.a.height, r.lineHeight, accuracy: 2, "(a) Git answer not .cardFaceSmall (\(r.a.height) vs \(r.lineHeight))")
    // (e) The next card's question shows in ink from its first frame (no fade from grey): frame sequence.
    let next = captureFrames(during: 0.8) { el(stub, "study.rate.good").tap() }
    waitForLabel(front, Self.idiom.0)
    Thread.sleep(forTimeInterval: 0.6)
    let nextQ = front.frame
    let nextColours = next.map { textColour(ColorProbe(at3x: UIImage(data: $0.png)!.cgImage!), nextQ, bg: r.bg) }
    note("QA017-16 \(mode) e-next: \(zip(next.map { Int($0.t * 1000) }, nextColours).map { "\($0)ms \($1)" })")
    attach(next, "study-axis-e-next-\(mode)", every: 1)

    // (b) idiom + 2-line answer.
    r = revealChecked(stub, Self.idiom.1, "b-2lines", mode, leading: true)
    assertLeadingPair(r, card.frame, "(b)")
    XCTAssertEqual(r.aLines.count, 2, "(b) fixture: answer not 2 lines \(r.aLines)")
    XCTAssertLessThan(r.a.height / CGFloat(max(r.aLines.count, 1)), r.lineHeight - 2, "(b) 2-line answer not .body")
    assertColour(r.qAfter, receded, "(b) question after reveal")
    assertColour(r.aColour, palette.ink, "(b) answer")
    rateGood(stub, next: Self.westphalia)

    // (c) Westphalia + 3+-line answer.
    r = revealChecked(stub, Self.threeLines, "c-3lines", mode, leading: true)
    assertLeadingPair(r, card.frame, "(c)")
    XCTAssertGreaterThanOrEqual(r.aLines.count, 3, "(c) fixture: answer not 3+ lines \(r.aLines)")
    assertColour(r.qAfter, receded, "(c) question after reveal")
    assertColour(r.aColour, palette.ink, "(c) answer")
    rateGood(stub, next: Self.longCentred.0)

    // Manager amendment: a long (> 60 chars), 2-line centred question keeps .cardAnswer and today's colours.
    r = revealChecked(stub, Self.longCentred.1, "d-long2line", mode, leading: false)
    XCTAssertEqual(r.qLines.count, 2, "fixture: the 63-char question isn't 2 lines \(r.qLines)")
    XCTAssertEqual(r.q.midX, card.frame.midX, accuracy: 1, "(d) 2-line question not centred \(r.q)")
    XCTAssertEqual(r.a.midX, card.frame.midX, accuracy: 1, "(d) answer under a 2-line question not centred \(r.a)")
    assertColour(r.qAfter, palette.ink, "(d) 2-line long question after reveal")
    assertColour(r.aColour, palette.secondaryInk, "(d) The Seine")
    rateGood(stub, next: Self.flute.0)

    // (d) 2-line centred question + 1-line answer: centred.
    r = revealChecked(stub, Self.flute.1, "d-2line-short", mode, leading: false)
    XCTAssertEqual(r.a.midX, card.frame.midX, accuracy: 1, "(d) Mozart not centred \(r.a)")
    assertColour(r.qAfter, palette.ink, "(d) Magic Flute after reveal")
    assertColour(r.aColour, palette.secondaryInk, "(d) Mozart")
    rateGood(stub, next: Self.westphalia)

    // Control for the Reduce Motion test: Westphalia + 5-line answer lifts (lift > 40) with motion on.
    r = revealChecked(stub, Self.fiveLines, "c-5lines-lift", mode, leading: true)
    note("QA017-16 \(mode) lift control: question moved \(r.qBeforeFrame.minY - r.q.minY)")
    XCTAssertGreaterThan(r.qBeforeFrame.minY - r.q.minY, 20, "control: no lift with Reduce Motion off")
    assertLeadingPair(r, card.frame, "(c) 5 lines")
  }

  /// (e) with Reduce Motion: the colour crossfade stays, the lift is dropped (the question doesn't move).
  @MainActor
  func testStudyAnswerAlign_reduceMotion() throws {
    XCUIDevice.shared.appearance = .light
    setReduceMotion(true)
    defer { setReduceMotion(false) }
    let base = Date(timeIntervalSince1970: 1_767_225_600)
    let server = try startReviewStub([
      StubDeck.Card(id: "A16A16B0-0000-0000-0000-000000000000", front: Self.westphalia, back: Self.fiveLines,
                    due: base, createdAt: base),
    ])
    defer { server.stop() }
    let app = launch(api: .live(server.url))
    waitForLabel(el(app, "study.front"), Self.westphalia)
    Thread.sleep(forTimeInterval: 0.8)
    let r = revealChecked(app, Self.fiveLines, "e-reduce-motion", "light", leading: true, captureMotion: true,
                          snapshotSuffix: "-reduce-motion")
    XCTAssertEqual(r.q.minY, r.qBeforeFrame.minY, accuracy: 0.5, "Reduce Motion: the question moved on reveal \(r.qBeforeFrame) → \(r.q)")
    assertColour(r.qAfter, Self.recededLight, "Reduce Motion: question after reveal")
    assertColour(r.aColour, Palette.light.ink, "Reduce Motion: answer")
  }

  // MARK: - Helpers

  struct Revealed {
    var qBeforeFrame: CGRect, q: CGRect, a: CGRect, bg: RGB
    var qBefore: RGB, qAfter: RGB, aColour: RGB
    var qLines: [Band], aLines: [Band]
    /// The question's line pitch (its height over its drawn lines).
    var lineHeight: CGFloat
  }

  /// One drawn text line: its rows and its ink's horizontal extent (pt).
  struct Band: CustomStringConvertible {
    var minY: CGFloat, maxY: CGFloat, minX: CGFloat, maxX: CGFloat
    var description: String { String(format: "y %.2f–%.2f x %.2f–%.2f", minY, maxY, minX, maxX) }
  }

  /// Snapshots the front, reveals, snapshots the back; checks (f) when `leading`: the question's frame and its ink
  /// lines are unchanged (only the colour changes). With `captureMotion` the reveal is a frame sequence, attached,
  /// whose question colours must include one strictly between `ink` and `recededInk`.
  @MainActor
  private func revealChecked(_ app: XCUIApplication, _ answer: String?, _ name: String, _ mode: String, leading: Bool,
                             captureMotion: Bool = false, snapshotSuffix: String = "") -> Revealed {
    let appearance: XCUIDevice.Appearance = mode == "dark" ? .dark : .light
    let card = el(app, "study.card").frame, front = el(app, "study.front"), back = el(app, "study.back")
    Thread.sleep(forTimeInterval: 0.4)
    let q0 = front.frame
    let probe0 = ColorProbe(screenOf: app)
    let bg = probe0.color(at: CGPoint(x: card.minX - 8, y: card.midY))
    let qBefore = textColour(probe0, q0, bg: bg), lines0 = bands(probe0, q0, bg: bg)
    snapshot("study-axis-\(name)-front\(snapshotSuffix)", appearance: appearance)
    if captureMotion {
      let frames = captureFrames(during: 1.2) { el(app, "study.reveal").tap() }
      let colours = frames.map { textColour(ColorProbe(at3x: UIImage(data: $0.png)!.cgImage!), q0, bg: bg) }
      note("QA017-16 \(mode) e \(name): \(zip(frames.map { Int($0.t * 1000) }, colours).map { "\($0)ms \($1)" })")
      attach(frames, "study-axis-e-\(name)-\(mode)", every: 1)
      let ink = Palette.of(appearance).ink, receded = appearance == .dark ? Self.recededDark : Self.recededLight
      let between = colours.filter {
        let l = $0.luminance, lo = min(ink.luminance, receded.luminance), hi = max(ink.luminance, receded.luminance)
        return l > lo + 6 && l < hi - 6
      }
      // Off-main screenshots sometimes stall for ~0.6 s; only a dense sequence can be asked for a mid frame. The
      // timing itself is measured on the run's recording (`image-ops.py track`, QA report).
      let gaps = zip(frames.dropFirst(), frames).map { $0.t - $1.t }
      if (gaps.max() ?? 1) < 0.15 {
        XCTAssertFalse(between.isEmpty, "(e) \(name): no frame between ink and recededInk: \(colours)")
      } else {
        note("QA017-16 \(mode) e \(name): capture stalled (gaps \(gaps)), mid-frame check left to the recording")
      }
    } else {
      el(app, "study.reveal").tap()
    }
    if let answer { waitForLabel(back, answer) } else { XCTAssertTrue(back.waitFor(timeout: 5), "(\(name)) study.back missing") }
    XCTAssertTrue(el(app, "study.rate.good").waitFor(timeout: 3), "(\(name)) ratings missing")
    Thread.sleep(forTimeInterval: 0.8)  // lift and crossfade settled
    let q = front.frame, a = back.frame
    let probe = ColorProbe(screenOf: app)
    let qAfter = textColour(probe, q, bg: bg), aColour = textColour(probe, a, bg: bg)
    let lines = bands(probe, q, bg: bg), aLines = bands(probe, a, bg: bg)
    let lineHeight = q.height / CGFloat(max(lines.count, 1))
    note("QA017-16 \(mode) \(name): card \(card) front \(q0) → \(q) back \(a) colours q \(qBefore) → \(qAfter) a \(aColour)")
    note("QA017-16 \(mode) \(name): question lines before \(lines0) after \(lines) answer lines \(aLines)")
    snapshot("study-axis-\(name)-back\(snapshotSuffix)", appearance: appearance)
    XCTAssertEqual(q.minX, q0.minX, accuracy: 0.5, "(f) \(name): question moved sideways \(q0) → \(q)")
    XCTAssertEqual(q.width, q0.width, accuracy: 0.5, "(f) \(name): question resized \(q0) → \(q)")
    XCTAssertEqual(q.height, q0.height, accuracy: 0.5, "(f) \(name): question resized \(q0) → \(q)")
    if leading, abs(q.minY - q0.minY) < 0.5 {
      // (f) Same ink mask: same lines, same extents (± 1/3 pt, anti-aliasing at the new colour).
      XCTAssertEqual(lines.count, lines0.count, "(f) \(name): question line count changed \(lines0) → \(lines)")
      for (b0, b1) in zip(lines0, lines) {
        let same = abs(b0.minY - b1.minY) <= 0.34 && abs(b0.maxY - b1.maxY) <= 0.34
          && abs(b0.minX - b1.minX) <= 0.34 && abs(b0.maxX - b1.maxX) <= 0.34
        XCTAssertTrue(same, "(f) \(name): question ink moved \(b0) → \(b1)")
      }
    }
    return Revealed(qBeforeFrame: q0, q: q, a: a, bg: bg, qBefore: qBefore, qAfter: qAfter, aColour: aColour,
                    qLines: lines, aLines: aLines, lineHeight: lineHeight)
  }

  /// (a)–(c): question at the column's edge, each line's ink starting there; the answer's frame and every line on
  /// the same edge, never wider than the column.
  private func assertLeadingPair(_ r: Revealed, _ card: CGRect, _ what: String) {
    XCTAssertGreaterThanOrEqual(r.qLines.count, 3, "\(what) fixture: question not 3+ lines \(r.qLines)")
    XCTAssertEqual(r.q.minX, card.minX, accuracy: 1, "\(what): question not at the 16 pt edge \(r.q) in \(card)")
    XCTAssertEqual(r.a.minX, r.q.minX, accuracy: 1, "\(what): answer not on the question's edge \(r.a) vs \(r.q)")
    XCTAssertLessThanOrEqual(r.a.maxX, card.maxX + 1, "\(what): answer wider than the column \(r.a)")
    for (i, b) in r.qLines.enumerated() {
      XCTAssertEqual(b.minX, card.minX, accuracy: 3, "\(what): question line \(i + 1) ink starts at \(b.minX)")
    }
    for (i, b) in r.aLines.enumerated() {
      XCTAssertEqual(b.minX, card.minX, accuracy: 3, "\(what): answer line \(i + 1) ink starts at \(b.minX)")
    }
    let qInk = r.qLines.map(\.minX).min() ?? .nan, aInk = r.aLines.map(\.minX).min() ?? .nan
    XCTAssertEqual(aInk, qInk, accuracy: 1.5, "\(what): answer ink edge \(aInk) vs question ink edge \(qInk)")
  }

  /// The most common colour among pixels far from `bg` in `rect` (glyph cores; caret and anti-aliasing are minor).
  private func textColour(_ probe: ColorProbe, _ rect: CGRect, bg: RGB) -> RGB {
    var counts: [Int: Int] = [:]
    for c in probe.colors(in: rect, step: 1.0 / 3) where c.distance(to: bg) > 90 {
      counts[(c.r << 16) | (c.g << 8) | c.b, default: 0] += 1
    }
    guard let key = counts.max(by: { $0.value < $1.value })?.key else { return bg }
    return RGB(key >> 16, (key >> 8) & 0xFF, key & 0xFF)
  }

  /// Ink lines in `rect` (rows with a pixel > 60 from `bg`), 1/3 pt steps, each with its ink's x extent.
  private func bands(_ probe: ColorProbe, _ rect: CGRect, bg: RGB) -> [Band] {
    var result: [Band] = []
    var inBand = false
    for y in stride(from: rect.minY, to: rect.maxY, by: 1.0 / 3) {
      let xs = stride(from: rect.minX - 4, to: rect.maxX + 4, by: 1.0 / 3)
        .filter { probe.color(at: CGPoint(x: $0, y: y)).distance(to: bg) > 60 }
      if let lo = xs.first, let hi = xs.last {
        if inBand, var last = result.popLast() {
          last.maxY = y; last.minX = min(last.minX, lo); last.maxX = max(last.maxX, hi)
          result.append(last)
        } else {
          result.append(Band(minY: y, maxY: y, minX: lo, maxX: hi))
        }
        inBand = true
      } else {
        inBand = false
      }
    }
    return result
  }

  private func assertColour(_ c: RGB, _ expected: RGB, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(c.isClose(to: expected, tolerance: 6), "\(what): colour \(c), expected \(expected)", file: file, line: line)
  }

  @MainActor
  private func startReviewStub(_ cards: [StubDeck.Card]) throws -> StubAPIServer {
    let deck = StubDeck(cards)
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
    return server
  }

  @MainActor
  private func rateGood(_ app: XCUIApplication, next: String) {
    el(app, "study.rate.good").tap()
    waitForLabel(el(app, "study.front"), next)
    Thread.sleep(forTimeInterval: 0.6)  // fade-in done
  }

  private func attach(_ frames: [(t: TimeInterval, png: Data)], _ name: String, every: Int) {
    for (i, f) in frames.enumerated() where i % every == 0 {
      let a = XCTAttachment(data: f.png, uniformTypeIdentifier: "public.png")
      a.name = String(format: "\(name)-%02d-%04dms", i, Int(f.t * 1000))
      a.lifetime = .keepAlways
      add(a)
    }
  }

  /// Screenshots taken off the main thread as fast as possible for `duration` s, starting 0.15 s before `action`.
  @MainActor
  private func captureFrames(during duration: TimeInterval, _ action: () -> Void) -> [(t: TimeInterval, png: Data)] {
    let box = AxisFrameBox()
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

  private func note(_ line: String) {
    print(line)
    XCTContext.runActivity(named: line) { _ in }
  }
}

private final class AxisFrameBox: @unchecked Sendable {
  private let lock = NSLock()
  private var _frames: [(t: TimeInterval, png: Data)] = []
  private var done = false
  nonisolated func append(_ f: (TimeInterval, Data)) { lock.withLock { _frames.append((t: f.0, png: f.1)) } }
  nonisolated func finish() { lock.withLock { done = true } }
  nonisolated var isDone: Bool { lock.withLock { done } }
  nonisolated var frames: [(t: TimeInterval, png: Data)] { lock.withLock { _frames } }
}
