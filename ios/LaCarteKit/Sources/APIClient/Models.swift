import Foundation

/// A flashcard, as returned by the la-carte API. Scheduling (FSRS) is computed server-side.
public struct Card: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
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

  public init(
    id: UUID,
    front: String,
    back: String,
    state: State = .new,
    due: Date,
    lastReview: Date? = nil,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.front = front
    self.back = back
    self.state = state
    self.due = due
    self.lastReview = lastReview
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum Rating: String, Codable, CaseIterable, Sendable {
  case again, hard, good, easy
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
