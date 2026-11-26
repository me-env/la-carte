import APIClient
import Foundation

/// What the user did, as features log it (spec 029): ids, enums, counts and durations, never the user's text.
public enum Activity: Equatable, Sendable {
  case appForeground, appBackground
  case queueFetched(count: Int, due: Int, new: Int, total: Int, nextDue: Date?)
  case cardShown(cardID: Card.ID, noteID: Note.ID, type: NoteType, prompt: [String])
  case answerRevealed(cardID: Card.ID, msSinceShown: Int?)
  case rated(cardID: Card.ID, rating: Rating, input: RatingInput, msToReveal: Int?, msToRate: Int?)
  case reportSent(cardID: Card.ID, reason: ReportReason)
  case photoFailed(cardID: Card.ID, side: Side)
  case noteCreated(noteID: Note.ID, type: NoteType, directions: Int)
  case noteEdited(noteID: Note.ID, cardID: Card.ID?, source: EditSource)
  case noteDeleted(noteID: Note.ID)
  case deckLoaded(count: Int, query: Bool)
  case apiError(request: Request, cardID: Card.ID?, status: Int, error: String)

  public enum RatingInput: String, Sendable {
    case button, drag
  }

  public enum Side: String, Sendable {
    case front, back
  }

  public enum EditSource: String, Sendable {
    case editor, inline
  }

  /// The failed request of an `api_error`.
  public enum Request: String, Sendable {
    case queue, stats, review, report, notes
    case updateCard = "update_card"
    case addNote = "add_note"
    case updateNote = "update_note"
    case deleteNote = "delete_note"
  }

  /// An `api_error` for `error`: the HTTP status (0 without a response) and the `URLError` code name or the start
  /// of the server's `detail`.
  public static func failed(_ request: Request, cardID: Card.ID? = nil, _ error: any Error) -> Activity {
    let (status, description): (Int, String) =
      switch error {
      case let error as APIError: (error.statusCode, Self.detail(error.message))
      case let error as URLError: (0, Self.name(error.code))
      default: (0, String(describing: type(of: error)))
      }
    return .apiError(request: request, cardID: cardID, status: status, error: String(description.prefix(200)))
  }

  var kind: String {
    switch self {
    case .appForeground: "app_foreground"
    case .appBackground: "app_background"
    case .queueFetched: "queue_fetched"
    case .cardShown: "card_shown"
    case .answerRevealed: "answer_revealed"
    case .rated: "rated"
    case .reportSent: "report_sent"
    case .photoFailed: "photo_failed"
    case .noteCreated: "note_created"
    case .noteEdited: "note_edited"
    case .noteDeleted: "note_deleted"
    case .deckLoaded: "deck_loaded"
    case .apiError: "api_error"
    }
  }

  var cardID: Card.ID? {
    switch self {
    case let .cardShown(cardID, _, _, _), let .answerRevealed(cardID, _), let .rated(cardID, _, _, _, _),
      let .reportSent(cardID, _), let .photoFailed(cardID, _):
      cardID
    case let .noteEdited(_, cardID, _), let .apiError(_, cardID, _, _):
      cardID
    case .appForeground, .appBackground, .queueFetched, .noteCreated, .noteDeleted, .deckLoaded:
      nil
    }
  }

  var data: [String: JSONValue] {
    switch self {
    case .appForeground, .appBackground:
      [:]
    case let .queueFetched(count, due, new, total, nextDue):
      [
        "count": .int(count), "due": .int(due), "new": .int(new), "total": .int(total),
        "next_due": nextDue.map { .string($0.formatted(.iso8601)) } ?? .null,
      ]
    case let .cardShown(_, noteID, type, prompt):
      ["note_id": .string(noteID.uuidString), "type": .string(type.rawValue), "prompt": .array(prompt.map(JSONValue.string))]
    case let .answerRevealed(_, msSinceShown):
      ["ms_since_shown": .number(msSinceShown)]
    case let .rated(_, rating, input, msToReveal, msToRate):
      [
        "rating": .string(rating.rawValue), "input": .string(input.rawValue),
        "ms_to_reveal": .number(msToReveal), "ms_to_rate": .number(msToRate),
      ]
    case let .reportSent(_, reason):
      ["reason": .string(reason.rawValue)]
    case let .photoFailed(_, side):
      ["side": .string(side.rawValue)]
    case let .noteCreated(noteID, type, directions):
      ["note_id": .string(noteID.uuidString), "type": .string(type.rawValue), "directions": .int(directions)]
    case let .noteEdited(noteID, _, source):
      ["note_id": .string(noteID.uuidString), "source": .string(source.rawValue)]
    case let .noteDeleted(noteID):
      ["note_id": .string(noteID.uuidString)]
    case let .deckLoaded(count, query):
      ["count": .int(count), "query": .bool(query)]
    case let .apiError(request, _, status, error):
      ["request": .string(request.rawValue), "status": .int(status), "error": .string(error)]
    }
  }

  /// The server's `{"detail": "…"}` message, or nothing when it has no string detail: other bodies (a 422's `input`)
  /// can echo the user's text.
  private static func detail(_ body: String) -> String {
    struct Body: Decodable { var detail: String }
    return (try? JSONDecoder().decode(Body.self, from: Data(body.utf8)).detail) ?? ""
  }

  private static func name(_ code: URLError.Code) -> String {
    switch code {
    case .notConnectedToInternet: "notConnectedToInternet"
    case .timedOut: "timedOut"
    case .cannotConnectToHost: "cannotConnectToHost"
    case .cannotFindHost: "cannotFindHost"
    case .networkConnectionLost: "networkConnectionLost"
    case .dataNotAllowed: "dataNotAllowed"
    case .secureConnectionFailed: "secureConnectionFailed"
    case .cancelled: "cancelled"
    case .unsupportedURL: "unsupportedURL"
    default: "URLError \(code.rawValue)"
    }
  }
}

extension JSONValue {
  fileprivate static func number(_ value: Int?) -> JSONValue {
    value.map(JSONValue.int) ?? .null
  }
}
