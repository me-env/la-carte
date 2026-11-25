@testable import APIClient
import Dependencies
import Foundation
import Testing

@testable import ActivityClient

/// Spec 029 AC 12-18: the buffer file and its uploader, driven directly.
struct ActivityLogTests {
  @Test func logReturnsAtOnceWhileSendingIsStuck() async throws {
    let file = Self.newFile()
    var api = APIClient()
    api.sendActivity = { _ in try await Task.never() }
    let client = ActivityClient.live(api: api, isConfigured: { true }, fileURL: file)

    let start = ContinuousClock.now
    for count in 0..<1_000 {
      client.log(.deckLoaded(count: count, query: false))
    }
    #expect(ContinuousClock.now - start < .milliseconds(50))

    for _ in 0..<500 where Self.lines(file).count < 1_000 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(Self.lines(file).map(\.data["count"]) == (0..<1_000).map { .int($0) })
  }

  @Test func eventsSurviveARestart() async {
    let file = Self.newFile()
    let events = (0..<3).map { _ in Self.event() }
    let first = ActivityLog(fileURL: file, isConfigured: { false }, send: { _ in Issue.record("sent while not configured") })
    for event in events { await first.append(event) }

    let server = Server()
    let second = ActivityLog(fileURL: file, send: server.send)
    await second.flush()
    await second.sending?.value

    #expect(server.batches.value == [events])
    #expect(Self.lines(file).isEmpty)
  }

  @Test func aFailedBatchStaysAndIsSentAgainWithTheSameIDs() async {
    for error: any Error in [URLError(.notConnectedToInternet), APIError(statusCode: 500, message: ""),
      APIError(statusCode: 401, message: "")]
    {
      let file = Self.newFile()
      let server = Server(failures: [error])
      let log = ActivityLog(fileURL: file, clock: TestClock(), send: server.send)
      let events = (0..<3).map { _ in Self.event() }
      for event in events { await log.append(event) }
      await log.flush()
      await log.sending?.value

      #expect(Self.lines(file) == events)
      let foreground = Self.event("app_foreground")
      await log.append(foreground)
      await log.sending?.value

      #expect(server.batches.value == [events, events + [foreground]])
      #expect(Self.lines(file).isEmpty)
    }
  }

  @Test func aBatchTheServerCanNeverTakeIsDropped() async {
    for status in [400, 413, 422] {
      let file = Self.newFile()
      let isConfigured = LockIsolated(false)
      let server = Server(failures: [APIError(statusCode: status, message: "")])
      let log = ActivityLog(fileURL: file, isConfigured: { isConfigured.value }, send: server.send)
      let events = (0..<250).map { _ in Self.event() }
      for event in events { await log.append(event) }
      isConfigured.setValue(true)
      await log.flush()
      await log.sending?.value

      #expect(server.batches.value == [Array(events[..<200]), Array(events[200...])])
      #expect(Self.lines(file).isEmpty)
      #expect(await log.backoff == nil)
    }
  }

  @Test func twentyFiveWaitingEventsAreSentAtOnce() async {
    let server = Server()
    let log = ActivityLog(fileURL: Self.newFile(), clock: TestClock(), send: server.send)
    let events = (0..<25).map { _ in Self.event() }
    for event in events.dropLast() { await log.append(event) }
    #expect(await log.sending == nil)

    await log.append(events[24])
    await log.sending?.value
    #expect(server.batches.value == [events])
  }

  @Test func fewerEventsAreSent60SecondsAfterTheOldest() async {
    let clock = TestClock()
    let server = Server()
    let log = ActivityLog(fileURL: Self.newFile(), clock: clock, send: server.send)
    let events = (0..<3).map { _ in Self.event() }
    for event in events { await log.append(event) }
    await Task.megaYield()

    await clock.advance(by: .seconds(59))
    #expect(server.batches.value.isEmpty)
    await clock.advance(by: .seconds(1))
    await server.nextCall()
    #expect(server.batches.value == [events])
  }

  @Test func foregroundAndBackgroundFlush() async {
    for kind in ["app_foreground", "app_background"] {
      let server = Server()
      let log = ActivityLog(fileURL: Self.newFile(), clock: TestClock(), send: server.send)
      let events = [Self.event(), Self.event(kind)]
      for event in events { await log.append(event) }
      await log.sending?.value
      #expect(server.batches.value == [events])
    }
  }

  @Test func atMostOneRequestIsInFlight() async {
    let server = Server(isHeld: true)
    let log = ActivityLog(fileURL: Self.newFile(), clock: TestClock(), send: server.send)
    let events = (0..<50).map { _ in Self.event() }
    for event in events[..<25] { await log.append(event) }
    await server.nextCall()
    for event in events[25...] { await log.append(event) }
    await log.flush()
    #expect(server.batches.value.count == 1)

    server.release()
    await server.nextCall()
    server.release()
    await log.sending?.value
    #expect(server.batches.value == [Array(events[..<25]), Array(events[25...])])
    #expect(server.maxInFlight.value == 1)
  }

  @Test func batchesHoldAtMost200EventsOldestFirst() async {
    let isConfigured = LockIsolated(false)
    let server = Server()
    let log = ActivityLog(fileURL: Self.newFile(), isConfigured: { isConfigured.value }, send: server.send)
    let events = (0..<450).map { _ in Self.event() }
    for event in events { await log.append(event) }
    isConfigured.setValue(true)
    await log.flush()
    await log.sending?.value

    #expect(server.batches.value.map(\.count) == [200, 200, 50])
    #expect(server.batches.value.flatMap { $0 } == events)
  }

  @Test func backoffDoublesUpTo15MinutesAndResetsOnSuccessAndForeground() async {
    let clock = TestClock()
    let server = Server(failures: Array(repeating: URLError(.timedOut), count: 7))
    let log = ActivityLog(fileURL: Self.newFile(), clock: clock, send: server.send)
    await log.append(Self.event())
    await log.flush()
    await server.nextCall()
    await log.sending?.value
    #expect(await log.backoff == .seconds(30))

    for expected in [60, 120, 240, 480, 900, 900] {
      await Task.megaYield()
      await clock.advance(by: await log.backoff!)
      await server.nextCall()
      await log.sending?.value
      #expect(await log.backoff == .seconds(expected))
    }

    await Task.megaYield()
    await clock.advance(by: .seconds(900))
    await server.nextCall()
    await log.sending?.value
    #expect(await log.backoff == nil)

    server.failures.setValue([URLError(.timedOut), URLError(.timedOut), URLError(.timedOut)])
    await log.append(Self.event("app_background"))
    await server.nextCall()
    await log.sending?.value
    await Task.megaYield()
    await clock.advance(by: .seconds(30))
    await server.nextCall()
    await log.sending?.value
    #expect(await log.backoff == .seconds(60))

    await log.append(Self.event("app_foreground"))
    await log.sending?.value
    #expect(await log.backoff == .seconds(30))
    #expect(server.batches.value.count == 11)
  }

  @Test func overTheCapTheOldestAreDropped() async {
    let file = Self.newFile()
    let full = ActivityLog(fileURL: file, isConfigured: { false }, send: { _ in })
    let events = (0..<6_000).map { _ in Self.event() }
    for event in events { await full.append(event) }
    #expect(Self.lines(file).count <= 5_500)

    let server = Server()
    let reopened = ActivityLog(fileURL: file, send: server.send)
    await reopened.flush()
    await reopened.sending?.value
    #expect(server.batches.value.flatMap { $0 } == Array(events.suffix(5_000)))
  }

  @Test func offOrAMockAPIWithoutAnActivityURLDisablesLogging() {
    #expect(ActivityClient.isEnabled(environment: [:]))
    #expect(!ActivityClient.isEnabled(environment: ["LA_CARTE_ACTIVITY": "off"]))
    #expect(!ActivityClient.isEnabled(environment: ["LA_CARTE_ACTIVITY": "off", "LA_CARTE_API_URL": "http://a.b"]))
    for mode in ["mock", "mock-notes", "mock-lengths"] {
      #expect(!ActivityClient.isEnabled(environment: ["LA_CARTE_API": mode]))
      #expect(
        ActivityClient.isEnabled(environment: ["LA_CARTE_API": mode, "LA_CARTE_ACTIVITY_URL": "http://127.0.0.1:9"])
      )
      #expect(
        !ActivityClient.isEnabled(
          environment: ["LA_CARTE_API": mode, "LA_CARTE_ACTIVITY_URL": "http://127.0.0.1:9", "LA_CARTE_ACTIVITY": "off"]
        )
      )
    }
  }

  // MARK: Helpers

  private static func event(_ kind: String = "card_shown") -> ActivityEvent {
    ActivityEvent(
      id: UUID(), kind: kind, at: Date(), timeZone: .gmt, session: UUID(), appVersion: "1.0", build: "1",
      os: "iOS 26.1", cardID: nil, data: [:]
    )
  }

  private static func newFile() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "activity-\(UUID())").appending(path: "activity.jsonl")
  }

  private static func lines(_ file: URL) -> [ActivityEvent] {
    let data = (try? Data(contentsOf: file)) ?? Data()
    return data.split(separator: UInt8(ascii: "\n")).compactMap { try? JSONDecoder().decode(ActivityEvent.self, from: $0) }
  }
}

/// A fake `POST /activity`: records each batch, throws the queued failures in order, and can hold each request
/// until the test releases it.
private struct Server: Sendable {
  let batches = LockIsolated<[[ActivityEvent]]>([])
  let failures: LockIsolated<[any Error]>
  let maxInFlight = LockIsolated(0)
  private let inFlight = LockIsolated(0)
  private let isHeld: Bool
  private let calls = AsyncStream.makeStream(of: Void.self)
  private let releases = AsyncStream.makeStream(of: Void.self)

  init(failures: [any Error] = [], isHeld: Bool = false) {
    self.failures = LockIsolated(failures)
    self.isHeld = isHeld
  }

  func send(_ batch: [ActivityEvent]) async throws {
    inFlight.withValue { $0 += 1 }
    maxInFlight.setValue(max(maxInFlight.value, inFlight.value))
    defer { inFlight.withValue { $0 -= 1 } }
    batches.withValue { $0.append(batch) }
    calls.continuation.yield()
    if isHeld {
      for await _ in releases.stream { break }
    }
    let failure = failures.withValue { $0.isEmpty ? nil : $0.removeFirst() }
    if let failure { throw failure }
  }

  /// Waits for the next request to reach the server.
  func nextCall() async {
    for await _ in calls.stream { break }
  }

  func release() {
    releases.continuation.yield()
  }
}
