import Foundation

/// One activity event as `POST /activity` takes it and as the app's buffer file stores it (spec 029).
/// `at` is formatted once, at log time, in the device's zone: `2026-11-25T10:14:03.120+01:00`.
public struct ActivityEvent: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var kind: String
  public var at: String
  public var tz: String
  public var session: UUID
  public var appVersion: String
  public var build: String
  public var os: String
  public var cardID: UUID?
  public var data: [String: JSONValue]

  public init(
    id: UUID, kind: String, at date: Date, timeZone: TimeZone, session: UUID, appVersion: String, build: String,
    os: String, cardID: UUID?, data: [String: JSONValue]
  ) {
    self.id = id
    self.kind = kind
    self.at = date.formatted(
      Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true, timeZone: timeZone)
    )
    self.tz = timeZone.identifier
    self.session = session
    self.appVersion = appVersion
    self.build = build
    self.os = os
    self.cardID = cardID
    self.data = data
  }

  enum CodingKeys: String, CodingKey {
    case id, kind, at, tz, session, build, os, data
    case appVersion = "app_version"
    case cardID = "card_id"
  }

  /// Synthesized encoding would leave out a nil `card_id`; the contract sends it as null.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(kind, forKey: .kind)
    try container.encode(at, forKey: .at)
    try container.encode(tz, forKey: .tz)
    try container.encode(session, forKey: .session)
    try container.encode(appVersion, forKey: .appVersion)
    try container.encode(build, forKey: .build)
    try container.encode(os, forKey: .os)
    try container.encode(cardID, forKey: .cardID)
    try container.encode(data, forKey: .data)
  }
}

/// The values an activity event's `data` holds: ids, enums, counts, durations, field names.
public enum JSONValue: Codable, Equatable, Sendable {
  case string(String)
  case int(Int)
  case bool(Bool)
  case array([JSONValue])
  case null

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let bool = try? container.decode(Bool.self) {
      self = .bool(bool)
    } else if let int = try? container.decode(Int.self) {
      self = .int(int)
    } else if let string = try? container.decode(String.self) {
      self = .string(string)
    } else {
      self = .array(try container.decode([JSONValue].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case let .string(value): try container.encode(value)
    case let .int(value): try container.encode(value)
    case let .bool(value): try container.encode(value)
    case let .array(value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}
