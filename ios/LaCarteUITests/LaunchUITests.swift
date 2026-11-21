import XCTest

/// Launch stability: the corner buttons must be where they belong on the first frame, not jump there.
/// Other suites wait for elements and screenshot after layout has settled, so they can't see a first-frame jump.
final class LaunchUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testLaunch_studyFront_cornerButtonsDontMove() {
    assertCornerButtonsStable(launch(api: .mock))
  }

  @MainActor
  func testLaunch_caughtUp_cornerButtonsDontMove() throws {
    let deck = StubDeck([])
    let server = StubAPIServer(handler: deck.handle)
    try server.start()
    defer { server.stop() }
    assertCornerButtonsStable(launch(api: .live(server.url)))
  }

  @MainActor
  func testLaunch_offline_cornerButtonsDontMove() {
    assertCornerButtonsStable(launch(api: .live(unreachableAPIURL)))
  }

  /// Rating the last card swaps the content for "All caught up": the top bar must stay put, also in between,
  /// while the due cards and stats load (slow reads here, so that gap is long enough to sample).
  @MainActor
  func testLastCardToCaughtUp_cornerButtonsDontMove() throws {
    let deck = StubDeck([.init(id: "aaaaaaaa-0000-0000-0000-000000000001", front: "gratitude", back: "thank you")])
    let server = StubAPIServer(handler: deck.handle)
    try server.start()
    defer { server.stop() }
    let app = launch(api: .live(server.url))
    let deckButton = el(app, "study.deck")
    let add = el(app, "study.add")
    waitForLabel(el(app, "study.remaining"), "1 to review")
    el(app, "study.reveal").tap()
    XCTAssertTrue(el(app, "study.rate.good").waitFor(timeout: 5), "study.rate.good missing")
    let studying = (deck: deckButton.frame, add: add.frame)

    deck.readDelay = 2
    el(app, "study.rate.good").tap()
    var samples = [(deck: deckButton.frame, add: add.frame)]
    let caughtUp = el(app, "study.message")
    while !caughtUp.exists, samples.count < 40 {
      samples.append((deck: deckButton.frame, add: add.frame))
    }
    waitForLabel(caughtUp, "All caught up")
    _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: 1)
    samples.append((deck: deckButton.frame, add: add.frame))

    for sample in samples {
      for (name, a, b) in [("study.deck", studying.deck, sample.deck), ("study.add", studying.add, sample.add)] {
        XCTAssertEqual(a.minX, b.minX, accuracy: 1, "\(name) moved: \(a) → \(b)")
        XCTAssertEqual(a.minY, b.minY, accuracy: 1, "\(name) moved: \(a) → \(b)")
      }
    }
  }

  /// Reads the buttons' frames as soon as they exist, then after 1 s: they must match within 1 pt.
  @MainActor
  private func assertCornerButtonsStable(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let deck = el(app, "study.deck")
    let add = el(app, "study.add")
    XCTAssertTrue(deck.waitFor(timeout: 10), "study.deck missing", file: file, line: line)
    let early = (deck: deck.frame, add: add.frame)
    _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: 1)
    let settled = (deck: deck.frame, add: add.frame)
    let window = app.windows.firstMatch.frame
    for (name, a, b) in [("study.deck", early.deck, settled.deck), ("study.add", early.add, settled.add)] {
      XCTAssertEqual(a.minX, b.minX, accuracy: 1, "\(name) moved: \(a) → \(b) (window \(window))", file: file, line: line)
      XCTAssertEqual(a.minY, b.minY, accuracy: 1, "\(name) moved: \(a) → \(b) (window \(window))", file: file, line: line)
    }
    XCTAssertGreaterThanOrEqual(settled.deck.minX, window.minX + 8, "study.deck has no margin", file: file, line: line)
    XCTAssertLessThanOrEqual(settled.add.maxX, window.maxX - 8, "study.add has no margin", file: file, line: line)
  }
}
