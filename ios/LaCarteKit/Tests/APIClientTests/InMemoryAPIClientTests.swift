import Foundation
import Testing

@testable import APIClient

/// The in-memory deck backs previews and `LA_CARTE_API=mock` UI tests, so its scheduling must stay predictable.
struct InMemoryAPIClientTests {
  let now = Date(timeIntervalSince1970: 1_795_000_000)

  @Test func nextDueIsTheEarliestCardNotYetDue() async throws {
    let client = APIClient.inMemory(cards: .fixtures, now: now)
    #expect(try await client.stats().nextDue == nil)

    let cards = [Card].fixtures
    _ = try await client.review(cards[0].id, .good)
    _ = try await client.review(cards[1].id, .again)
    #expect(try await client.stats().nextDue == now.addingTimeInterval(600))
  }

  @Test func dueCardsKeepFixtureOrderAfterAReview() async throws {
    let client = APIClient.inMemory(cards: .fixtures, now: now)
    let cards = [Card].fixtures

    _ = try await client.review(cards[1].id, .good)
    #expect(try await client.dueCards(100).map(\.front) == [cards[0].front, cards[2].front])
  }
}
