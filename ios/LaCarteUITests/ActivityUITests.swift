import XCTest

/// Spec 029: activity log. Nothing is visible: the study flow must look and time the same with logging off, with the
/// activity server unreachable and with it hung (#30, #31), and buffered events must reach the server after a
/// relaunch, each once (#32). Light only (spec: "the point is identity, not theme").
/// Mock deck = `LA_CARTE_API=mock`: serendipity, la carte, ephemeral (all due, fixture order).
final class ActivityUITests: XCTestCase {
  private static let cards: [(front: String, back: String)] = [
    ("serendipity", "finding something good without looking for it"),
    ("la carte", "the menu — and the map"),
    ("ephemeral", "lasting a very short time"),
  ]

  override func setUp() {
    continueAfterFailure = false
  }

  // MARK: - #30 + #31: same screens, same timing

  /// 10 rounds: 30 reveal and 20 rate → next samples per mode (5 rounds were too few on a shared, busy Mac).
  private static let rounds = 10

  private enum Mode: String, CaseIterable {
    case off, down, hung
  }

  /// `rounds` rounds; each round launches the mock deck once per mode (order rotated per round, so warm-up and drift
  /// don't favour one mode) and studies its 3 cards: 3 reveal and 2 rate → next samples per mode and round.
  @MainActor
  func testActivity_studyLooksAndTimesTheSame() throws {
    XCUIDevice.shared.appearance = .light
    // Hung activity server: accepts, reads the request, never answers within the test.
    let hung = StubAPIServer { _ in StubAPIServer.Response(status: 200, body: "{}", delay: 3600) }
    try hung.start()
    let environment: [Mode: [String: String]] = [
      .off: ["LA_CARTE_ACTIVITY": "off"],
      .down: ["LA_CARTE_ACTIVITY_URL": unreachableAPIURL],
      .hung: ["LA_CARTE_ACTIVITY_URL": hung.url],
    ]
    var reveal: [Mode: [Double]] = [:]
    var rateNext: [Mode: [Double]] = [:]
    var rateCaughtUp: [Mode: [Double]] = [:]
    var signatures: [Mode: [String: [String]]] = [:]

    let modes = Mode.allCases
    for round in 0..<Self.rounds {
      for k in 0..<modes.count {
        let mode = modes[(k + round) % modes.count]
        let app = launch(api: .mock, environment: environment[mode]!)
        let first = round == 0
        for (index, card) in Self.cards.enumerated() {
          waitForLabel(el(app, "study.front"), card.front, timeout: 15)
          XCTAssertTrue(el(app, "study.reveal").waitFor(timeout: 5), "\(mode): study.reveal missing")
          if first && index == 0 {
            settle()
            signatures[mode, default: [:]]["front"] = signature(app)
            snapshot("study-front-activity-\(mode)", appearance: .light)
          }
          let revealPoint = point(app, "study.reveal")  // resolved before the clock starts
          let reveal0 = Date()
          revealPoint.tap()
          let back = el(app, "study.back")
          reveal[mode, default: []].append(ms(since: reveal0, "\(mode) reveal \(index)") {
            back.exists && back.label == card.back
          })
          XCTAssertTrue(el(app, "study.rate.good").waitFor(timeout: 5), "\(mode): study.rate.good missing")
          if first && index == 0 {
            settle()
            signatures[mode, default: [:]]["revealed"] = signature(app)
            snapshot("study-revealed-activity-\(mode)", appearance: .light)
          }
          let ratePoint = point(app, "study.rate.good")
          let rate0 = Date()
          ratePoint.tap()
          if index + 1 < Self.cards.count {
            let next = Self.cards[index + 1].front
            let front = el(app, "study.front")
            rateNext[mode, default: []].append(ms(since: rate0, "\(mode) rate \(index)") {
              front.exists && front.label == next
            })
          } else {
            let message = el(app, "study.message")
            rateCaughtUp[mode, default: []].append(ms(since: rate0, "\(mode) rate \(index)") {
              message.exists && message.label == "All caught up"
            })
          }
        }
        if first {
          XCTAssertTrue(el(app, "study.nextDue").waitFor(timeout: 5), "\(mode): study.nextDue missing")
          settle()
          signatures[mode, default: [:]]["caughtUp"] = signature(app)
          snapshot("study-caught-up-activity-\(mode)", appearance: .light)
        }
        XCTAssertEqual(app.alerts.count, 0, "\(mode): an alert is shown")
        app.terminate()
      }
    }

    // #30: same elements (identifiers) on every screen, no alert or notice.
    for mode in [Mode.down, .hung] {
      for state in ["front", "revealed", "caughtUp"] {
        XCTAssertEqual(signatures[mode]?[state], signatures[.off]?[state], "#30 \(mode) \(state): elements differ")
      }
    }
    // The hung run really was logging (and stuck): the activity server got requests it never answered.
    let posts = hung.requests.filter { $0.method == "POST" && $0.path.hasSuffix("/activity") }
    XCTAssertFalse(posts.isEmpty, "#30: the hung server never received POST /activity")

    // #31: medians within 50 ms of `off`.
    var lines = ["requests to the hung server: \(posts.count) POST /activity"]
    for mode in modes {
      lines.append("\(mode): reveal median \(median(reveal[mode]!)) ms \(reveal[mode]!), "
        + "rate→next median \(median(rateNext[mode]!)) ms \(rateNext[mode]!), "
        + "rate→caught-up median \(median(rateCaughtUp[mode]!)) ms \(rateCaughtUp[mode]!)")
    }
    report("029 #31 timings (ms)", lines)
    for mode in [Mode.down, .hung] {
      let dReveal = median(reveal[mode]!) - median(reveal[.off]!)
      let dRate = median(rateNext[mode]!) - median(rateNext[.off]!)
      XCTAssertLessThan(abs(dReveal), 50, "#31 \(mode): reveal median differs by \(dReveal) ms from off")
      XCTAssertLessThan(abs(dRate), 50, "#31 \(mode): rate→next median differs by \(dRate) ms from off")
    }
    hung.stop()
  }

  // MARK: - Delivery on the mock deck: buffer survives a kill, a failed batch is retried with the same ids

  /// Launch 1 studies 3 cards with the activity server unreachable, then the app is terminated. Launch 2 points at a
  /// stub that answers the first POST /activity with 500 and the rest with 200: the failed batch comes back with the
  /// same ids (after a foreground resets the backoff), no id is acknowledged twice, and launch 1's events all arrive.
  @MainActor
  func testActivity_bufferSurvivesRelaunchAndRetries() throws {
    XCUIDevice.shared.appearance = .light
    let start = Date().addingTimeInterval(-1)
    let app = launch(api: .mock, environment: ["LA_CARTE_ACTIVITY_URL": unreachableAPIURL])
    studyAll(app)
    app.terminate()

    let relaunchAt = Date()
    let answered = Counter()
    let stub = StubAPIServer { request in
      guard request.method == "POST", request.path.hasSuffix("/activity") else {
        return StubAPIServer.Response(status: 404, body: #"{"detail":"Not Found"}"#)
      }
      return answered.next() == 0
        ? StubAPIServer.Response(status: 500, body: #"{"detail":"boom"}"#)
        : StubAPIServer.Response(status: 200, body: #"{"stored":0,"duplicates":0,"rejected":0}"#)
    }
    try stub.start()
    let relaunched = launch(api: .mock, environment: ["LA_CARTE_ACTIVITY_URL": stub.url])
    waitForLabel(el(relaunched, "study.front"), Self.cards[0].front, timeout: 15)
    XCTAssertTrue(poll(timeout: 15) { !self.activityPosts(stub).isEmpty }, "no POST /activity after relaunch")
    XCTAssertEqual(relaunched.alerts.count, 0, "an alert is shown after a failed upload")
    backgroundAndReactivate(relaunched)  // app_foreground resets the 30 s backoff and flushes
    waitForLabel(el(relaunched, "study.front"), Self.cards[0].front, timeout: 10)

    // Launch 1's study events (after `start`): 3 shown, 3 revealed, 3 rated, all acknowledged.
    func acknowledged() -> [[String: Any]] { activityPosts(stub).dropFirst().flatMap { $0 } }
    func launch1(_ events: [[String: Any]], _ kind: String) -> [[String: Any]] {
      events.filter { $0["kind"] as? String == kind && (isoDate($0["at"]) ?? .distantPast) >= start }
    }
    XCTAssertTrue(poll(timeout: 20) { launch1(acknowledged(), "rated").count >= 3 },
                  "launch 1's rated events not acknowledged: \(activityPosts(stub).map(\.count))")
    let posts = activityPosts(stub)
    let failedIDs = Set(posts[0].compactMap { $0["id"] as? String })
    let okEvents = posts.dropFirst().flatMap { $0 }
    let okIDs = okEvents.compactMap { $0["id"] as? String }
    let samples = posts.flatMap { $0 }.filter { (isoDate($0["at"]) ?? .distantPast) >= start }
    let json = (try? JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
    attachment.name = "activity-events-mock"
    attachment.lifetime = .keepAlways
    add(attachment)
    report("029 delivery (mock)", ["POST /activity sizes: \(posts.map(\.count))", "failed batch: \(failedIDs.count) ids",
                                   "acknowledged: \(okIDs.count) ids, unique \(Set(okIDs).count)"])
    print("ACTIVITY-EVENTS-JSON " + String(decoding: json, as: UTF8.self).replacingOccurrences(of: "\n", with: " "))
    XCTAssertTrue(failedIDs.isSubset(of: Set(okIDs)), "the failed batch was not resent with the same ids")
    XCTAssertEqual(okIDs.count, Set(okIDs).count, "an event was acknowledged twice")

    let rated = launch1(okEvents, "rated")
    let shown = launch1(okEvents, "card_shown")
    let revealed = launch1(okEvents, "answer_revealed")
    XCTAssertEqual(rated.count, 3, "rated")
    XCTAssertEqual(revealed.count, 3, "answer_revealed")
    let ratedSessions = Set(rated.compactMap { $0["session"] as? String })
    XCTAssertEqual(ratedSessions.count, 1, "launch 1's ratings span several sessions")
    // The first card is shown before scene `.active` starts the foreground session (decision 10: a session at launch
    // and one per app_foreground), so launch 1's card_shown events span the launch and the foreground session.
    let shownLaunch1 = shown.filter { (isoDate($0["at"]) ?? .distantFuture) < relaunchAt }
    XCTAssertEqual(Set(shownLaunch1.compactMap { $0["card_id"] as? String }).count, 3, "card_shown in launch 1")
    XCTAssertEqual(Set(rated.compactMap { $0["card_id"] as? String }).count, 3, "rated card ids")
    for event in rated + revealed + shownLaunch1 {
      XCTAssertEqual(event["tz"] as? String, TimeZone.current.identifier, "tz")
      XCTAssertFalse((event["app_version"] as? String ?? "").isEmpty, "app_version")
      XCTAssertFalse((event["build"] as? String ?? "").isEmpty, "build")
    }
    for event in rated {
      let data = event["data"] as? [String: Any] ?? [:]
      XCTAssertEqual(data["rating"] as? String, "good")
      XCTAssertEqual(data["input"] as? String, "button")
    }
    // Launch 2 has its own session.
    let launch2Sessions = Set(posts.flatMap { $0 }
      .filter { ($0["kind"] as? String) == "app_foreground" && (isoDate($0["at"]) ?? .distantPast) >= start }
      .compactMap { $0["session"] as? String })
    XCTAssertTrue(launch2Sessions.count >= 2, "expected launch 1 and launch 2 foreground sessions: \(launch2Sessions)")

    stub.stop()
  }

  // MARK: - #32 live: events arrive once the server is back

  /// Dedicated API seeded with 4 cards (scripts/e2e.sh `LA_CARTE_ACTIVITY_API_URL`). Launch 1 studies 3 with the
  /// activity URL on a closed port; terminate; launch 2 pointed at the live API: within 15 s `GET /activity` lists
  /// launch 1's card_shown / answer_revealed / rated (each once, the launch and foreground sessions of decision 10),
  /// with version/build and the device zone.
  @MainActor
  func testActivity_eventsArriveAfterRelaunch_liveAPI() throws {
    guard let url = ProcessInfo.processInfo.environment["LA_CARTE_ACTIVITY_API_URL"], !url.isEmpty else {
      throw XCTSkip("LA_CARTE_ACTIVITY_API_URL not set — run scripts/e2e.sh")
    }
    XCUIDevice.shared.appearance = .light
    let cards = try XCTUnwrap(liveJSON("\(url)/cards") as? [[String: Any]], "GET /cards")
    var idByFront: [String: String] = [:]
    for card in cards { idByFront[card["front"] as? String ?? ""] = card["id"] as? String }
    XCTAssertEqual(idByFront.count, 4, "seeded cards")

    let app = launch(api: .live(url), environment: ["LA_CARTE_ACTIVITY_URL": unreachableAPIURL])
    var studied: [String] = []
    for _ in 0..<3 {
      let front = el(app, "study.front")
      XCTAssertTrue(poll(timeout: 15) { front.exists && !studied.contains(idByFront[front.label] ?? "") },
                    "next card not shown")
      let id = try XCTUnwrap(idByFront[front.label], "unknown card \(front.label)")
      studied.append(id)
      el(app, "study.reveal").tap()
      XCTAssertTrue(el(app, "study.rate.good").waitFor(timeout: 5), "study.rate.good missing")
      el(app, "study.rate.good").tap()
    }
    let front = el(app, "study.front")
    XCTAssertTrue(poll(timeout: 15) { front.exists && !studied.contains(idByFront[front.label] ?? "") },
                  "4th card not shown")
    snapshot("study-front-activity-live-launch1", appearance: .light)
    let fourth = try XCTUnwrap(idByFront[front.label])
    XCTAssertEqual(try events(url).count, 0, "events reached the live API while the activity URL was closed")
    app.terminate()

    let relaunched = launch(api: .live(url))
    let relaunchedAt = Date()
    let front2 = el(relaunched, "study.front")
    XCTAssertTrue(poll(timeout: 15) { front2.exists && idByFront[front2.label] == fourth }, "4th card after relaunch")
    snapshot("study-front-activity-live-launch2", appearance: .light)

    var found: [[String: Any]] = []
    let arrived = poll(timeout: 15) {
      found = (try? self.events(url)) ?? []
      let launch1 = studied.allSatisfy { id in
        ["card_shown", "answer_revealed", "rated"].allSatisfy { kind in
          found.contains { $0["kind"] as? String == kind && $0["card_id"] as? String == id }
        }
      }
      // The 4th card was shown in launch 1 before terminating. Launch 2's own card_shown isn't required: it waits
      // for the lazy flush (25 events or 60 s, decision 6); launch 2 only has to deliver launch 1's buffer.
      let shownFourth = found.contains { $0["kind"] as? String == "card_shown" && $0["card_id"] as? String == fourth }
      return launch1 && shownFourth
    }
    let elapsed = Date().timeIntervalSince(relaunchedAt)
    let json = (try? JSONSerialization.data(withJSONObject: found, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
    attachment.name = "activity-events-live"
    attachment.lifetime = .keepAlways
    add(attachment)
    print("ACTIVITY-EVENTS-LIVE " + String(decoding: json, as: UTF8.self).replacingOccurrences(of: "\n", with: " "))
    XCTAssertTrue(arrived, "#32: events missing after 15 s: \(found.map { "\($0["kind"] ?? "")" })")

    let ids = found.compactMap { $0["id"] as? String }
    XCTAssertEqual(ids.count, Set(ids).count, "#32: duplicate event ids")
    for id in studied {
      for kind in ["card_shown", "answer_revealed", "rated"] {
        let matches = found.filter { $0["kind"] as? String == kind && $0["card_id"] as? String == id }
        XCTAssertEqual(matches.count, 1, "#32: \(kind) for a studied card listed \(matches.count) times")
      }
    }
    // Launch 1's study events: one session for reveal/rate; the first card_shown may sit in the launch session
    // (logged before scene `.active`, decision 10), so at most 2.
    let study = found.filter { studied.contains($0["card_id"] as? String ?? "") }
    let launch1Sessions = Set(study.compactMap { $0["session"] as? String })
    let ratingSessions = Set(study.filter { ($0["kind"] as? String) != "card_shown" }.compactMap { $0["session"] as? String })
    XCTAssertEqual(ratingSessions.count, 1, "#32: launch 1's reveal/rate events span several sessions")
    XCTAssertLessThanOrEqual(launch1Sessions.count, 2, "#32: launch 1's study events: \(launch1Sessions.count) sessions")
    let shownFourth = found.filter { $0["kind"] as? String == "card_shown" && $0["card_id"] as? String == fourth }
    XCTAssertEqual(shownFourth.count, 1, "#32: launch 1's card_shown of the 4th card")
    let versions = Set(found.compactMap { $0["app_version"] as? String })
    let builds = Set(found.compactMap { $0["build"] as? String })
    XCTAssertEqual(versions.count, 1, "#32: app_version \(versions)")
    XCTAssertEqual(builds.count, 1, "#32: build \(builds)")
    XCTAssertFalse(versions.first?.isEmpty ?? true, "#32: empty app_version")
    for event in found {
      XCTAssertEqual(event["tz"] as? String, TimeZone.current.identifier, "#32: tz")
      XCTAssertNotNil(event["received_at"], "#32: received_at")
      XCTAssertNotNil(event["local_at"], "#32: local_at")
    }
    report("029 #32 live", ["arrived \(String(format: "%.1f", elapsed)) s after relaunch",
                            "\(found.count) events, \(Set(ids).count) unique ids, versions \(versions), builds \(builds)",
                            "kinds: \(found.compactMap { $0["kind"] as? String }.reversed())"])
  }

  // MARK: - Helpers

  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
  }

  @MainActor
  private func studyAll(_ app: XCUIApplication) {
    for card in Self.cards {
      waitForLabel(el(app, "study.front"), card.front, timeout: 15)
      el(app, "study.reveal").tap()
      waitForLabel(el(app, "study.back"), card.back, timeout: 5)
      el(app, "study.rate.good").tap()
    }
    waitForLabel(el(app, "study.message"), "All caught up", timeout: 10)
  }

  /// Event arrays of each POST /activity the stub received, in arrival order.
  private func activityPosts(_ stub: StubAPIServer) -> [[[String: Any]]] {
    stub.requests.filter { $0.method == "POST" && $0.path.hasSuffix("/activity") }.map { request in
      let object = try? JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any]
      return object?["events"] as? [[String: Any]] ?? []
    }
  }

  private func isoDate(_ value: Any?) -> Date? {
    guard let string = value as? String else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: string)
  }

  /// Milliseconds from `start` until `condition` holds (checked continuously, ~5 ms apart).
  @MainActor
  private func ms(since start: Date, _ what: String, _ condition: () -> Bool) -> Double {
    while !condition() {
      if Date().timeIntervalSince(start) > 10 {
        XCTFail("\(what): not reached in 10 s")
        return 10_000
      }
      Thread.sleep(forTimeInterval: 0.005)
    }
    return (Date().timeIntervalSince(start) * 1000).rounded()
  }

  private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let mid = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
  }

  /// Screen point at the element's centre, so the timed tap doesn't include resolving the element.
  @MainActor
  private func point(_ app: XCUIApplication, _ id: String) -> XCUICoordinate {
    let frame = el(app, id).frame
    return app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY))
  }

  /// Lets the reveal fade / card transition finish so screenshots compare like for like.
  @MainActor
  private func settle() { Thread.sleep(forTimeInterval: 0.8) }

  /// Sorted identifiers of every element on screen (the "same elements" of #30), plus alert / sheet counts.
  @MainActor
  private func signature(_ app: XCUIApplication) -> [String] {
    let ids = app.descendants(matching: .any).allElementsBoundByIndex.map(\.identifier).filter { !$0.isEmpty }
    return ids.sorted() + ["alerts=\(app.alerts.count)", "sheets=\(app.sheets.count)"]
  }

  private func report(_ title: String, _ lines: [String]) {
    XCTContext.runActivity(named: title + ": " + lines.joined(separator: " | ")) { _ in }
    lines.forEach { print("\(title): \($0)") }
  }

  private func events(_ url: String) throws -> [[String: Any]] {
    try XCTUnwrap(liveJSON("\(url)/activity?limit=1000") as? [[String: Any]], "GET /activity")
  }

  private func liveJSON(_ url: String) throws -> Any {
    var request = URLRequest(url: URL(string: url)!)
    if let token = ProcessInfo.processInfo.environment["LA_CARTE_API_TOKEN"] {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    nonisolated(unsafe) var result: Data?
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, _, _ in
      result = data
      done.signal()
    }.resume()
    _ = done.wait(timeout: .now() + 10)
    let data = try XCTUnwrap(result, "no response from \(url)")
    return try JSONSerialization.jsonObject(with: data)
  }
}
