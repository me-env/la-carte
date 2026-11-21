import Foundation
import Network

/// Tiny HTTP/1.1 server running inside the UI-test runner, used to put the app in states the in-memory
/// mock can't reach (API down then back up, slow/failing reviews, empty deck, long card text).
/// The simulator shares the host network, so the app reaches it at `http://127.0.0.1:<port>`.
final class StubAPIServer: @unchecked Sendable {
  struct Response {
    var status = 200
    var body = ""
    var delay: TimeInterval = 0
  }

  struct Request {
    var method: String
    var path: String
    var body: String
    /// Header fields, names lowercased.
    var headers: [String: String] = [:]
    /// When the request was fully received.
    var time = Date()
  }

  typealias Handler = @Sendable (Request) -> Response

  let port: UInt16
  var url: String { "http://127.0.0.1:\(port)" }

  private let queue = DispatchQueue(label: "qa.stub-api")
  private let lock = NSLock()
  private var listener: NWListener?
  private var _requests: [Request] = []
  private var _handler: Handler

  var requests: [Request] { lock.withLock { _requests } }
  var handler: Handler {
    get { lock.withLock { _handler } }
    set { lock.withLock { _handler = newValue } }
  }

  init(handler: @escaping Handler = { _ in Response(status: 404, body: #"{"detail":"Not Found"}"#) }) {
    port = UInt16.random(in: 20_000...50_000)
    _handler = handler
  }

  deinit { stop() }

  func start() throws {
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in
      switch state {
      case .ready, .failed, .cancelled: ready.signal()
      default: break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { return }
      connection.start(queue: self.queue)
      self.receive(on: connection, buffer: Data())
    }
    listener.start(queue: queue)
    _ = ready.wait(timeout: .now() + 5)
    self.listener = listener
  }

  func stop() {
    listener?.cancel()
    listener = nil
  }

  private func receive(on connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      var buffer = buffer
      if let data { buffer.append(data) }
      if let request = Self.parse(buffer) {
        self.respond(to: request, on: connection)
      } else if isComplete || error != nil {
        connection.cancel()
      } else {
        self.receive(on: connection, buffer: buffer)
      }
    }
  }

  /// Returns the request once headers and the full body (per Content-Length) have arrived.
  private static func parse(_ data: Data) -> Request? {
    guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let head = String(decoding: data[..<separator.lowerBound], as: UTF8.self)
    let lines = head.components(separatedBy: "\r\n")
    let parts = lines.first?.split(separator: " ") ?? []
    guard parts.count >= 2 else { return nil }
    let length = lines.dropFirst()
      .first { $0.lowercased().hasPrefix("content-length:") }
      .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
    let body = data[separator.upperBound...]
    guard body.count >= length else { return nil }
    var headers: [String: String] = [:]
    for field in lines.dropFirst() {
      guard let colon = field.firstIndex(of: ":") else { continue }
      headers[field[..<colon].lowercased()] = field[field.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    return Request(method: String(parts[0]), path: String(parts[1]),
                   body: String(decoding: body.prefix(length), as: UTF8.self), headers: headers)
  }

  private func respond(to request: Request, on connection: NWConnection) {
    let handler = lock.withLock { () -> Handler in
      _requests.append(request)
      return _handler
    }
    let response = handler(request)
    let body = Data(response.body.utf8)
    let head = "HTTP/1.1 \(response.status) Stub\r\nContent-Type: application/json\r\n"
      + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    queue.asyncAfter(deadline: .now() + response.delay) {
      connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
        connection.cancel()
      })
    }
  }
}

// MARK: - API payloads (shape of `api/` CardRead / DeckStats)

enum StubJSON {
  static func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }

  static func card(id: String, front: String, back: String, state: String = "new",
                   due: String = "2026-01-01T00:00:00Z", createdAt: String = "2026-01-01T00:00:00Z") -> String {
    let object: [String: Any] = [
      "id": id, "front": front, "back": back, "state": state,
      "due": due, "last_review": NSNull(),
      "created_at": createdAt, "updated_at": createdAt,
    ]
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }

  static func cards(_ cards: [String]) -> String { "[" + cards.joined(separator: ",") + "]" }

  static func stats(total: Int, nextDue: Date?) -> String {
    let next = nextDue.map { "\"\(iso($0))\"" } ?? "null"
    return #"{"total":\#(total),"due":0,"new":0,"reviewed_today":\#(total),"next_due":\#(next),"streak":0}"#
  }
}

// MARK: - Stateful stub deck (spec 002: list / search / add / edit / delete)

/// An in-memory deck behind `StubAPIServer`, speaking the REST shape of `api/` for `/cards`, `/cards/due`,
/// `/stats`, `POST /cards`, `POST /cards/{id}/review`, `PATCH /cards/{id}` and `DELETE /cards/{id}`. Writes can be delayed or failed.
final class StubDeck: @unchecked Sendable {
  struct Card {
    var id: String
    var front: String
    var back: String
    var state = "new"
    var due = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01: due now
    var createdAt = Date(timeIntervalSince1970: 1_767_225_600)
  }

  private let lock = NSLock()
  private var _cards: [Card]
  private var _writeStatus = 0  // 0 = succeed; else the HTTP status returned to writes
  private var _writeDelay: TimeInterval = 0
  private var _listStatus = 200
  private var _readDelay: TimeInterval = 0

  init(_ cards: [Card]) { _cards = cards }

  /// Spec 006: simulates an agent adding / another device removing a card while the app is open.
  func add(_ card: Card) { lock.withLock { _cards.append(card) } }
  func remove(id: String) { lock.withLock { _cards.removeAll { $0.id.lowercased() == id.lowercased() } } }
  /// Delay applied to the GET routes (`/cards`, `/cards/due`, `/stats`), to observe a refresh in flight.
  var readDelay: TimeInterval { get { lock.withLock { _readDelay } } set { lock.withLock { _readDelay = newValue } } }

  var cards: [Card] { lock.withLock { _cards } }
  var writeStatus: Int { get { lock.withLock { _writeStatus } } set { lock.withLock { _writeStatus = newValue } } }
  var writeDelay: TimeInterval { get { lock.withLock { _writeDelay } } set { lock.withLock { _writeDelay = newValue } } }
  var listStatus: Int { get { lock.withLock { _listStatus } } set { lock.withLock { _listStatus = newValue } } }

  static func json(_ c: Card) -> String {
    StubJSON.card(id: c.id, front: c.front, back: c.back, state: c.state,
                  due: StubJSON.iso(c.due), createdAt: StubJSON.iso(c.createdAt))
  }

  /// Query items of a request path (`/cards?query=ser&limit=500`).
  static func queryItems(_ path: String) -> [String: String] {
    let items = URLComponents(string: "http://stub" + path)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
  }

  static func route(_ path: String) -> String { String(path.split(separator: "?").first ?? "") }

  func handle(_ request: StubAPIServer.Request) -> StubAPIServer.Response {
    lock.lock(); defer { lock.unlock() }
    let route = Self.route(request.path)
    let body = (try? JSONSerialization.jsonObject(with: Data(request.body.utf8))) as? [String: Any] ?? [:]
    let now = Date()
    var response = respond(request, route: route, body: body, now: now)
    if request.method == "GET" { response.delay = max(response.delay, _readDelay) }
    return response
  }

  /// Caller holds `lock`.
  private func respond(_ request: StubAPIServer.Request, route: String, body: [String: Any],
                       now: Date) -> StubAPIServer.Response {
    switch (request.method, route) {
    case ("GET", "/cards"):
      guard _listStatus == 200 else { return .init(status: _listStatus, body: #"{"detail":"boom"}"#) }
      let query = (Self.queryItems(request.path)["query"] ?? "").lowercased()
      let matches = _cards
        .sorted { $0.createdAt > $1.createdAt }
        .filter { query.isEmpty || $0.front.lowercased().contains(query) || $0.back.lowercased().contains(query) }
      return .init(body: StubJSON.cards(matches.map(Self.json)))
    case ("GET", "/cards/due"):
      let due = _cards.filter { $0.due <= now }.sorted { $0.due < $1.due }
      return .init(body: StubJSON.cards(due.map(Self.json)))
    case ("GET", "/stats"):
      let next = _cards.map(\.due).filter { $0 > now }.min()
      return .init(body: StubJSON.stats(total: _cards.count, nextDue: _cards.isEmpty ? nil : next ?? now.addingTimeInterval(86_400)))
    case ("POST", "/cards"):
      if _writeStatus != 0 { return .init(status: _writeStatus, body: #"{"detail":"boom"}"#, delay: _writeDelay) }
      let card = Card(id: UUID().uuidString.lowercased(), front: body["front"] as? String ?? "",
                      back: body["back"] as? String ?? "", due: now, createdAt: now)
      _cards.append(card)
      return .init(status: 201, body: Self.json(card), delay: _writeDelay)
    case ("POST", let r) where r.hasPrefix("/cards/") && r.hasSuffix("/review"):
      if _writeStatus != 0 { return .init(status: _writeStatus, body: #"{"detail":"boom"}"#, delay: _writeDelay) }
      let id = String(r.dropFirst("/cards/".count).dropLast("/review".count)).lowercased()
      guard let i = _cards.firstIndex(where: { $0.id.lowercased() == id }) else { return .init(status: 404, body: "{}") }
      _cards[i].state = "review"
      _cards[i].due = now.addingTimeInterval(86_400)
      return .init(body: Self.json(_cards[i]), delay: _writeDelay)
    case ("PATCH", let r) where r.hasPrefix("/cards/"):
      if _writeStatus != 0 { return .init(status: _writeStatus, body: #"{"detail":"boom"}"#, delay: _writeDelay) }
      let id = String(r.dropFirst("/cards/".count)).lowercased()
      guard let i = _cards.firstIndex(where: { $0.id.lowercased() == id }) else { return .init(status: 404, body: "{}") }
      if let front = body["front"] as? String { _cards[i].front = front }
      if let back = body["back"] as? String { _cards[i].back = back }
      return .init(body: Self.json(_cards[i]), delay: _writeDelay)
    case ("DELETE", let r) where r.hasPrefix("/cards/"):
      if _writeStatus != 0 { return .init(status: _writeStatus, body: #"{"detail":"boom"}"#, delay: _writeDelay) }
      let id = String(r.dropFirst("/cards/".count)).lowercased()
      _cards.removeAll { $0.id.lowercased() == id }
      return .init(status: 204, body: "", delay: _writeDelay)
    default:
      return .init(status: 404, body: #"{"detail":"Not Found"}"#)
    }
  }
}
