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
  /// The card Study serves first and when (spec 028); `nil` when every card is held by a report.
  public var next: Next?
  public var createdAt: Date
  public var updatedAt: Date

  /// The server's pick of the note's next card in the study queue.
  public struct Next: Codable, Equatable, Sendable {
    public var cardId: UUID
    public var readyAt: Date

    public init(cardId: UUID, readyAt: Date) {
      self.cardId = cardId
      self.readyAt = readyAt
    }
  }

  public init(
    id: UUID,
    type: NoteType,
    fields: [String: String],
    cards: [Card],
    next: Next? = nil,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.type = type
    self.fields = fields
    self.cards = cards
    self.next = next
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  /// `next: null` means reported. A server older than spec 028 sends no `next` key: the earliest-due card stands in,
  /// since a decoded `nil` would read as reported.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let cards = try container.decode([Card].self, forKey: .cards)
    let next =
      container.contains(.next)
      ? try container.decodeIfPresent(Next.self, forKey: .next)
      : cards.min { $0.due < $1.due }.map { Next(cardId: $0.id, readyAt: $0.due) }
    try self.init(
      id: container.decode(UUID.self, forKey: .id),
      type: container.decode(NoteType.self, forKey: .type),
      fields: container.decode([String: String].self, forKey: .fields),
      cards: cards,
      next: next,
      createdAt: container.decode(Date.self, forKey: .createdAt),
      updatedAt: container.decode(Date.self, forKey: .updatedAt)
    )
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

/// The deck's counts and study history, as `/stats` returns them for the device's time zone (specs 007, 024).
public struct DeckStats: Equatable, Sendable {
  public var total: Int
  public var due: Int
  public var new: Int
  public var reviewedToday: Int
  /// When the next card that isn't due yet becomes due; `nil` if there is none.
  public var nextDue: Date?
  /// Days in the current run, frozen days included, ending today or yesterday (spec 024 decision 4).
  public var streak: Int
  /// New cards introduced today and the size of a batch of new cards (spec 021).
  public var newToday: Int
  public var milestone: Int
  /// The never-reviewed cards among `due`.
  public var dueNew: Int
  /// The day's ladder steps "At risk" and "Reviews" (spec 021 decision 5); a total of 0 = no such step today.
  public var atRiskTotal: Int
  public var atRiskDone: Int
  public var reviewsTotal: Int
  public var reviewsDone: Int
  /// One letter per local day from `historyStart` to today: `s` studied, `f` frozen, `m` missed, `p` today not yet
  /// studied.
  public var history: String
  /// Local midnights in the device's time zone (`yyyy-MM-dd` on the wire).
  public var historyStart: Date
  public var streakStart: Date?

  /// The history defaults describe a deck with no reviews whose today is unknown; only the widget's grid reads them.
  public init(
    total: Int,
    due: Int,
    new: Int,
    reviewedToday: Int,
    nextDue: Date?,
    streak: Int = 0,
    newToday: Int = 0,
    milestone: Int = 15,
    dueNew: Int = 0,
    atRiskTotal: Int = 0,
    atRiskDone: Int = 0,
    reviewsTotal: Int = 0,
    reviewsDone: Int = 0,
    history: String = "p",
    historyStart: Date = .distantPast,
    streakStart: Date? = nil
  ) {
    self.total = total
    self.due = due
    self.new = new
    self.reviewedToday = reviewedToday
    self.nextDue = nextDue
    self.streak = streak
    self.newToday = newToday
    self.milestone = milestone
    self.dueNew = dueNew
    self.atRiskTotal = atRiskTotal
    self.atRiskDone = atRiskDone
    self.reviewsTotal = reviewsTotal
    self.reviewsDone = reviewsDone
    self.history = history
    self.historyStart = historyStart
    self.streakStart = streakStart
  }

  /// The count Study shows (spec 021 decision 6): due reviews, plus new cards up to the end of today's batch.
  public var toReview: Int {
    let batchLeft = milestone > 0 ? milestone - newToday % milestone : dueNew
    return (due - dueNew) + min(dueNew, batchLeft)
  }

  /// Calendar days in the device's time zone, in the Gregorian calendar whatever the user's calendar setting.
  public static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar
  }
}

extension DeckStats: Codable {
  enum CodingKeys: String, CodingKey {
    case total, due, new, reviewedToday, nextDue, streak, newToday, milestone, dueNew, history, historyStart
    case streakStart, atRiskTotal, atRiskDone, reviewsTotal, reviewsDone
  }

  /// The dates are `yyyy-MM-dd` days. A missing ladder count reads as 0 (`milestone` as 15), spec 021's defaults,
  /// so an older server still decodes.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      total: container.decode(Int.self, forKey: .total),
      due: container.decode(Int.self, forKey: .due),
      new: container.decode(Int.self, forKey: .new),
      reviewedToday: container.decode(Int.self, forKey: .reviewedToday),
      nextDue: container.decodeIfPresent(Date.self, forKey: .nextDue),
      streak: container.decode(Int.self, forKey: .streak),
      newToday: container.decodeIfPresent(Int.self, forKey: .newToday) ?? 0,
      milestone: container.decodeIfPresent(Int.self, forKey: .milestone) ?? 15,
      dueNew: container.decodeIfPresent(Int.self, forKey: .dueNew) ?? 0,
      atRiskTotal: container.decodeIfPresent(Int.self, forKey: .atRiskTotal) ?? 0,
      atRiskDone: container.decodeIfPresent(Int.self, forKey: .atRiskDone) ?? 0,
      reviewsTotal: container.decodeIfPresent(Int.self, forKey: .reviewsTotal) ?? 0,
      reviewsDone: container.decodeIfPresent(Int.self, forKey: .reviewsDone) ?? 0,
      history: container.decode(String.self, forKey: .history),
      historyStart: Self.day(container.decode(String.self, forKey: .historyStart), forKey: .historyStart, in: container),
      streakStart: container.decodeIfPresent(String.self, forKey: .streakStart).map {
        try Self.day($0, forKey: .streakStart, in: container)
      }
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(total, forKey: .total)
    try container.encode(due, forKey: .due)
    try container.encode(new, forKey: .new)
    try container.encode(reviewedToday, forKey: .reviewedToday)
    try container.encodeIfPresent(nextDue, forKey: .nextDue)
    try container.encode(streak, forKey: .streak)
    try container.encode(newToday, forKey: .newToday)
    try container.encode(milestone, forKey: .milestone)
    try container.encode(dueNew, forKey: .dueNew)
    try container.encode(atRiskTotal, forKey: .atRiskTotal)
    try container.encode(atRiskDone, forKey: .atRiskDone)
    try container.encode(reviewsTotal, forKey: .reviewsTotal)
    try container.encode(reviewsDone, forKey: .reviewsDone)
    try container.encode(history, forKey: .history)
    try container.encode(Self.dayString(historyStart), forKey: .historyStart)
    try container.encodeIfPresent(streakStart.map(Self.dayString), forKey: .streakStart)
  }

  private static func day(
    _ string: String, forKey key: CodingKeys, in container: KeyedDecodingContainer<CodingKeys>
  ) throws -> Date {
    let parts = string.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    else {
      throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Invalid day: \(string)")
    }
    return date
  }

  private static func dayString(_ date: Date) -> String {
    let day = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
  }
}
