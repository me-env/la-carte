import APIClient
import ActivityClient
import ComposableArchitecture
import Foundation

extension StudyFeature {
  /// What the activity log saw after the previous action (spec 029): when the visible card was shown and revealed,
  /// and whether a request was already in flight. Always equal, so logging never changes the state tests compare.
  struct ActivityTrail: Equatable {
    var shownCardID: Card.ID?
    var shownAt: Date?
    var revealedAt: Date?
    var isReviewing = false
    var reportReason: ReportReason?

    static func == (_: Self, _: Self) -> Bool { true }
  }

  /// Runs after the core reducer: logs what `action` did, without changing anything a view reads.
  var activityLogging: some ReducerOf<Self> {
    Reduce { state, action in
      let events = activityEvents(action, &state)
      guard !events.isEmpty else { return .none }
      return .run { [activity] _ in
        for event in events { activity.log(event) }
      }
    }
  }

  /// The events `action` produced, in order, ending with `card_shown` when the visible card changed.
  private func activityEvents(_ action: Action, _ state: inout State) -> [Activity] {
    let now = activity.now()
    let trail = state.activityTrail
    // A rating or a report was sent by this action (both set `isReviewing`).
    let isNewRequest = state.isReviewing && !trail.isReviewing
    var events: [Activity] = []

    func rated(_ rating: Rating?, input: Activity.RatingInput) {
      guard isNewRequest, let rating, let card = state.cards.first else { return }
      events.append(
        .rated(
          cardID: card.id, rating: rating, input: input,
          msToReveal: Self.milliseconds(from: trail.shownAt, to: trail.revealedAt),
          msToRate: Self.milliseconds(from: trail.revealedAt, to: now)
        )
      )
    }

    switch action {
    case .scenePhaseChanged(.active):
      events.append(.appForeground)
    case .scenePhaseChanged(.background):
      events.append(.appBackground)
    case let .queueResponse(.success(queue), _):
      let stats = queue.stats
      events.append(
        .queueFetched(
          count: queue.cards.count, due: stats.due, new: stats.new, total: stats.total, nextDue: stats.nextDue
        )
      )
    case let .queueResponse(.failure(error), _):
      events.append(.failed(.queue, error))
    case let .ladderResponse(.failure(error), _):
      events.append(.failed(.stats, error))
    case .revealTapped, .cardTapped:
      guard state.isRevealed, trail.revealedAt == nil, let cardID = trail.shownCardID else { break }
      state.activityTrail.revealedAt = now
      events.append(.answerRevealed(cardID: cardID, msSinceShown: Self.milliseconds(from: trail.shownAt, to: now)))
    case let .ratingTapped(rating):
      rated(rating, input: .button)
    case .swipeEnded:
      rated(state.releasedRating, input: .drag)
    case let .reviewResponse(.failure(error)):
      events.append(.failed(.review, cardID: state.cards.first?.id, error))
    case let .reportReasonTapped(reason) where isNewRequest:
      state.activityTrail.reportReason = reason
    case .reportCommentSubmitted where isNewRequest:
      state.activityTrail.reportReason = .other
    case let .reportResponse(.success, cardID):
      events.append(.reportSent(cardID: cardID, reason: trail.reportReason ?? .other))
    case let .reportResponse(.failure(error), cardID):
      events.append(.failed(.report, cardID: cardID, error))
    case let .photoLoadFailed(cardID, _, side):
      events.append(.photoFailed(cardID: cardID, side: side == .front ? .front : .back))
    case let .brokenPhotoReportResponse(.success, cardID):
      events.append(.reportSent(cardID: cardID, reason: .brokenPhoto))
    case let .brokenPhotoReportResponse(.failure(error), cardID):
      events.append(.failed(.report, cardID: cardID, error))
    case let .editSaveResponse(.success(card), _):
      events.append(.noteEdited(noteID: card.noteId, cardID: card.id, source: .inline))
    case let .editSaveResponse(.failure(error), previous):
      events.append(.failed(.updateCard, cardID: previous.id, error))
    default:
      break
    }

    let visible = state.phase == .studying ? state.cards.first : nil
    if visible?.id != trail.shownCardID {
      state.activityTrail.shownCardID = visible?.id
      state.activityTrail.shownAt = now
      state.activityTrail.revealedAt = nil
      if let visible {
        events.append(.cardShown(cardID: visible.id, noteID: visible.noteId, type: visible.type, prompt: visible.prompt))
      }
    }
    state.activityTrail.isReviewing = state.isReviewing
    return events
  }

  private static func milliseconds(from start: Date?, to end: Date?) -> Int? {
    guard let start, let end else { return nil }
    return Int((end.timeIntervalSince(start) * 1000).rounded())
  }
}
