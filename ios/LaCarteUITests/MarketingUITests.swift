import XCTest

/// Marketing frames (owner: marketing, `docs/marketing/app-demo.md`). Not a validation suite: it drives a scripted
/// demo on the in-process stub deck (the demo deck of `marketing/demo-deck.json`, made-up person, placeholder photo
/// from `StubPhoto`) and attaches one screenshot per shot. `marketing/build-demo.py` turns them into the video.
///
///   UI_WORKERS=1 scripts/ios-ui-test.sh marketing -only-testing:LaCarteUITests/MarketingUITests
///
/// Shots are named `vNN-<what>-light` (video), `readme-<what>-<light|dark>` (README), `theme-<name>-light`,
/// `widget-due-<light|dark>`. No real server, token or person appears: the stub listens on 127.0.0.1 and no screen
/// that shows the URL (Settings) is captured.
final class MarketingUITests: XCTestCase {
  static let base = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01: due now

  override func setUp() {
    continueAfterFailure = false
  }

  // MARK: - Video: one continuous study session (light)

  @MainActor
  func testMarketing_1_videoSession() throws {
    XCUIDevice.shared.appearance = .light
    let (server, _) = try demoDeck(halcyonBack: "calm")
    let app = launch(api: .live(server.url), arguments: ["-aiApp", "copyOnly"])

    // Front, then the answer with the two buttons.
    waitForLabel(el(app, "study.front"), "petrichor")
    settle()
    snapshot("v01-front", appearance: .light)
    el(app, "study.reveal").tap()
    waitForLabel(el(app, "study.back"), "the smell of rain on dry earth")
    settle()
    snapshot("v02-reveal", appearance: .light)
    next(app)

    // Double-tap the answer to finish it in place.
    reveal(app, "halcyon", "calm")
    el(app, "study.back").doubleTap()
    let field = el(app, "study.backField")
    XCTAssertTrue(field.waitFor(timeout: 5), "no study.backField after double-tap")
    XCTAssertTrue(app.keyboards.firstMatch.waitFor(timeout: 5), "no keyboard")
    dismissKeyboardTip(app)
    settle(0.8)
    field.typeText(" and peaceful")
    settle()
    snapshot("v04-edit", appearance: .light)
    let done = app.keyboards.buttons.matching(NSPredicate(format: "label ==[c] 'done'")).firstMatch
    XCTAssertTrue(done.waitFor(timeout: 3), "keyboard has no Done key")
    done.tap()
    waitForLabel(el(app, "study.back"), "calm and peaceful")
    settle(0.8)
    snapshot("v05-edited", appearance: .light)
    next(app)

    // A person: photo → name + description.
    waitForLabel(el(app, "study.photo"), "Photo")
    settle()
    snapshot("v06-person-front", appearance: .light)
    el(app, "study.reveal").tap()
    XCTAssertTrue(app.staticTexts["Nora Vale"].waitFor(timeout: 5), "person answer missing")
    settle()
    snapshot("v07-person-back", appearance: .light)
    next(app)

    // Double-tap the card: the menu, then "Ask about this card" (copy only on the simulator).
    reveal(app, "Capital of Australia?", "Canberra")
    openMenu(app)
    snapshot("v08-menu", appearance: .light)
    menuButton(app, "ask", "Ask about this card").tap()
    waitForLabel(el(app, "study.reportNotice"), "Copied", timeout: 3)
    settle()
    snapshot("v09-copied", appearance: .light)
    waitForLabel(el(app, "study.remaining"), "5 to review", timeout: 5)
    next(app)

    // A wrong card (as an agent might write it): report it, it leaves the session.
    reveal(app, "Largest planet?", "Saturn")
    openMenu(app)
    snapshot("v10-report-menu", appearance: .light)
    menuButton(app, "wrong", "This is wrong").tap()
    waitForLabel(el(app, "study.reportNotice"), "Reported", timeout: 5)
    settle()
    snapshot("v11-reported", appearance: .light)
    app.terminate()
    server.stop()
  }

  // MARK: - Video: the drag ring (debug preview holds the drag at a fixed fraction of the card width)

  @MainActor
  func testMarketing_2_dragRing() throws {
    XCUIDevice.shared.appearance = .light
    for (name, f) in [("forgot", -0.3), ("gotit", 0.13), ("easy", 0.3)] {
      let (server, _) = try demoDeck()
      let app = launch(api: .live(server.url), arguments: ["-studySwipePreview", " \(f)"])
      reveal(app, "petrichor", "the smell of rain on dry earth")
      let ring = app.descendants(matching: .any)
        .matching(NSPredicate(format: "identifier == 'study.swipeRing' OR label == 'Rating'")).firstMatch
      XCTAssertTrue(ring.waitFor(timeout: 5), "no drag ring (\(name))")
      settle(0.8)
      snapshot("v03-ring-\(name)", appearance: .light)
      app.terminate()
      server.stop()
    }
  }

  // MARK: - Video: the three themes, and the widget

  @MainActor
  func testMarketing_3_themesAndWidget() throws {
    XCUIDevice.shared.appearance = .light
    for theme in ["light", "dark", "forest"] {
      let (server, _) = try demoDeck()
      let app = launch(api: .live(server.url), theme: theme)
      reveal(app, "petrichor", "the smell of rain on dry earth")
      settle()
      snapshot("theme-\(theme)", appearance: .light)
      app.terminate()
      server.stop()
    }
    for appearance in [XCUIDevice.Appearance.light, .dark] {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .mock, screen: "widget")
      let tile = el(app, "widgetGallery.tile.small.nine")
      XCTAssertTrue(tile.waitFor(timeout: 10), "no widget tile")
      settle()
      let attachment = XCTAttachment(screenshot: tile.screenshot())
      attachment.name = "widget-small-nine-\(appearance == .dark ? "dark" : "light")"
      attachment.lifetime = .keepAlways
      add(attachment)
      app.terminate()
    }
  }

  // MARK: - README: the same four screens in light and dark

  @MainActor
  func testMarketing_4_readme() throws {
    for appearance in [XCUIDevice.Appearance.light, .dark] {
      XCUIDevice.shared.appearance = appearance
      let (server, _) = try demoDeck()
      let app = launch(api: .live(server.url))
      waitForLabel(el(app, "study.front"), "petrichor")
      settle()
      snapshot("readme-1-front", appearance: appearance)
      el(app, "study.reveal").tap()
      waitForLabel(el(app, "study.back"), "the smell of rain on dry earth")
      settle()
      snapshot("readme-2-reveal", appearance: appearance)
      next(app)
      next(app, reveal: "halcyon")
      waitForLabel(el(app, "study.photo"), "Photo")
      el(app, "study.reveal").tap()
      XCTAssertTrue(app.staticTexts["Nora Vale"].waitFor(timeout: 5), "person answer missing")
      settle()
      snapshot("readme-3-person", appearance: appearance)
      el(app, "study.deck").tap()
      waitForDeckTitle(app)
      settle(1)
      snapshot("readme-4-deck", appearance: appearance)
      app.terminate()
      server.stop()
    }
  }

  // MARK: - Demo deck (marketing/demo-deck.json, in study order) + one made-up person

  /// Due cards in this order: petrichor, halcyon, the person, Capital of Australia?, Largest planet? (deliberately
  /// wrong: "Saturn", to be reported), luminous, Au, mellifluous = "8 to review". The rest are reviewed, due later.
  private func demoDeck(halcyonBack: String = "calm and peaceful") throws -> (StubAPIServer, StubDeck) {
    let server = StubAPIServer()
    try server.start()  // first: the photo URL needs its port
    let due: [(String, String)] = [
      ("petrichor", "the smell of rain on dry earth"), ("halcyon", halcyonBack), ("", ""),
      ("Capital of Australia?", "Canberra"), ("Largest planet?", "Saturn"), ("luminous", "full of light"),
      ("Au", "gold"), ("mellifluous", "sweet-sounding"),
    ]
    var cards: [StubDeck.Card] = []
    var notes: [StubDeck.Note] = []
    for (i, (front, back)) in due.enumerated() {
      let at = Self.base.addingTimeInterval(Double(i) * 60)
      if front.isEmpty {
        notes.append(.init(type: "person", fields: [
          "photo": server.url + "/photos/nora.png", "name": "Nora Vale", "description": "runs the corner bakery"],
          cards: [.init(prompt: ["photo"], answer: ["name", "description"], due: at)], createdAt: at))
      } else {
        cards.append(.init(id: UUID().uuidString.lowercased(), front: front, back: back, due: at, createdAt: at))
      }
    }
    let later: [(String, String, Double)] = [
      ("ubiquitous", "found everywhere", 3), ("candor", "honesty", 5), ("laconic", "using few words", 2),
      ("wistful", "gently longing", 9), ("ineffable", "too great for words", 4), ("Largest ocean?", "Pacific", 12),
    ]
    for (i, (front, back, days)) in later.enumerated() {
      cards.append(.init(id: UUID().uuidString.lowercased(), front: front, back: back, state: "review",
                         due: Date().addingTimeInterval(days * 86_400),
                         createdAt: Self.base.addingTimeInterval(Double(i) * 30)))
    }
    let deck = StubDeck(cards, notes: notes)
    server.handler = deck.handle
    return (server, deck)
  }

  // MARK: - Helpers

  /// Lets animations finish so the frame is at rest.
  private func settle(_ seconds: TimeInterval = 0.6) { Thread.sleep(forTimeInterval: seconds) }

  @MainActor
  private func reveal(_ app: XCUIApplication, _ front: String, _ back: String) {
    waitForLabel(el(app, "study.front"), front)
    el(app, "study.reveal").tap()
    waitForLabel(el(app, "study.back"), back)
    settle()
  }

  /// "Got it" on the current card (revealing it first when `reveal` names its front), then waits for the next one.
  @MainActor
  private func next(_ app: XCUIApplication, reveal front: String? = nil) {
    if let front {
      waitForLabel(el(app, "study.front"), front)
      el(app, "study.reveal").tap()
    }
    let good = el(app, "study.rate.good")
    XCTAssertTrue(good.waitFor(timeout: 5), "no Got it button")
    good.tap()
    XCTAssertTrue(el(app, "study.reveal").waitFor(timeout: 10), "no next card")
    settle(0.8)
  }

  /// Double-taps the revealed card clear of its text (spec 015b) and waits for the menu.
  @MainActor
  private func openMenu(_ app: XCUIApplication) {
    el(app, "study.card").coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.08)).doubleTap()
    XCTAssertTrue(menuButton(app, "ask", "Ask about this card").waitFor(timeout: 5), "no menu after double-tap")
    settle(0.8)
  }

  @MainActor
  private func menuButton(_ app: XCUIApplication, _ id: String, _ title: String) -> XCUIElement {
    let byID = el(app, "study.report.\(id)")
    return byID.exists ? byID : app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
  }
}
