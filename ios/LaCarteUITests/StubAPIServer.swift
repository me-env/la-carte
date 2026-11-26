import Foundation
import Network
import UIKit

/// Tiny HTTP/1.1 server running inside the UI-test runner, used to put the app in states the in-memory
/// mock can't reach (API down then back up, slow/failing reviews, empty deck, long card text).
/// The simulator shares the host network, so the app reaches it at `http://127.0.0.1:<port>`.
final class StubAPIServer: @unchecked Sendable {
  struct Response {
    var status = 200
    var body = ""
    var delay: TimeInterval = 0
    /// Binary body (e.g. a PNG photo); wins over `body` when set.
    var data: Data? = nil
    var contentType = "application/json"
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

  /// Picked by the OS on the first start (port 0), so parallel test workers never collide; a restart reuses it.
  private(set) var port: UInt16 = 0
  var url: String { "http://127.0.0.1:\(port)" }

  private let queue = DispatchQueue(label: "qa.stub-api")
  private let lock = NSLock()
  private var listener: NWListener?
  private var _requests: [Request] = []
  private var _handler: Handler

  var requests: [Request] { lock.withLock { _requests } }
  /// `POST /cards/{id}/review` only: since spec 029 the app also POSTs `/activity`, so never count bare POSTs.
  var reviewPosts: [Request] {
    requests.filter { $0.method == "POST" && StubDeck.route($0.path).hasSuffix("/review") }
  }
  var handler: Handler {
    get { lock.withLock { _handler } }
    set { lock.withLock { _handler = newValue } }
  }

  init(handler: @escaping Handler = { _ in Response(status: 404, body: #"{"detail":"Not Found"}"#) }) {
    _handler = handler
  }

  deinit { stop() }

  func start() throws {
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    let listener = try NWListener(using: params, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
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
    port = listener.port?.rawValue ?? 0
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
    let body = response.data ?? Data(response.body.utf8)
    let head = "HTTP/1.1 \(response.status) Stub\r\nContent-Type: \(response.contentType)\r\n"
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

  /// Spec 024: `/stats` also carries `new_today`, `milestone`, `due_new` and the streak history (one letter per
  /// local day since `history_start`): here a single pending today ("p"), streak 0. Spec 021: the four ladder
  /// counts are 0 and `due_new` 0, so Study's counter falls back to the loaded batch ("N to review").
  static func stats(total: Int, nextDue: Date?) -> String {
    let next = nextDue.map { "\"\(iso($0))\"" } ?? "null"
    return #"{"total":\#(total),"due":0,"new":0,"reviewed_today":\#(total),"next_due":\#(next),"streak":0,"#
      + #""new_today":0,"milestone":15,"due_new":0,"history":"p","history_start":"\#(localDay(.now))","#
      + #""streak_start":null,"at_risk_total":0,"at_risk_done":0,"reviews_total":0,"reviews_done":0}"#
  }

  /// `yyyy-MM-dd` in the device zone (the app decodes `/stats` days as device-zone calendar days).
  static func localDay(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }
}

// MARK: - Stateful stub deck (spec 002: list / search / add / edit / delete)

/// An in-memory deck behind `StubAPIServer`, speaking the REST shape of `api/` for `/cards`, `/cards/due`,
/// `/stats`, `POST /cards`, `POST /cards/{id}/review`, `POST /cards/{id}/report` (spec 015: recorded in `reports`, the
/// card is then held out of `/cards/due`), `PATCH /cards/{id}`, `DELETE /cards/{id}` and the notes routes
/// (`GET/POST /notes`, `GET/PATCH/DELETE /notes/{id}`, spec 014), plus a made-up photo at `/photos/*.png`
/// (`/photos/broken-*` answers 404: an unreachable photo).
/// Writes can be delayed or failed.
final class StubDeck: @unchecked Sendable {
  struct Card {
    var id: String
    var front: String
    var back: String
    var state = "new"
    var due = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01: due now
    var createdAt = Date(timeIntervalSince1970: 1_767_225_600)
  }

  /// A note's direction with its own schedule (`Note.cards[]` in `api/`).
  struct NoteCard {
    var id = UUID().uuidString.lowercased()
    var prompt: [String]
    var answer: [String]
    var state = "new"
    var due = Date(timeIntervalSince1970: 1_767_225_600)
  }

  /// A note that isn't a plain `front → back` card (spec 014: person notes, extra directions). Plain basic notes
  /// stay in `cards` (a card's id is its note's id, as after migration 014).
  struct Note {
    var id = UUID().uuidString.lowercased()
    var type: String
    var fields: [String: String]
    var cards: [NoteCard]
    var createdAt = Date(timeIntervalSince1970: 1_767_225_600)
  }

  private let lock = NSLock()
  private var _cards: [Card]
  private var _notes: [Note]
  private var _writeStatus = 0  // 0 = succeed; else the HTTP status returned to writes
  private var _writeDelay: TimeInterval = 0
  private var _listStatus = 200
  private var _readDelay: TimeInterval = 0
  private var _reports: [Report] = []

  /// A `POST /cards/{id}/report` as received (spec 015). `comment` is nil when the body has no `comment` key.
  struct Report: Equatable {
    var cardID: String
    var reason: String
    var comment: String?
    var hasCommentKey: Bool
    /// Answered with `writeStatus` (an error): the card isn't held.
    var failed = false
  }

  /// Reports received, in order (failed writes included: `writeStatus` doesn't stop the recording).
  var reports: [Report] { lock.withLock { _reports } }

  init(_ cards: [Card], notes: [Note] = []) {
    _cards = cards
    _notes = notes
  }

  /// Spec 006: simulates an agent adding / another device removing a card while the app is open.
  func add(_ card: Card) { lock.withLock { _cards.append(card) } }
  func remove(id: String) { lock.withLock { _cards.removeAll { $0.id.lowercased() == id.lowercased() } } }
  /// Delay applied to the GET routes (`/cards`, `/cards/due`, `/stats`), to observe a refresh in flight.
  var readDelay: TimeInterval { get { lock.withLock { _readDelay } } set { lock.withLock { _readDelay = newValue } } }

  var cards: [Card] { lock.withLock { _cards } }
  var notes: [Note] { lock.withLock { _notes } }
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
    if let photo = StubPhoto.response(request) { return photo }
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
      // Spec 015: a reported card is held out of study (every report here stays open).
      let held = Set(_reports.filter { !$0.failed }.map(\.cardID))
      let due = _cards.filter { $0.due <= now && !held.contains($0.id.lowercased()) }.map { ($0.due, Self.json($0)) }
        + _notes.flatMap { n in
          n.cards.filter { $0.due <= now && !held.contains($0.id.lowercased()) }.map { ($0.due, Self.cardJSON(n, $0)) }
        }
      return .init(body: StubJSON.cards(due.sorted { $0.0 < $1.0 }.map(\.1)))
    case ("GET", "/stats"):
      let dues = _cards.map(\.due) + _notes.flatMap { $0.cards.map(\.due) }
      let next = dues.filter { $0 > now }.min()
      return .init(body: StubJSON.stats(total: dues.count, nextDue: dues.isEmpty ? nil : next ?? now.addingTimeInterval(86_400)))
    case ("POST", "/cards"):
      if _writeStatus != 0 { return .init(status: _writeStatus, body: #"{"detail":"boom"}"#, delay: _writeDelay) }
      let card = Card(id: UUID().uuidString.lowercased(), front: body["front"] as? String ?? "",
                      back: body["back"] as? String ?? "", due: now, createdAt: now)
      _cards.append(card)
      return .init(status: 201, body: Self.json(card), delay: _writeDelay)
    case ("POST", let r) where r.hasPrefix("/cards/") && r.hasSuffix("/report"):
      let id = String(r.dropFirst("/cards/".count).dropLast("/report".count)).lowercased()
      let report = Report(cardID: id, reason: body["reason"] as? String ?? "", comment: body["comment"] as? String,
                          hasCommentKey: body.keys.contains("comment"), failed: _writeStatus != 0)
      _reports.append(report)
      if report.failed { return .init(status: _writeStatus, body: #"{"detail":"boom"}"#, delay: _writeDelay) }
      let object: [String: Any] = [
        "id": _reports.count, "card_id": id, "note_id": id, "reason": report.reason,
        "comment": report.comment ?? NSNull(), "status": "open", "resolution": NSNull(),
        "created_at": StubJSON.iso(now), "updated_at": StubJSON.iso(now), "resolved_at": NSNull(), "card": NSNull(),
      ]
      let json = String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
      return .init(status: 201, body: json, delay: _writeDelay)
    case ("POST", let r) where r.hasPrefix("/cards/") && r.hasSuffix("/review"):
      if _writeStatus != 0 { return .init(status: _writeStatus, body: #"{"detail":"boom"}"#, delay: _writeDelay) }
      let id = String(r.dropFirst("/cards/".count).dropLast("/review".count)).lowercased()
      if let n = _notes.firstIndex(where: { $0.cards.contains { $0.id == id } }),
         let c = _notes[n].cards.firstIndex(where: { $0.id == id }) {
        _notes[n].cards[c].state = "review"
        _notes[n].cards[c].due = now.addingTimeInterval(86_400)
        return .init(body: Self.cardJSON(_notes[n], _notes[n].cards[c]), delay: _writeDelay)
      }
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
    case ("GET", "/notes"):
      guard _listStatus == 200 else { return .init(status: _listStatus, body: #"{"detail":"boom"}"#) }
      let items = Self.queryItems(request.path)
      let query = (items["query"] ?? "").lowercased()
      let matches = allNotes()
        .sorted { $0.createdAt > $1.createdAt }
        .filter { n in items["type"].map { t in t.isEmpty || n.type == t } ?? true }
        .filter { n in query.isEmpty || n.fields.contains { $0.key != "photo" && $0.value.lowercased().contains(query) } }
      return .init(body: "[" + matches.map(Self.noteJSON).joined(separator: ",") + "]")
    case ("POST", "/notes"):
      if _writeStatus != 0 { return .init(status: _writeStatus, body: #"{"detail":"boom"}"#, delay: _writeDelay) }
      let fields = (body["fields"] as? [String: String] ?? [:]).filter { !$0.value.isEmpty }
      let note = Note(type: body["type"] as? String ?? "basic", fields: fields,
                      cards: Self.directions(body["directions"], fields: fields, type: body["type"] as? String ?? "basic")
                        .map { NoteCard(prompt: $0.0, answer: $0.1, due: now) },
                      createdAt: now)
      store(note)
      return .init(status: 201, body: Self.noteJSON(note), delay: _writeDelay)
    case (let method, let r) where r.hasPrefix("/notes/"):
      let id = String(r.dropFirst("/notes/".count)).lowercased()
      guard var note = allNotes().first(where: { $0.id.lowercased() == id }) else {
        return .init(status: 404, body: #"{"detail":"Note not found"}"#)
      }
      if method == "GET" { return .init(body: Self.noteJSON(note)) }
      if _writeStatus != 0 { return .init(status: _writeStatus, body: #"{"detail":"boom"}"#, delay: _writeDelay) }
      removeNote(id)
      if method == "DELETE" { return .init(status: 204, body: "", delay: _writeDelay) }
      for (key, value) in body["fields"] as? [String: String] ?? [:] { note.fields[key] = value.isEmpty ? nil : value }
      if body["directions"] != nil {
        let wanted = Self.directions(body["directions"], fields: note.fields, type: note.type)
        note.cards = wanted.map { d in
          note.cards.first { $0.prompt == d.0 } .map { var c = $0; c.answer = d.1; return c }
            ?? NoteCard(prompt: d.0, answer: d.1, due: now)
        }
      }
      store(note)
      return .init(body: Self.noteJSON(note), delay: _writeDelay)
    default:
      return .init(status: 404, body: #"{"detail":"Not Found"}"#)
    }
  }

  // MARK: Notes (spec 014)

  /// Caller holds `lock`. Plain cards as basic notes (id = card id) + the other notes.
  private func allNotes() -> [Note] {
    _cards.map { c in
      Note(id: c.id, type: "basic", fields: ["front": c.front, "back": c.back],
           cards: [NoteCard(id: c.id, prompt: ["front"], answer: ["back"], state: c.state, due: c.due)],
           createdAt: c.createdAt)
    } + _notes
  }

  /// Caller holds `lock`. A basic note with exactly its own `front → back` card is kept as a plain card.
  private func store(_ note: Note) {
    if note.type == "basic", note.cards.count == 1, let c = note.cards.first,
       c.prompt == ["front"], c.answer == ["back"] {
      _cards.append(Card(id: note.id, front: note.fields["front"] ?? "", back: note.fields["back"] ?? "",
                         state: c.state, due: c.due, createdAt: note.createdAt))
    } else {
      _notes.append(note)
    }
  }

  /// Caller holds `lock`.
  private func removeNote(_ id: String) {
    _cards.removeAll { $0.id.lowercased() == id }
    _notes.removeAll { $0.id.lowercased() == id }
  }

  /// `[{prompt: [field], answer?: [fields]}]`; a missing answer = every other non-empty field (type order).
  static func directions(_ raw: Any?, fields: [String: String], type: String) -> [([String], [String])] {
    let order = type == "person" ? ["photo", "name", "description"] : ["front", "back"]
    return (raw as? [[String: Any]] ?? [["prompt": [order[type == "person" ? 1 : 0]]]]).map { d in
      let prompt = d["prompt"] as? [String] ?? []
      let answer = d["answer"] as? [String]
        ?? order.filter { !prompt.contains($0) && !(fields[$0] ?? "").isEmpty }
      return (prompt, answer)
    }
  }

  static func noteJSON(_ n: Note) -> String {
    let cards: [[String: Any]] = n.cards.map {
      ["id": $0.id, "prompt": $0.prompt, "answer": $0.answer, "state": $0.state,
       "due": StubJSON.iso($0.due), "last_review": NSNull()]
    }
    let object: [String: Any] = [
      "id": n.id, "type": n.type, "fields": n.fields, "cards": cards,
      "created_at": StubJSON.iso(n.createdAt), "updated_at": StubJSON.iso(n.createdAt),
    ]
    return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
  }

  /// A note's card in `/cards/due` shape (`CardRead`: note fields + `front`/`back` text of each side).
  static func cardJSON(_ n: Note, _ c: NoteCard) -> String {
    let side = { (names: [String]) in names.compactMap { n.fields[$0] }.joined(separator: "\n") }
    let object: [String: Any] = [
      "id": c.id, "note_id": n.id, "type": n.type, "prompt": c.prompt, "answer": c.answer, "fields": n.fields,
      "front": side(c.prompt), "back": side(c.answer), "state": c.state, "due": StubJSON.iso(c.due),
      "last_review": NSNull(), "created_at": StubJSON.iso(n.createdAt), "updated_at": StubJSON.iso(n.createdAt),
    ]
    return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
  }
}

// MARK: - Made-up person photo (never a real person)

enum StubPhoto {
  /// A 400×500 PNG: a soft gradient with a generic head-and-shoulders silhouette. Served by `StubAPIServer` at
  /// `/photos/<anything>.png` via `StubPhoto.response`.
  static let png: Data = {
    let size = CGSize(width: 400, height: 500)
    return UIGraphicsImageRenderer(size: size).pngData { ctx in
      let colors = [UIColor(red: 0.55, green: 0.70, blue: 0.85, alpha: 1).cgColor,
                    UIColor(red: 0.85, green: 0.62, blue: 0.55, alpha: 1).cgColor] as CFArray
      let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
      ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
      UIColor(white: 1, alpha: 0.85).setFill()
      UIBezierPath(ovalIn: CGRect(x: 130, y: 110, width: 140, height: 160)).fill()
      UIBezierPath(ovalIn: CGRect(x: 60, y: 300, width: 280, height: 300)).fill()
    }
  }()

  static func response(_ request: StubAPIServer.Request) -> StubAPIServer.Response? {
    guard request.method == "GET", request.path.hasPrefix("/photos/") else { return nil }
    if request.path.hasPrefix("/photos/broken-") {  // spec 015b #13/#14: a photo URL that fails to load
      return .init(status: 404, body: #"{"detail":"Not Found"}"#)
    }
    return .init(data: png, contentType: "image/png")
  }
}
