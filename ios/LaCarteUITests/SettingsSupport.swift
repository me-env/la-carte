import XCTest

/// Shared by `SettingsUITests` and `SetupUITests` (separate classes so parallel workers can split them): stub
/// server with a token guard, Settings navigation and text-field helpers. Holds no tests.
class SettingsTestCase: XCTestCase {
  static let urlPlaceholder = "Server URL"
  static let goodToken = "qa-good-token"

  override func setUp() {
    continueAfterFailure = false
  }

  func uuid(_ suffix: String) -> String {
    "00000000-0000-0000-0000-" + String(repeating: "0", count: 12 - suffix.count) + suffix.uppercased()
  }

  func card(_ id: String, _ front: String, _ back: String) -> StubDeck.Card {
    .init(id: uuid(id), front: front, back: back)
  }

  /// Wraps a stub deck: any request without `Bearer <token>` gets a 401 (like the API); `/stats` can be slow.
  static func guarded(_ deck: StubDeck, token: String, statsDelay: TimeInterval)
    -> @Sendable (StubAPIServer.Request) -> StubAPIServer.Response {
    { request in
      guard request.headers["authorization"] == "Bearer \(token)" else {
        return .init(status: 401, body: #"{"detail":"Invalid token"}"#)
      }
      var response = deck.handle(request)
      if StubDeck.route(request.path) == "/stats" { response.delay = statsDelay }
      return response
    }
  }

  func startStub(_ deck: StubDeck, token: String, statsDelay: TimeInterval = 0) throws -> StubAPIServer {
    let server = StubAPIServer(handler: Self.guarded(deck, token: token, statsDelay: statsDelay))
    try server.start()
    return server
  }

  @MainActor
  func openDeck(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let button = el(app, "study.deck")
    XCTAssertTrue(button.waitFor(timeout: 10), "study.deck missing", file: file, line: line)
    button.tap()
    waitForLabel(el(app, "deck.title"), "Cards", file: file, line: line)
  }

  @MainActor
  func openSettings(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let gear = el(app, "deck.settings")
    XCTAssertTrue(gear.waitFor(timeout: 5), "deck.settings missing", file: file, line: line)
    gear.tap()
    waitForLabel(el(app, "settings.title"), "Settings", file: file, line: line)
  }

  @MainActor
  func statusText(_ app: XCUIApplication) -> XCUIElement { el(app, "settings.status") }

  @MainActor
  func assertStatusCleared(_ app: XCUIApplication, _ context: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
    let status = statusText(app)
    waitUntil("settings.status cleared \(context)", timeout: 3, file: file, line: line) {
      !status.exists || status.label.isEmpty
    }
  }

  /// Text of a settings field, or "" when it only shows its placeholder.
  @MainActor
  func fieldText(_ app: XCUIApplication, _ id: String) -> String {
    let field = el(app, id)
    let value = field.value as? String ?? ""
    return value == field.placeholderValue || value == Self.urlPlaceholder || value == "Token" ? "" : value
  }

  /// No element label or value contains `token` in clear.
  @MainActor
  func assertTokenNotOnScreen(_ app: XCUIApplication, _ token: String, file: StaticString = #filePath, line: UInt = #line) {
    let clear = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", token, token))
    XCTAssertEqual(clear.count, 0, "token shown in clear", file: file, line: line)
  }

  @MainActor
  func hasFocus(_ element: XCUIElement) -> Bool {
    (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
  }

  /// Taps right of the (short) text so the cursor lands at its end. Not at the far right edge: the last ~10pt of
  /// the row don't focus the field (see report).
  @MainActor
  func tapEnd(_ field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
    field.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
    waitUntil("\(field.identifier) focused", timeout: 5, file: file, line: line) { self.hasFocus(field) }
  }

  /// Replaces a field's text: cursor at the end, delete everything, type `text`.
  @MainActor
  func setText(_ app: XCUIApplication, _ id: String, _ text: String, secure: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) {
    let field = el(app, id)
    XCTAssertTrue(field.waitFor(timeout: 5), "\(id) missing", file: file, line: line)
    let old = fieldText(app, id)
    tapEnd(field, file: file, line: line)
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 2) + text)
    if secure {
      XCTAssertEqual(fieldText(app, id).count, text.count, "\(id) length after typing", file: file, line: line)
    } else {
      XCTAssertEqual(fieldText(app, id), text, "\(id) text after typing", file: file, line: line)
    }
  }

  @MainActor
  func waitUntil(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                         _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
    XCTAssertTrue(condition(), "timed out waiting for: \(what)", file: file, line: line)
  }
}
