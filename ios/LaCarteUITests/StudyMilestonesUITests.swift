import XCTest

/// Spec 021: the milestone ladder on Study (counter button, milestones popover, step notices), AC 20–24.
/// Mock deck = `LA_CARTE_API=mock` (3 basic cards: serendipity, la carte, ephemeral) with the ladder seeded by
/// `LA_CARTE_STARTED` / `LA_CARTE_AT_RISK` / `LA_CARTE_MILESTONE` / `LA_CARTE_NEW_TODAY`.
/// Each flow runs in light, dark and forest (forest forces the dark scheme); screenshots are `<name>-<look>`.
final class StudyMilestonesUITests: XCTestCase {
  /// Device appearance + `-theme` value, and the screenshot suffix.
  static let looks: [(appearance: XCUIDevice.Appearance, theme: String, name: String)] = [
    (.light, "system", "light"), (.dark, "system", "dark"), (.light, "forest", "forest"),
  ]
  /// Step notices stay 5 s instead of 2 s (debug-only `-noticeSeconds`), so each one is caught and photographed.
  static let noticeArguments = ["-noticeSeconds", "5"]
  static let rowIds = ["atRisk", "reviews", "newDone", "new"].map { "study.milestone.\($0)" }

  override func setUp() {
    continueAfterFailure = false
  }

  /// AC 20 + 23 + 24: at risk → reviews → new → caught up, with a notice at each finished step.
  @MainActor
  func testStudyMilestones_atRiskLadder() {
    for look in Self.looks {
      XCUIDevice.shared.appearance = look.appearance
      let app = launch(api: .mock, arguments: Self.noticeArguments, theme: look.theme,
                       environment: ["LA_CARTE_STARTED": "2", "LA_CARTE_AT_RISK": "1", "LA_CARTE_MILESTONE": "1"])

      // Start: "1 at risk", popover "At risk 0/1" only.
      waitForCounter(app, "1 at risk")
      assertCounterIsButton(app)
      shot("study-counter-atrisk", look.name)
      openMilestones(app, rows: ["study.milestone.atRisk": "At risk, 0 of 1"])
      shot("study-milestones-atrisk", look.name)
      closeMilestones(app)

      // Rate the at-risk card → "At risk done", then "1 to review", popover At risk ✓ + Reviews 1/2.
      rateGood(app)
      assertNotice(app, "At risk done")
      shot("study-milestone-notice", look.name)
      waitForCounter(app, "1 to review", timeout: 10)
      openMilestones(app, rows: ["study.milestone.atRisk": "At risk, done",
                                 "study.milestone.reviews": "Reviews, 1 of 2"])
      shot("study-milestones-reviews", look.name)
      closeMilestones(app)

      // Rate the last review → "Reviews done", then "1 new", popover At risk ✓, Reviews ✓, 1 new 0/1.
      rateGood(app)
      assertNotice(app, "Reviews done")
      shot("study-milestone-notice-reviews", look.name)
      waitForCounter(app, "1 new", timeout: 10)
      openMilestones(app, rows: ["study.milestone.atRisk": "At risk, done",
                                 "study.milestone.reviews": "Reviews, done",
                                 "study.milestone.new": "1 new, 0 of 1"])
      shot("study-milestones-new", look.name)
      closeMilestones(app)

      // Rate the new card → "1 new done" over the caught-up screen.
      rateGood(app)
      assertNotice(app, "1 new done")
      waitForLabel(el(app, "study.message"), "All caught up")
      shot("study-milestone-notice-caughtup", look.name)
      app.terminate()
    }
  }

  /// AC 21: a normal day (one started review, no at-risk step): "1 to review", one row "Reviews 0/1".
  @MainActor
  func testStudyMilestones_normalDay() {
    for look in Self.looks {
      XCUIDevice.shared.appearance = look.appearance
      let app = launch(api: .mock, theme: look.theme, environment: ["LA_CARTE_STARTED": "1"])
      waitForCounter(app, "1 to review")
      assertCounterIsButton(app)
      openMilestones(app, rows: ["study.milestone.reviews": "Reviews, 0 of 1"])
      shot("study-milestones-normal", look.name)
      closeMilestones(app)
      app.terminate()
    }
  }

  /// AC 22: many new (M 2, 4 already introduced today, 3 waiting): "2 new"; popover "4 new" ✓ then "6 new 4/6".
  @MainActor
  func testStudyMilestones_manyNew() {
    for look in Self.looks {
      XCUIDevice.shared.appearance = look.appearance
      let app = launch(api: .mock, theme: look.theme,
                       environment: ["LA_CARTE_MILESTONE": "2", "LA_CARTE_NEW_TODAY": "4"])
      waitForCounter(app, "2 new")
      openMilestones(app, rows: ["study.milestone.newDone": "4 new, done",
                                 "study.milestone.new": "6 new, 4 of 6"])
      let newDone = el(app, "study.milestone.newDone").frame, next = el(app, "study.milestone.new").frame
      XCTAssertLessThan(newDone.midY, next.midY, "'4 new' ✓ not above '6 new 4/6': \(newDone) / \(next)")
      shot("study-milestones-many", look.name)
      closeMilestones(app)
      app.terminate()
    }
  }

  // MARK: - Live API (spec 021, implementation order step 3)

  /// The real `/stats` carries the four ladder counts, and the app shows the ladder they describe: scripts/e2e.sh
  /// seeds two new cards (greeting, gratitude), so there is no at-risk or reviews step and the counter is "2 new".
  /// Reads only (opens and closes the popover), so the deck stays as seeded for the later live tests.
  @MainActor
  func testStudyMilestones_ladderFromStats_liveAPI() throws {
    guard let url = ProcessInfo.processInfo.environment["LA_CARTE_API_URL"], !url.isEmpty else {
      throw XCTSkip("LA_CARTE_API_URL not set — run scripts/e2e.sh")
    }
    let stats = try getJSON(url + "/stats")
    for key in ["at_risk_total", "at_risk_done", "reviews_total", "reviews_done", "new_today", "milestone", "due_new"] {
      XCTAssertNotNil(stats[key] as? Int, "/stats lacks \(key): \(stats)")
    }
    XCTAssertEqual(stats["at_risk_total"] as? Int, 0, "\(stats)")
    XCTAssertEqual(stats["reviews_total"] as? Int, 0, "\(stats)")
    XCTAssertEqual(stats["milestone"] as? Int, 15, "\(stats)")
    XCTAssertEqual(stats["due_new"] as? Int, 2, "\(stats)")

    XCUIDevice.shared.appearance = .light
    let app = launch(api: .live(url))
    waitForCounter(app, "2 new")
    assertCounterIsButton(app)
    openMilestones(app, rows: ["study.milestone.new": "15 new, 0 of 15"])
    snapshot("study-milestones-live", appearance: .light)
    closeMilestones(app)
  }

  // MARK: - Helpers

  /// AC 23: a button labelled "Milestones" (its value is the counter text, checked by `waitForCounter`).
  @MainActor
  private func assertCounterIsButton(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    let counter = el(app, "study.remaining")
    XCTAssertEqual(counter.elementType, .button, "study.remaining is not a button", file: file, line: line)
    XCTAssertEqual(counter.label, "Milestones", file: file, line: line)
    XCTAssertTrue(counter.isHittable, "study.remaining not hittable", file: file, line: line)
    XCTAssertGreaterThanOrEqual(counter.frame.height, 43.5, "counter under 44 pt: \(counter.frame)", file: file, line: line)
    XCTAssertEqual(counter.frame.midY, el(app, "study.deck").frame.midY, accuracy: 2,
                   "counter not on the corner-button line", file: file, line: line)
  }

  /// Taps the counter, waits for the popover and checks it holds exactly `rows` (id → accessibility label), in
  /// ladder order, and nothing else: no title, no button, no other text (AC 23).
  @MainActor
  private func openMilestones(_ app: XCUIApplication, rows: [String: String],
                              file: StaticString = #filePath, line: UInt = #line) {
    el(app, "study.remaining").tap()
    let popover = el(app, "study.milestones")
    XCTAssertTrue(popover.waitFor(timeout: 5), "study.milestones did not open", file: file, line: line)
    for (id, label) in rows {
      waitForLabel(el(app, id), label, timeout: 5, file: file, line: line)
      XCTAssertTrue(popover.frame.contains(el(app, id).frame), "\(id) outside the popover", file: file, line: line)
    }
    for id in Self.rowIds where rows[id] == nil {
      XCTAssertFalse(el(app, id).exists, "\(id) shown, expected only \(rows.keys.sorted())", file: file, line: line)
    }
    let shown = Self.rowIds.filter { rows[$0] != nil }.map { el(app, $0).frame.minY }
    XCTAssertEqual(shown, shown.sorted(), "rows not in ladder order", file: file, line: line)
    XCTAssertEqual(popover.buttons.count, 0, "button inside the popover", file: file, line: line)
    // A row's own texts (label, "done/total") are inside its frame; anything else is a stray title or sentence.
    let rowFrames = Self.rowIds.filter { rows[$0] != nil }.map { el(app, $0).frame.insetBy(dx: -1, dy: -1) }
    let strays = popover.staticTexts.allElementsBoundByIndex.filter { text in
      !rowFrames.contains { $0.contains(text.frame) }
    }
    XCTAssertTrue(strays.isEmpty, "text besides the rows: \(strays.map(\.label))", file: file, line: line)
    // The popover hangs below the counter (arrow edge top).
    XCTAssertGreaterThan(popover.frame.minY, el(app, "study.remaining").frame.midY,
                         "popover not below the counter: \(popover.frame)", file: file, line: line)
    _ = poll(timeout: 1) { false }  // let the presentation settle before a screenshot
  }

  /// A tap outside dismisses the popover and doesn't reach the card underneath.
  @MainActor
  private func closeMilestones(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
    waitForAbsence(el(app, "study.milestones"), "popover still open after a tap outside", file: file, line: line)
    XCTAssertFalse(el(app, "study.back").exists, "the tap that closed the popover revealed the card",
                   file: file, line: line)
  }

  @MainActor
  private func rateGood(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(el(app, "study.reveal").waitFor(timeout: 5), "study.reveal missing", file: file, line: line)
    el(app, "study.card").tap()
    let good = el(app, "study.rate.good")
    XCTAssertTrue(good.waitFor(timeout: 5), "study.rate.good missing", file: file, line: line)
    good.tap()
  }

  /// The step notice (`study.milestoneNotice`) shows `text`; the counter is hidden meanwhile.
  @MainActor
  private func assertNotice(_ app: XCUIApplication, _ text: String,
                            file: StaticString = #filePath, line: UInt = #line) {
    waitForLabel(el(app, "study.milestoneNotice"), text, timeout: 5, file: file, line: line)
    XCTAssertFalse(el(app, "study.remaining").exists, "counter shown with the notice", file: file, line: line)
    _ = poll(timeout: 0.6) { false }  // past the notice's fade-in
  }

  /// Full-screen screenshot named `<name>-<light|dark|forest>`, kept when the test passes.
  @MainActor
  private func shot(_ name: String, _ look: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "\(name)-\(look)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func getJSON(_ url: String) throws -> [String: Any] {
    var request = URLRequest(url: URL(string: url)!)
    if let token = ProcessInfo.processInfo.environment["LA_CARTE_API_TOKEN"] {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    var result: Data?
    let done = expectation(description: "GET \(url)")
    URLSession.shared.dataTask(with: request) { data, _, _ in
      result = data
      done.fulfill()
    }.resume()
    wait(for: [done], timeout: 10)
    let data = try XCTUnwrap(result, "no response from \(url)")
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
