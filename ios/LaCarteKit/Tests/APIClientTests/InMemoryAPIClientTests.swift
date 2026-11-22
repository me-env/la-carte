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

  @Test func streakIsOneOnceACardWasReviewedToday() async throws {
    let client = APIClient.inMemory(cards: .fixtures, now: .now)
    #expect(try await client.stats().streak == 0)

    _ = try await client.review([Card].fixtures[0].id, .good)
    #expect(try await client.stats().streak == 1)
  }

  @Test func dueCardsKeepFixtureOrderAfterAReview() async throws {
    let client = APIClient.inMemory(cards: .fixtures, now: now)
    let cards = [Card].fixtures

    _ = try await client.review(cards[1].id, .good)
    #expect(try await client.dueCards(100).map(\.front) == [cards[0].front, cards[2].front])
  }

  @Test func aReportedCardIsHeldOutOfStudyButStillCounted() async throws {
    let client = APIClient.inMemory(cards: .fixtures, now: now)
    let cards = [Card].fixtures

    try await client.reportCard(cards[0].id, .drop, nil)
    #expect(try await client.dueCards(100).map(\.id) == [cards[1].id, cards[2].id])
    let stats = try await client.stats()
    #expect(stats.total == 3)
    #expect(stats.due == 2)
    #expect(stats.nextDue == nil)
    await #expect(throws: APIError.self) { try await client.reportCard(UUID(), .wrong, nil) }
  }

  @Test func mockDeckServesTheSameCardsAsBeforeNotes() async throws {
    let client = APIClient.inMemory(cards: .fixtures, now: now)
    #expect(try await client.notes(nil).map(\.id) == [Card].fixtures.map(\.id))
    #expect(try await client.dueCards(100) == .fixtures)
  }

  @Test func dueCardsServeOneCardPerNoteAndBurySiblingsAfterAReview() async throws {
    let client = APIClient.inMemory(notes: .fixtures, now: now)
    let laCarte = [Note].fixtures[2]
    #expect(laCarte.cards.count == 2)

    let due = try await client.dueCards(100)
    #expect(due.count == 4)
    #expect(Set(due.map(\.noteId)).count == 4)
    #expect(try await client.stats().due == 4)

    _ = try await client.review(laCarte.cards[0].id, .again)
    let afterReview = try await client.dueCards(100)
    #expect(!afterReview.contains { $0.noteId == laCarte.id })
    #expect(try await client.stats().due == 3)
  }

  @Test func mockNotesDeckHasFourNotesAndSevenCards() async throws {
    let client = APIClient.inMemory(notes: .fixtures, now: now)
    let notes = try await client.notes(nil)
    let ids = (11...15).map { UUID(uuidString: "00000000-0000-0000-0000-0000000000\($0)")! }

    #expect(notes.count == 4)
    #expect(notes.flatMap(\.cards).count == 7)
    #expect(notes[0].id == ids[0])
    #expect(notes[0].cards.map(\.id) == [ids[1], ids[2], ids[4]])
    #expect(notes[2].cards.map(\.id) == [[Card].fixtures[1].id, ids[3]])
    #expect(notes[2].cards[1].direction == Direction(prompt: ["back"], answer: ["front"]))
    #expect(notes[0].fields["photo"]?.hasPrefix("data:image/png;base64,") == true)
    #expect(try await client.dueCards(100).first?.id == ids[1])
  }

  @Test func updateNoteKeepsTheScheduleOfKeptDirections() async throws {
    let client = APIClient.inMemory(notes: .fixtures, now: now)
    let person = [Note].fixtures[0]
    _ = try await client.review(person.cards[0].id, .good)

    let updated = try await client.updateNote(
      person.id,
      NoteDraft(type: .person, fields: ["description": ""], directions: [person.cards[0].direction])
    )
    #expect(updated.fields["description"] == nil)
    #expect(updated.cards.map(\.id) == [person.cards[0].id])
    #expect(updated.cards[0].lastReview == now)
  }

  @Test func searchMatchesEveryTextFieldButThePhoto() async throws {
    let client = APIClient.inMemory(notes: .fixtures, now: now)
    #expect(try await client.notes("bakery").map(\.id) == [[Note].fixtures[0].id])
    #expect(try await client.notes("base64").isEmpty)
  }

  @Test func deletingANoteDeletesItsCards() async throws {
    let client = APIClient.inMemory(notes: .fixtures, now: now)
    try await client.deleteNote([Note].fixtures[2].id)
    #expect(try await client.notes(nil).count == 3)
    #expect(try await client.dueCards(100).count == 3)
  }
}
