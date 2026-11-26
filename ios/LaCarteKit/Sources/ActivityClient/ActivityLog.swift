import APIClient
import Foundation

/// Owns the activity buffer file and its uploader, off the main actor (spec 029 decisions 4-8).
/// The file (JSON Lines) is the durable copy; `events` mirrors it in memory, capped at `cap`, oldest first.
actor ActivityLog {
  private let fileURL: URL
  private let cap: Int
  private let clock: any Clock<Duration>
  private let isConfigured: @Sendable () -> Bool
  private let send: @Sendable ([ActivityEvent]) async throws -> Void

  private var events: [ActivityEvent]
  /// Lines in the file: it holds more than `events` until the next rewrite, so trimming isn't paid on every append.
  private var fileLines: Int
  /// The send loop in flight: at most one request at a time.
  private(set) var sending: Task<Void, Never>?
  /// The delay before the pending retry; nil when the last send succeeded.
  private(set) var backoff: Duration?
  private var retry: Task<Void, Never>?
  private var ageTimer: Task<Void, Never>?

  static let batchSize = 200
  static let flushCount = 25
  static let maxAge: Duration = .seconds(60)
  static let firstBackoff: Duration = .seconds(30)
  static let maxBackoff: Duration = .seconds(15 * 60)
  /// Answers that can never succeed: the batch is dropped instead of retried.
  static let unsendable: Set<Int> = [400, 413, 422]

  init(
    fileURL: URL,
    cap: Int = 5_000,
    clock: any Clock<Duration> = ContinuousClock(),
    isConfigured: @escaping @Sendable () -> Bool = { true },
    send: @escaping @Sendable ([ActivityEvent]) async throws -> Void
  ) {
    self.fileURL = fileURL
    self.cap = cap
    self.clock = clock
    self.isConfigured = isConfigured
    self.send = send
    let lines = ((try? Data(contentsOf: fileURL)) ?? Data()).split(separator: UInt8(ascii: "\n"))
    let decoder = JSONDecoder()
    events = lines.compactMap { try? decoder.decode(ActivityEvent.self, from: $0) }.suffix(cap)
    fileLines = lines.count
  }

  /// Flushes once (launch), then buffers every logged event.
  func run(_ stream: AsyncStream<ActivityEvent>) async {
    flush()
    for await event in stream {
      append(event)
    }
  }

  func append(_ event: ActivityEvent) {
    events.append(event)
    if events.count > cap { events.removeFirst(events.count - cap) }
    if fileLines >= cap + cap / 10 {
      rewriteFile()
    } else {
      appendLine(event)
    }
    switch event.kind {
    case "app_foreground":
      retry?.cancel()
      retry = nil
      backoff = nil
      flush()
    case "app_background":
      flush()
    default:
      if events.count >= Self.flushCount { flush() } else { armAgeTimer() }
    }
  }

  /// Starts the send loop unless one is in flight, a retry is pending or there's no server to send to.
  func flush() {
    guard sending == nil, retry == nil, !events.isEmpty, isConfigured() else { return }
    sending = Task {
      await sendAll()
      sending = nil
    }
  }

  /// Batches of `batchSize`, oldest first, until the buffer is empty or a send fails.
  private func sendAll() async {
    while !events.isEmpty {
      let batch = Array(events.prefix(Self.batchSize))
      do {
        try await send(batch)
      } catch let error as APIError where Self.unsendable.contains(error.statusCode) {
        // Dropped below like a sent batch: retrying would fail forever and block the queue.
      } catch {
        scheduleRetry()
        return
      }
      let sent = Set(batch.map(\.id))
      events.removeAll { sent.contains($0.id) }
      rewriteFile()
    }
    backoff = nil
  }

  private func scheduleRetry() {
    let delay = backoff.map { min($0 * 2, Self.maxBackoff) } ?? Self.firstBackoff
    backoff = delay
    retry = Task { [clock] in
      do { try await clock.sleep(for: delay) } catch { return }
      retry = nil
      flush()
    }
  }

  private func armAgeTimer() {
    guard ageTimer == nil else { return }
    ageTimer = Task { [clock] in
      try? await clock.sleep(for: Self.maxAge)
      ageTimer = nil
      flush()
    }
  }

  private func appendLine(_ event: ActivityEvent) {
    guard let handle = try? FileHandle(forWritingTo: fileURL) else { return rewriteFile() }
    defer { try? handle.close() }
    guard let line = try? JSONEncoder().encode(event) else { return }
    do {
      try handle.seekToEnd()
      try handle.write(contentsOf: line + [UInt8(ascii: "\n")])
      fileLines += 1
    } catch {
      rewriteFile()
    }
  }

  private func rewriteFile() {
    let encoder = JSONEncoder()
    let lines = events.compactMap { try? encoder.encode($0) + [UInt8(ascii: "\n")] }
    try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(lines.joined()).write(to: fileURL, options: .atomic)
    fileLines = lines.count
  }
}
