import XCTest

/// Specs 015b (report a card from the double-tap menu, broken_photo auto-report) and 016a (ask about this card:
/// copy the card as text, "Copied" notice). Mock = `LA_CARTE_API=mock` (serendipity first). Stub = `StubAPIServer` +
/// `StubDeck`, which records each `POST /cards/{id}/report` and then holds that card out of `/cards/due`.
/// "Double-tap the card" = on `study.card` at normalized (0.08, 0.08), clear of the text (spec 015b).
final class ReportUITests: XCTestCase {
  static let appearances: [XCUIDevice.Appearance] = [.light, .dark]
  static let front = "serendipity"
  static let back = "finding something good without looking for it"
  static let base = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01: due now
  /// Menu order (016a #1): Ask first, then the five reasons of 015b. Ids and the titles the spec gives them.
  static let menu: [(id: String, title: String)] = [
    ("ask", "Ask about this card"), ("wrong", "This is wrong"), ("drop", "I don't want this card"),
    ("doubt", "I doubt this is correct"), ("rephrase", "I want it phrased differently"), ("other", "Other…"),
  ]

  override func setUp() {
    continueAfterFailure = false
  }

  // MARK: - Menu (015b #1, #4; 016a #1)

  /// 015b #1 / 016a #1 (light, dark, forest): double-tapping the revealed card outside the text opens the menu with no
  /// title: Ask, then the five reasons in order, all the same height, below the answer, with the screen behind dimmed
  /// (audit 2026-11-22 P0-1/2/3).
  /// #4: dismissing it closes it, the card stays revealed, nothing changes.
  @MainActor
  func testReport_menuOpensAndCancels() {
    let looks: [(appearance: XCUIDevice.Appearance, theme: String, name: String)] = [
      (.light, "system", ""), (.dark, "system", ""), (.light, "forest", "-forest"),
    ]
    for (appearance, theme, name) in looks {
      XCUIDevice.shared.appearance = appearance
      let app = launch(api: .mock, theme: theme)
      reveal(app)
      // Audit P0-3: the menu dims what's behind it. Probe the page left of the card, above the sheet.
      let behind = CGPoint(x: 3, y: app.windows.firstMatch.frame.height * 0.2)
      let undimmed = ColorProbe(screenOf: app).color(at: behind)
      openMenu(app)
      let dimmed = ColorProbe(screenOf: app).color(at: behind)
      XCTAssertLessThan(dimmed.luminance, undimmed.luminance - (appearance == .dark || theme == "forest" ? 3 : 20),
                        "nothing dims behind the menu: \(undimmed) -> \(dimmed)")
      for item in Self.menu {
        XCTAssertTrue(el(app, "study.report.\(item.id)").exists, "dialog button '\(item.title)' has no study.report.\(item.id) id")
      }
      let buttons = Self.menu.map { menuButton(app, $0.id, $0.title) }
      for (button, item) in zip(buttons, Self.menu) {
        XCTAssertTrue(button.exists, "menu has no '\(item.title)'")
        XCTAssertEqual(button.label, item.title, "study.report.\(item.id) title")
      }
      let ys = buttons.map(\.frame.midY)
      XCTAssertEqual(ys, ys.sorted(), "menu order: \(zip(Self.menu.map(\.id), ys).map { "\($0)=\($1)" })")
      let heights = buttons.map(\.frame.height)
      XCTAssertEqual(heights.max()! - heights.min()!, 0, accuracy: 1, "menu items differ in height: \(heights)")
      XCTAssertLessThanOrEqual(el(app, "study.back").frame.maxY, buttons[0].frame.minY,
                               "the menu covers the answer")
      XCTAssertFalse(app.staticTexts["Report this card"].exists, "dialog still has the title 'Report this card' (016 #5)")
      XCTAssertFalse(app.buttons["Broken photo"].exists || el(app, "study.report.broken_photo").exists,
                     "menu offers broken_photo")
      snapshot("study-report-menu\(name)", appearance: appearance)
      snapshot("study-ask-menu\(name)", appearance: appearance)

      cancelMenu(app)
      waitForAbsence(buttons[1], "dialog still shown after Cancel")
      waitForLabel(el(app, "study.back"), Self.back)
      assertRatingsEnabled(app)
      waitForLabel(el(app, "study.remaining"), "3 to review")
      app.terminate()
    }
  }

  // MARK: - Gestures (015b #2)

  /// 015b #2 (regression of 010 #1, #3): an unrevealed card's double tap only reveals; a double tap on the revealed
  /// back text opens the inline editor, not the dialog.
  @MainActor
  func testReport_doubleTapTextStillEdits() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock)
    waitForLabel(el(app, "study.front"), Self.front)
    el(app, "study.card").coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.08)).doubleTap()
    waitForLabel(el(app, "study.back"), Self.back)
    Thread.sleep(forTimeInterval: 1)
    XCTAssertFalse(menuButton(app, "wrong", "This is wrong").exists, "double tap on an unrevealed card opened the menu")

    el(app, "study.back").doubleTap()
    XCTAssertTrue(el(app, "study.backField").waitFor(timeout: 5), "double tap on study.back opened no editor")
    Thread.sleep(forTimeInterval: 1)
    XCTAssertFalse(menuButton(app, "wrong", "This is wrong").exists, "double tap on the text opened the menu")
    snapshot("study-report-doubletap-text", appearance: .light)
    app.terminate()
  }

  // MARK: - Reasons (015b #5, #6, #7, #8)

  /// 015b #5–#8 (stub): each of the four reasons sends its `reason` with no `comment` key; the card leaves at once,
  /// the next one shows unrevealed, "Reported" takes the counter slot, then the count comes back. "Other…" opens the
  /// "What's wrong?" alert right after the menu: Report is disabled while blank, Cancel sends nothing, the trimmed
  /// comment is sent. The last card reported → "All caught up".
  @MainActor
  func testReport_eachReasonSent() throws {
    XCUIDevice.shared.appearance = .light
    let words = ["alpha", "bravo", "charlie", "delta", "echo"]
    let cards = words.enumerated().map { i, w in
      StubDeck.Card(id: "aaaaaaaa-0000-0000-0000-00000000000\(i + 1)", front: w, back: "\(w) back",
                    due: Self.base.addingTimeInterval(Double(i) * 60))
    }
    let (server, deck) = try stub(cards)
    let app = launch(api: .live(server.url))

    for (i, reason) in ["wrong", "drop", "doubt", "rephrase"].enumerated() {
      reveal(app, front: words[i], back: "\(words[i]) back")
      openMenu(app)
      menuButton(app, reason, Self.menu.first { $0.id == reason }!.title).tap()
      waitForLabel(el(app, "study.reportNotice"), "Reported", timeout: 5)
      XCTAssertEqual(el(app, "study.reportNotice").frame.midX, app.windows.firstMatch.frame.midX, accuracy: 1,
                     "notice not centered in the counter slot")
      Thread.sleep(forTimeInterval: 0.5)  // counter cross-fade (Theme.Motion.standard) settled
      if i == 0 { snapshot("study-reported", appearance: .light) }
      waitForLabel(el(app, "study.front"), words[i + 1])
      XCTAssertFalse(el(app, "study.back").exists, "next card shown revealed after a report")
      let report = try XCTUnwrap(deck.reports.last, "no POST /cards/{id}/report for \(reason)")
      XCTAssertEqual(deck.reports.count, i + 1, "reports: \(deck.reports)")
      XCTAssertEqual(report.cardID, cards[i].id, "reported the wrong card")
      XCTAssertEqual(report.reason, reason)
      XCTAssertFalse(report.hasCommentKey, "\(reason) body has a comment key")
      // The notice lasts about 2 s, then the counter (decremented) comes back.
      waitForLabel(el(app, "study.remaining"), "\(4 - i) to review", timeout: 4)
    }

    // Other…: alert straight after the menu, Cancel sends nothing.
    reveal(app, front: "echo", back: "echo back")
    openMenu(app)
    menuButton(app, "other", "Other…").tap()
    // The id the spec asks for; the flow goes on with the alert's only text field so the rest is still checked,
    // and the missing id fails the test at the end.
    XCTAssertTrue(app.alerts.firstMatch.waitFor(timeout: 5), "no alert after Other…")
    let commentHasID = el(app, "study.report.comment").waitFor(timeout: 2)
    let comment = commentHasID ? el(app, "study.report.comment") : app.alerts.textFields.firstMatch
    XCTAssertTrue(comment.waitFor(timeout: 3), "no text field in the alert")
    XCTAssertTrue(app.alerts["What's wrong?"].exists, "alert title isn't \"What's wrong?\"")
    let send = el(app, "study.report.send")
    XCTAssertFalse(send.isEnabled, "Report enabled with an empty comment")
    comment.tap()
    comment.typeText("   ")
    XCTAssertFalse(send.isEnabled, "Report enabled with a blank comment")
    snapshot("study-report-other", appearance: .light)
    app.alerts.buttons["Cancel"].tap()
    waitForAbsence(comment, "alert still shown after Cancel")
    waitForLabel(el(app, "study.back"), "echo back")
    XCTAssertEqual(deck.reports.count, 4, "Cancel sent a report")

    openMenu(app)
    menuButton(app, "other", "Other…").tap()
    XCTAssertTrue(comment.waitFor(timeout: 3), "no study.report.comment on the second Other…")
    comment.tap()
    comment.typeText(" typo in the answer ")
    XCTAssertTrue(send.isEnabled, "Report disabled with a comment")
    send.tap()
    XCTAssertTrue(poll(timeout: 5) { deck.reports.count == 5 }, "no report for Other…")
    let other = try XCTUnwrap(deck.reports.last)
    XCTAssertEqual(other.cardID, cards[4].id)
    XCTAssertEqual(other.reason, "other")
    XCTAssertEqual(other.comment, "typo in the answer")
    // #8: that was the last due card.
    waitForLabel(el(app, "study.message"), "All caught up")
    Thread.sleep(forTimeInterval: 0.5)  // counter cross-fade (Theme.Motion.standard) settled
    snapshot("study-report-caught-up", appearance: .light)
    app.terminate()
    server.stop()
    XCTAssertTrue(commentHasID, "the alert's text field has no study.report.comment id (015b ids)")
  }

  // MARK: - Last card (015b #6, #8)

  /// Reporting the only due card: "Reported" shows, then "All caught up" (not "No cards yet": the deck holds
  /// the held-out card).
  @MainActor
  func testReport_lastCardShowsReportedThenCaughtUp() throws {
    XCUIDevice.shared.appearance = .light
    let (server, _) = try stub([
      .init(id: "aaaaaaaa-0000-0000-0000-000000000001", front: Self.front, back: Self.back, due: Self.base)
    ])
    let app = launch(api: .live(server.url))
    reveal(app)
    openMenu(app)
    menuButton(app, "drop", "I don't want this card").tap()
    var sawReported = false
    let caughtUp = poll(timeout: 10) {
      let n = self.el(app, "study.reportNotice")
      if n.exists && n.label == "Reported" {
        if !sawReported { Thread.sleep(forTimeInterval: 0.5); self.snapshot("study-report-last-reported", appearance: .light) }
        sawReported = true
      }
      return self.el(app, "study.message").exists
    }
    XCTAssertTrue(caughtUp, "no message screen after reporting the last card")
    XCTAssertTrue(sawReported, "'Reported' never shown after reporting the last card")
    XCTAssertEqual(el(app, "study.message").label, "All caught up")
    XCTAssertFalse(app.staticTexts["No cards yet"].exists, "empty-deck message instead of caught-up")
    Thread.sleep(forTimeInterval: 0.5)
    snapshot("study-report-last-caught-up", appearance: .light)
    app.terminate()
    server.stop()
  }

  // MARK: - Failure (015b #9)

  /// 015b #9 (stub 500): the card stays revealed, the ratings stay enabled, the counter slot says
  /// "Couldn't send the report"; a rating clears it.
  @MainActor
  func testReport_failureKeepsCard() throws {
    XCUIDevice.shared.appearance = .light
    let (server, deck) = try stub([
      .init(id: "aaaaaaaa-0000-0000-0000-000000000001", front: Self.front, back: Self.back, due: Self.base),
      .init(id: "aaaaaaaa-0000-0000-0000-000000000002", front: "la carte", back: "the menu",
            due: Self.base.addingTimeInterval(60)),
    ])
    deck.writeStatus = 500
    let app = launch(api: .live(server.url))
    reveal(app)
    openMenu(app)
    menuButton(app, "wrong", "This is wrong").tap()
    waitForLabel(el(app, "study.reportNotice"), "Couldn't send the report", timeout: 5)
    XCTAssertEqual(deck.reports.count, 1, "reports: \(deck.reports)")
    waitForLabel(el(app, "study.back"), Self.back)
    waitForLabel(el(app, "study.front"), Self.front)
    assertRatingsEnabled(app)
    XCTAssertFalse(el(app, "study.message").exists, "went to a message screen on a failed report")
    Thread.sleep(forTimeInterval: 0.5)  // counter cross-fade (Theme.Motion.standard) settled
    snapshot("study-report-failed", appearance: .light)
    Thread.sleep(forTimeInterval: 2.5)
    XCTAssertTrue(el(app, "study.reportNotice").exists, "the failure notice expired by itself")

    deck.writeStatus = 0
    el(app, "study.rate.good").tap()
    waitForLabel(el(app, "study.front"), "la carte")
    waitForAbsence(el(app, "study.reportNotice"), "failure notice not cleared by a rating")
    app.terminate()
    server.stop()
  }

  // MARK: - Held on refresh (015b #10)

  /// 015b #10 (mock): a reported card doesn't come back on a reload (spec 018: background → foreground, no pull).
  @MainActor
  func testReport_heldAfterRefresh() {
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .mock)
    reveal(app)
    openMenu(app)
    menuButton(app, "drop", "I don't want this card").tap()
    waitForLabel(el(app, "study.front"), "la carte")
    waitForLabel(el(app, "study.remaining"), "2 to review", timeout: 4)
    backgroundAndReactivate(app)
    Thread.sleep(forTimeInterval: 2)
    waitForLabel(el(app, "study.front"), "la carte")
    waitForLabel(el(app, "study.remaining"), "2 to review")
    app.terminate()
  }

  // MARK: - Ask (016a #1, #2, #4)

  /// 016a #2, #4 (stub, light + dark): "Ask about this card" shows "Copied" in the counter slot for about 2 s, sends
  /// nothing, leaves the card revealed with the ratings enabled and the count unchanged. The pasteboard holds the
  /// exact spec text: pasted inside the app into the New card editor (multi-line field) and read back.
  @MainActor
  func testAsk_copiesCardText() throws {
    let id = "AAAAAAAA-0000-0000-0000-0000000000A1"
    let expected = "This is the card \(id.lowercased()) in the La Carte flashcard app.\n"
      + "Question: \(Self.front)\nAnswer: \(Self.back)\n\n"
    for appearance in Self.appearances {
      XCUIDevice.shared.appearance = appearance
      let (server, deck) = try stub([
        .init(id: id, front: Self.front, back: Self.back, due: Self.base),
        .init(id: "BBBBBBBB-0000-0000-0000-0000000000B2", front: "la carte", back: "the menu",
              due: Self.base.addingTimeInterval(60)),
      ])
      let app = launch(api: .live(server.url))
      reveal(app)
      waitForLabel(el(app, "study.remaining"), "2 to review")
      let before = server.requests.count
      openMenu(app)
      menuButton(app, "ask", "Ask about this card").tap()
      // 016b #6: default Vibe isn't installed on the simulator.
      waitForLabel(el(app, "study.reportNotice"), "Copied · Vibe isn't installed", timeout: 3)
      XCTAssertTrue(el(app, "study.reportNotice").label.hasPrefix("Copied"))
      XCTAssertFalse(el(app, "study.remaining").exists, "counter shown next to the Copied notice")
      Thread.sleep(forTimeInterval: 0.5)  // counter cross-fade (Theme.Motion.standard) settled
      snapshot("study-ask-not-installed", appearance: appearance)
      waitForLabel(el(app, "study.back"), Self.back)
      assertRatingsEnabled(app)
      waitForLabel(el(app, "study.remaining"), "2 to review", timeout: 4)
      XCTAssertTrue(deck.reports.isEmpty, "Ask sent a report")
      let writes = server.requests.dropFirst(before).filter { $0.method != "GET" }
      XCTAssertTrue(writes.isEmpty, "Ask sent a request: \(writes.map { "\($0.method) \($0.path)" })")

      if appearance == .light {
        XCTAssertEqual(pastedText(app), expected, "pasteboard text isn't the 016 template")
      }
      app.terminate()
      server.stop()
    }
  }

  /// 016b #5: with "Copy only" chosen (`-aiApp copyOnly`, the stored value), Ask shows just "Copied".
  @MainActor
  func testAsk_copyOnlyShowsCopied() throws {
    XCUIDevice.shared.appearance = .light
    let (server, _) = try stub([
      .init(id: "AAAAAAAA-0000-0000-0000-0000000000A1", front: Self.front, back: Self.back, due: Self.base),
    ])
    let app = launch(api: .live(server.url), arguments: ["-aiApp", "copyOnly"])
    reveal(app)
    openMenu(app)
    menuButton(app, "ask", "Ask about this card").tap()
    waitForLabel(el(app, "study.reportNotice"), "Copied", timeout: 3)
    snapshot("study-ask-copy-only", appearance: .light)
    app.terminate()
    server.stop()
  }

  // MARK: - Broken photo (015b #13, #14)

  /// 015b #13 (stub): a card whose prompt photo fails to load is never shown broken: it's skipped silently (no
  /// dialog, no notice) and a `broken_photo` report with the URL is sent. #14: a card whose answer photo fails shows
  /// with the placeholder and is reported once; rating it goes on with the session.
  @MainActor
  func testReport_brokenPhotos() throws {
    XCUIDevice.shared.appearance = .light
    let server = StubAPIServer()
    try server.start()  // first: the photo URLs need its port
    let promptURL = server.url + "/photos/broken-ada.png"
    let answerURL = server.url + "/photos/broken-lee.png"
    let promptCard = StubDeck.NoteCard(id: "cccccccc-0000-0000-0000-000000000001", prompt: ["photo"],
                                       answer: ["name"], due: Self.base)
    let answerCard = StubDeck.NoteCard(id: "cccccccc-0000-0000-0000-000000000002", prompt: ["name"],
                                       answer: ["photo"], due: Self.base.addingTimeInterval(60))
    let deck = StubDeck(
      [.init(id: "aaaaaaaa-0000-0000-0000-000000000001", front: "greeting", back: "hello",
             due: Self.base.addingTimeInterval(120))],
      notes: [
        .init(type: "person", fields: ["photo": promptURL, "name": "Ada Byron"], cards: [promptCard]),
        .init(type: "person", fields: ["photo": answerURL, "name": "Lee Park"], cards: [answerCard]),
      ])
    server.handler = deck.handle
    let app = launch(api: .live(server.url))

    // #13: watch the screen until the next card shows; the broken prompt must never be on screen as broken.
    let photo = el(app, "study.photo"), lee = el(app, "study.front").staticTexts["Lee Park"]
    var sawBrokenPrompt = false, sawNotice = false
    let skipped = poll(timeout: 15) {
      // A snapshot, not `photo.label`: the card can be skipped between the check and the read (seen on CI), and
      // reading the label of a vanished element fails the test.
      if el(app, "study.reveal").exists, (try? photo.snapshot())?.label == "Photo, not loaded" { sawBrokenPrompt = true }
      if el(app, "study.reportNotice").exists { sawNotice = true }
      return lee.exists
    }
    XCTAssertTrue(skipped, "the card after the broken prompt photo never showed")
    XCTAssertFalse(sawBrokenPrompt, "the broken prompt photo was shown (placeholder) before the skip")
    XCTAssertFalse(sawNotice, "a notice was shown for the silent broken_photo report")
    XCTAssertFalse(menuButton(app, "wrong", "This is wrong").exists, "a dialog opened")
    waitForLabel(el(app, "study.remaining"), "2 to review")
    snapshot("study-broken-photo-skipped", appearance: .light)
    XCTAssertTrue(poll(timeout: 5) { deck.reports.contains { $0.cardID == promptCard.id } }, "no report for the prompt photo")
    let promptReports = deck.reports.filter { $0.cardID == promptCard.id }
    XCTAssertEqual(promptReports.count, 1, "prompt reports: \(promptReports)")
    XCTAssertEqual(promptReports.first?.reason, "broken_photo")
    XCTAssertTrue([nil, promptURL].contains(promptReports.first?.comment), "comment: \(String(describing: promptReports.first?.comment))")

    // #14: answer-side broken photo → placeholder, reported once, the session goes on.
    el(app, "study.reveal").tap()
    XCTAssertTrue(photo.waitFor(timeout: 5), "no study.photo in the answer")
    waitForLabel(photo, "Photo, not loaded", timeout: 15)
    XCTAssertTrue(el(app, "study.front").staticTexts["Lee Park"].exists, "answer-broken card not shown normally")
    assertRatingsEnabled(app)
    XCTAssertFalse(el(app, "study.reportNotice").exists, "a notice was shown for the answer photo report")
    snapshot("study-broken-photo-answer", appearance: .light)
    XCTAssertTrue(poll(timeout: 5) { deck.reports.contains { $0.cardID == answerCard.id } }, "no report for the answer photo")
    Thread.sleep(forTimeInterval: 2)
    el(app, "study.rate.good").tap()
    waitForLabel(el(app, "study.front"), "greeting")
    Thread.sleep(forTimeInterval: 1)
    let answerReports = deck.reports.filter { $0.cardID == answerCard.id }
    XCTAssertEqual(answerReports.map(\.reason), ["broken_photo"], "answer reports: \(answerReports)")
    XCTAssertTrue([nil, answerURL].contains(answerReports.first?.comment))
    XCTAssertEqual(deck.reports.count, 2, "reports: \(deck.reports)")
    app.terminate()
    server.stop()
  }

  // MARK: - Live API (015b #12)

  /// 015b #12 (scripts/e2e.sh, on the unseeded API): the runner adds a card, the app reveals it and reports
  /// "I don't want this card", then `GET /cards/due` doesn't include it. The card is deleted again so the
  /// empty-deck live check still holds.
  @MainActor
  func testReport_dropCard_liveAPI() throws {
    guard let url = ProcessInfo.processInfo.environment["LA_CARTE_EMPTY_API_URL"], !url.isEmpty else {
      throw XCTSkip("LA_CARTE_EMPTY_API_URL not set — run scripts/e2e.sh")
    }
    let created = try XCTUnwrap(
      liveJSON(url + "/cards", method: "POST", body: #"{"front":"obsolete","back":"no longer used"}"#)
        as? [String: Any])
    let id = try XCTUnwrap(created["id"] as? String, "POST /cards: \(created)")
    addTeardownBlock { _ = self.liveJSON(url + "/cards/\(id)", method: "DELETE") }  // runs even after a failure
    XCUIDevice.shared.appearance = .light
    let app = launch(api: .live(url))
    reveal(app, front: "obsolete", back: "no longer used")
    openMenu(app)
    menuButton(app, "drop", "I don't want this card").tap()
    // #6: "Reported" for 2 s; #8: the last card reported → "All caught up". Watch for both.
    var sawNotice = false
    let caughtUp = poll(timeout: 10) {
      if self.el(app, "study.reportNotice").exists { sawNotice = true }
      return self.el(app, "study.message").exists && self.el(app, "study.message").label == "All caught up"
    }
    Thread.sleep(forTimeInterval: 0.5)
    snapshot("study-report-live", appearance: .light)
    XCTAssertTrue(caughtUp, "no 'All caught up' after reporting the last card")
    let due = try XCTUnwrap(liveJSON(url + "/cards/due") as? [[String: Any]], "GET /cards/due")
    XCTAssertFalse(due.contains { ($0["id"] as? String)?.lowercased() == id.lowercased() }, "reported card still due")
    XCTAssertTrue(sawNotice || el(app, "study.reportNotice").waitFor(timeout: 1),
                  "no 'Reported' confirmation after reporting the last card")
  }

  // MARK: - Helpers

  @MainActor
  private func reveal(_ app: XCUIApplication, front: String = ReportUITests.front, back: String = ReportUITests.back,
                      file: StaticString = #filePath, line: UInt = #line) {
    waitForLabel(el(app, "study.front"), front, file: file, line: line)
    el(app, "study.reveal").tap()
    waitForLabel(el(app, "study.back"), back, file: file, line: line)
    assertRatingsEnabled(app, file: file, line: line)
  }

  /// Double-taps the revealed card clear of its text and waits for the dialog.
  @MainActor
  private func openMenu(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    Thread.sleep(forTimeInterval: 0.5)  // reveal animation settled
    el(app, "study.card").coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.08)).doubleTap()
    XCTAssertTrue(menuButton(app, "ask", "Ask about this card").waitFor(timeout: 5),
                  "double tap on the revealed card opened no menu", file: file, line: line)
    Thread.sleep(forTimeInterval: 0.6)  // presentation animation
  }

  /// A dialog button by its id; the spec allows its label when the system drops ids inside a dialog.
  @MainActor
  private func menuButton(_ app: XCUIApplication, _ id: String, _ title: String) -> XCUIElement {
    let byID = el(app, "study.report.\(id)")
    return byID.exists ? byID : app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
  }

  /// A dialog's Cancel (a system button, no id); the menu sheet has none, so tap the dimmed screen above it.
  @MainActor
  private func cancelMenu(_ app: XCUIApplication) {
    let cancel = app.buttons.matching(NSPredicate(format: "label == 'Cancel'")).firstMatch
    if cancel.exists && cancel.isHittable {
      cancel.tap()
    } else {
      app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
    }
  }

  @MainActor
  private func assertRatingsEnabled(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    for rating in ["again", "good"] {
      let button = el(app, "study.rate.\(rating)")
      XCTAssertTrue(button.waitFor(timeout: 3), "study.rate.\(rating) missing", file: file, line: line)
      XCTAssertTrue(poll(timeout: 3) { button.isEnabled }, "study.rate.\(rating) disabled", file: file, line: line)
    }
  }

  /// Opens New card from Study and pastes the pasteboard into its multi-line front field (a user paste from the
  /// edit menu: no paste-permission prompt), then reads the field back.
  @MainActor
  private func pastedText(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> String? {
    el(app, "study.add").tap()
    waitForSheet(app, "New card", file: file, line: line)
    let field = el(app, "editor.front")
    XCTAssertTrue(field.waitFor(timeout: 5), "no editor.front", file: file, line: line)
    field.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitFor(timeout: 5), "no keyboard in editor.front", file: file, line: line)
    let paste = app.menuItems.matching(NSPredicate(format: "label == 'Paste'")).firstMatch
    let pasteButton = app.buttons.matching(NSPredicate(format: "label == 'Paste'")).firstMatch
    for _ in 0..<3 where !(paste.exists || pasteButton.exists) {
      Thread.sleep(forTimeInterval: 0.5)
      field.tap()
      if !poll(timeout: 2, { paste.exists || pasteButton.exists }) { field.press(forDuration: 1) }
      _ = poll(timeout: 2) { paste.exists || pasteButton.exists }
    }
    XCTAssertTrue(paste.exists || pasteButton.exists, "no Paste in the edit menu", file: file, line: line)
    // CI once pasted nothing: log what the edit menu offered (logs/<test>.txt).
    print("pastedText: menu items \(app.menuItems.allElementsBoundByIndex.map(\.label)), Paste button \(pasteButton.exists)")
    (paste.exists ? paste : pasteButton).tap()
    Thread.sleep(forTimeInterval: 1)
    snapshot("study-ask-pasted", appearance: .light)
    return field.value as? String
  }

  private func stub(_ cards: [StubDeck.Card]) throws -> (StubAPIServer, StubDeck) {
    let deck = StubDeck(cards)
    let server = StubAPIServer(handler: deck.handle)
    try server.start()
    return (server, deck)
  }

  private func liveJSON(_ url: String, method: String = "GET", body: String? = nil) -> Any? {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = method
    if let token = ProcessInfo.processInfo.environment["LA_CARTE_API_TOKEN"] {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let body {
      request.httpBody = Data(body.utf8)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    var result: Data?
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, _, _ in
      result = data
      done.signal()
    }.resume()
    _ = done.wait(timeout: .now() + 10)
    return result.flatMap { try? JSONSerialization.jsonObject(with: $0) }
  }
}
