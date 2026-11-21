import Dependencies
import Foundation

extension APIClient {
  /// A fake deck held in memory, for previews and deterministic UI tests.
  /// Scheduling is deliberately naive: any review pushes the card one day out.
  public static func inMemory(cards: [Card], now: Date = Date()) -> APIClient {
    let deck = LockIsolated(cards)
    return APIClient(
      cards: { query in
        deck.value.filter { card in
          guard let query, !query.isEmpty else { return true }
          return card.front.localizedCaseInsensitiveContains(query)
            || card.back.localizedCaseInsensitiveContains(query)
        }
      },
      dueCards: { limit in
        // `sorted` is stable, so cards due at the same time keep fixture order.
        Array(deck.value.filter { $0.due <= now }.sorted { $0.due < $1.due }.prefix(limit))
      },
      addCard: { front, back in
        let card = Card(id: UUID(), front: front, back: back, due: now, createdAt: now, updatedAt: now)
        deck.withValue { $0.insert(card, at: 0) }
        return card
      },
      updateCard: { id, front, back in
        try deck.withValue { cards in
          guard let index = cards.firstIndex(where: { $0.id == id }) else { throw notFound }
          cards[index].front = front
          cards[index].back = back
          return cards[index]
        }
      },
      deleteCard: { id in
        deck.withValue { $0.removeAll { $0.id == id } }
      },
      review: { id, rating in
        try deck.withValue { cards in
          guard let index = cards.firstIndex(where: { $0.id == id }) else { throw notFound }
          cards[index].state = rating == .again ? .relearning : .review
          cards[index].lastReview = now
          cards[index].due = now.addingTimeInterval(rating == .again ? 600 : 86_400)
          return cards[index]
        }
      },
      stats: {
        let cards = deck.value
        let reviewedToday = cards.filter { $0.lastReview.map(Calendar.current.isDateInToday) ?? false }.count
        return DeckStats(
          total: cards.count,
          due: cards.filter { $0.due <= now }.count,
          new: cards.filter { $0.lastReview == nil }.count,
          reviewedToday: reviewedToday,
          nextDue: cards.map(\.due).filter { $0 > now }.min(),
          streak: reviewedToday > 0 ? 1 : 0
        )
      },
      isConfigured: { true }
    )
  }
}

private let notFound = APIError(statusCode: 404, message: "Card not found")

extension [Card] {
  /// Sample deck used by previews and `LA_CARTE_API=mock`. Keep it stable: UI screenshots depend on it.
  public static let fixtures: [Card] = {
    let date = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01
    return [
      ("serendipity", "finding something good without looking for it"),
      ("la carte", "the menu — and the map"),
      ("ephemeral", "lasting a very short time"),
    ].enumerated().map { index, pair in
      Card(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index + 1)")!,
        front: pair.0,
        back: pair.1,
        due: date,
        createdAt: date,
        updatedAt: date
      )
    }
  }()
}
