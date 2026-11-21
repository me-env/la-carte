import Foundation

/// One direction (`prompt` → `answer` fields) of a note, as `/cards` returns it; scheduling (FSRS) is server-side.
public struct Card: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var noteId: UUID
  public var type: NoteType
  public var prompt: [String]
  public var answer: [String]
  /// The whole note's fields, not only the ones this card shows.
  public var fields: [String: String]
  public var front: String
  public var back: String
  public var state: State
  public var due: Date
  public var lastReview: Date?
  public var createdAt: Date
  public var updatedAt: Date

  public enum State: String, Codable, Sendable {
    case new, learning, review, relearning
  }

  /// Defaults describe a `basic` note's `front → back` card whose note shares the card's id (014 migration).
  public init(
    id: UUID,
    noteId: UUID? = nil,
    type: NoteType = .basic,
    prompt: [String] = ["front"],
    answer: [String] = ["back"],
    fields: [String: String]? = nil,
    front: String,
    back: String,
    state: State = .new,
    due: Date,
    lastReview: Date? = nil,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.noteId = noteId ?? id
    self.type = type
    self.prompt = prompt
    self.answer = answer
    self.fields = fields ?? ["front": front, "back": back]
    self.front = front
    self.back = back
    self.state = state
    self.due = due
    self.lastReview = lastReview
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  /// Tolerates a server older than notes (spec 014a): the missing keys get the `init` defaults.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: container.decode(UUID.self, forKey: .id),
      noteId: container.decodeIfPresent(UUID.self, forKey: .noteId),
      type: container.decodeIfPresent(NoteType.self, forKey: .type) ?? .basic,
      prompt: container.decodeIfPresent([String].self, forKey: .prompt) ?? ["front"],
      answer: container.decodeIfPresent([String].self, forKey: .answer) ?? ["back"],
      fields: container.decodeIfPresent([String: String].self, forKey: .fields),
      front: container.decode(String.self, forKey: .front),
      back: container.decode(String.self, forKey: .back),
      state: container.decode(State.self, forKey: .state),
      due: container.decode(Date.self, forKey: .due),
      lastReview: container.decodeIfPresent(Date.self, forKey: .lastReview),
      createdAt: container.decode(Date.self, forKey: .createdAt),
      updatedAt: container.decode(Date.self, forKey: .updatedAt)
    )
  }
}

/// The API's fixed set of note types (spec 014); `fields` lists each type's fields in display order.
public enum NoteType: String, Codable, CaseIterable, Sendable {
  case basic, person

  public var fields: [String] {
    switch self {
    case .basic: ["front", "back"]
    case .person: ["photo", "name", "description"]
    }
  }
}

/// Which fields a card shows as the question (`prompt`) and which ones it asks to recall (`answer`).
public struct Direction: Codable, Hashable, Sendable {
  public var prompt: [String]
  public var answer: [String]

  public init(prompt: [String], answer: [String]) {
    self.prompt = prompt
    self.answer = answer
  }
}

/// One thing the user knows (spec 014): named fields shared by its cards, one card per direction.
public struct Note: Codable, Equatable, Identifiable, Sendable {
  public typealias Card = NoteCard

  public var id: UUID
  public var type: NoteType
  public var fields: [String: String]
  public var cards: [Card]
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID,
    type: NoteType,
    fields: [String: String],
    cards: [Card],
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.type = type
    self.fields = fields
    self.cards = cards
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

/// A card as nested in a `Note`: its direction and its own schedule. Spelled `Note.Card`.
public struct NoteCard: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var prompt: [String]
  public var answer: [String]
  public var state: Card.State
  public var due: Date
  public var lastReview: Date?

  public var direction: Direction { Direction(prompt: prompt, answer: answer) }

  public init(
    id: UUID,
    prompt: [String],
    answer: [String],
    state: Card.State = .new,
    due: Date,
    lastReview: Date? = nil
  ) {
    self.id = id
    self.prompt = prompt
    self.answer = answer
    self.state = state
    self.due = due
    self.lastReview = lastReview
  }
}

/// What the note editor saves: `POST /notes` sends it whole, `PATCH /notes/{id}` sends its fields and directions.
public struct NoteDraft: Encodable, Equatable, Sendable {
  public var type: NoteType
  public var fields: [String: String]
  public var directions: [Direction]

  public init(type: NoteType, fields: [String: String], directions: [Direction]) {
    self.type = type
    self.fields = fields
    self.directions = directions
  }
}

public enum Rating: String, Codable, CaseIterable, Sendable {
  case again, hard, good, easy
}

/// Why a card was reported (spec 015). `brokenPhoto` is filed by the app only, never offered in the menu.
public enum ReportReason: String, Codable, CaseIterable, Sendable {
  case wrong, drop, doubt, rephrase, other
  case brokenPhoto = "broken_photo"
}

public struct DeckStats: Codable, Equatable, Sendable {
  public var total: Int
  public var due: Int
  public var new: Int
  public var reviewedToday: Int
  /// When the next card that isn't due yet becomes due; `nil` if there is none.
  public var nextDue: Date?
  /// Consecutive days with at least one review, ending today or yesterday, in the device's time zone (spec 007).
  public var streak: Int

  public init(total: Int, due: Int, new: Int, reviewedToday: Int, nextDue: Date?, streak: Int = 0) {
    self.total = total
    self.due = due
    self.new = new
    self.reviewedToday = reviewedToday
    self.nextDue = nextDue
    self.streak = streak
  }
}
