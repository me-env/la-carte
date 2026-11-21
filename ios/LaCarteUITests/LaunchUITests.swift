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

  /// Reads the buttons' frames as soon as they exist, then after 1 s: they must match within 1 pt.
  @MainActor
  private func assertCornerButtonsStable(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let deck = el(app, "study.deck")
    let add = el(app, "study.add")
    XCTAssertTrue(deck.waitForExistence(timeout: 10), "study.deck missing", file: file, line: line)
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
