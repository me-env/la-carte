import Dependencies
import Foundation

extension APIClient: DependencyKey {
  /// Key of the API URL entered in Settings, in `AppGroup.defaults`; the single place it is spelled.
  public static let urlDefaultsKey = "apiURL"

  /// Launch environment (set by UI tests, or in the Xcode scheme):
  /// - `LA_CARTE_API=mock`      → in-memory deck seeded with `[Card].fixtures` (deterministic screenshots)
  /// - `LA_CARTE_API=mock-notes` → in-memory deck seeded with `[Note].fixtures` (several directions, a person)
  /// - `LA_CARTE_API=mock-lengths` → `[Card].lengthFixtures` (short, long and very long cards first, spec 017)
  /// - `LA_CARTE_API_URL=…`     → base URL of the API, wins over the one entered in Settings (no default)
  /// - `LA_CARTE_API_TOKEN=…`   → bearer token, wins over the one entered in Settings
  /// The widget has no launch environment, so it resolves from the App Group and the Keychain only.
  public static var liveValue: APIClient {
    live(environment: ProcessInfo.processInfo.environment) { AppGroup.defaults.string(forKey: urlDefaultsKey) }
  }

  static func live(environment: [String: String], storedURL: @escaping @Sendable () -> String?) -> APIClient {
    if environment["LA_CARTE_API"] == "mock" {
      return .inMemory(cards: .fixtures)
    }
    if environment["LA_CARTE_API"] == "mock-notes" {
      return .inMemory(notes: .fixtures)
    }
    if environment["LA_CARTE_API"] == "mock-lengths" {
      return .inMemory(cards: .lengthFixtures)
    }
    return .live(
      baseURL: {
        resolvedBaseURL(environment: environment, stored: storedURL())
      },
      token: {
        resolvedToken(environment: environment, stored: TokenStore.liveValue.load)
      }
    )
  }

  /// Launch env > URL stored by Settings > none: there is no built-in server (spec 008).
  /// Only http(s) URLs with a host count; anything else is treated as unset.
  static func resolvedBaseURL(environment: [String: String], stored: String?) -> URL? {
    environment["LA_CARTE_API_URL"].flatMap(httpURL) ?? stored.flatMap(httpURL)
  }

  private static func httpURL(_ string: String) -> URL? {
    guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
      url.scheme == "http" || url.scheme == "https",
      url.host() != nil
    else { return nil }
    return url
  }

  /// Launch env > token stored by Settings > none. Empty values count as unset.
  static func resolvedToken(environment: [String: String], stored: () -> String?) -> String? {
    if let token = environment["LA_CARTE_API_TOKEN"], !token.isEmpty {
      return token
    }
    return stored().flatMap { $0.isEmpty ? nil : $0 }
  }

  /// `baseURL` and `token` are read on every request and every `isConfigured` check,
  /// so Settings changes apply without a relaunch. Tests replace `load` to capture requests.
  public static func live(
    baseURL: @escaping @Sendable () -> URL?,
    token: @escaping @Sendable () -> String?,
    load: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
      try await URLSession.shared.data(for: $0)
    }
  ) -> APIClient {
    let http = HTTP(baseURL: baseURL, token: token, load: load)
    return APIClient(
      dueCards: { limit in
        try await http.send("GET", "cards/due", query: ["limit": "\(limit)"])
      },
      updateCard: { id, front, back in
        try await http.send("PATCH", "cards/\(id)", body: ["front": front, "back": back])
      },
      review: { id, rating in
        try await http.send("POST", "cards/\(id)/review", body: ["rating": rating.rawValue])
      },
      reportCard: { id, reason, comment in
        _ = try await http.data("POST", "cards/\(id)/report", body: ReportBody(reason: reason, comment: comment))
      },
      stats: {
        try await http.send("GET", "stats", query: ["tz": TimeZone.current.identifier])
      },
      notes: { query in
        // 500 is the API max: the deck list must not be silently cut at the default 100.
        var parameters = ["limit": "500"]
        parameters["query"] = query
        return try await http.send("GET", "notes", query: parameters)
      },
      addNote: { draft in
        try await http.send("POST", "notes", body: draft)
      },
      updateNote: { id, draft in
        try await http.send("PATCH", "notes/\(id)", body: NoteUpdate(draft))
      },
      deleteNote: { id in
        _ = try await http.data("DELETE", "notes/\(id)")
      },
      isConfigured: {
        baseURL() != nil && token() != nil
      }
    )
  }
}

public struct APIError: Error, Equatable {
  public var statusCode: Int
  public var message: String

  /// The server refused the token (or its absence).
  public var isUnauthorized: Bool { statusCode == 401 || statusCode == 403 }
}

/// `PATCH /notes/{id}` body: the type is fixed at creation, and fields are merged key by key on the server,
/// so every field of the type is sent for a cleared one to be cleared.
private struct NoteUpdate: Encodable {
  var fields: [String: String]
  var directions: [Direction]

  init(_ draft: NoteDraft) {
    fields = Dictionary(uniqueKeysWithValues: draft.type.fields.map { ($0, draft.fields[$0] ?? "") })
    directions = draft.directions
  }
}

/// `POST /cards/{id}/report` body: a nil comment is left out, not sent as null.
private struct ReportBody: Encodable {
  var reason: ReportReason
  var comment: String?
}

private struct HTTP: Sendable {
  let baseURL: @Sendable () -> URL?
  let token: @Sendable () -> String?
  let load: @Sendable (URLRequest) async throws -> (Data, URLResponse)

  func send<Response: Decodable>(
    _ method: String,
    _ path: String,
    query: [String: String] = [:],
    body: (any Encodable)? = nil
  ) async throws -> Response {
    let data = try await data(method, path, query: query, body: body)
    return try JSONDecoder.api.decode(Response.self, from: data)
  }

  func data(
    _ method: String,
    _ path: String,
    query: [String: String] = [:],
    body: (any Encodable)? = nil
  ) async throws -> Data {
    guard var url = baseURL()?.appending(path: path) else { throw URLError(.unsupportedURL) }
    if !query.isEmpty {
      url.append(queryItems: query.map { URLQueryItem(name: $0.key, value: $0.value) })
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    if let token = token() {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(body)
    }

    let (data, response) = try await load(request)
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(statusCode) else {
      throw APIError(statusCode: statusCode, message: String(decoding: data, as: UTF8.self))
    }
    return data
  }
}

extension JSONDecoder {
  /// Decodes the API's JSON: snake_case keys, ISO 8601 dates with optional fractional seconds.
  static let api: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .custom { decoder in
      let string = try decoder.singleValueContainer().decode(String.self)
      let formats = [Date.ISO8601FormatStyle(includingFractionalSeconds: true), .iso8601]
      for format in formats {
        if let date = try? format.parse(string) { return date }
      }
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Invalid date: \(string)")
      )
    }
    return decoder
  }()
}
