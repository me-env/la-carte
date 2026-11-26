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

  /// Spec 024 #19: a one-day history that starts today, studied once a card was reviewed.
  @Test func historyIsTodayPendingUntilACardIsReviewed() async throws {
    let client = APIClient.inMemory(cards: .fixtures, now: .now)
    let today = DeckStats.calendar.startOfDay(for: .now)
    let before = try await client.stats()
    #expect(before.streak == 0)
    #expect(before.history == "p")
    #expect(before.historyStart == today)
    #expect(before.streakStart == nil)
    #expect(before.dueNew == 3)

    _ = try await client.review([Card].fixtures[0].id, .good)
    let after = try await client.stats()
    #expect(after.streak == 1)
    #expect(after.history == "s")
    #expect(after.historyStart == today)
    #expect(after.streakStart == today)
    #expect(after.dueNew == 2)
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

  @Test func noteNextIsTheCardStudyServesFirstOrReadyEarliest() async throws {
    let client = APIClient.inMemory(notes: .fixtures, now: now)
    let laCarte = [Note].fixtures[2]
    func next(_ note: Note) async throws -> Note.Next? {
      try await client.notes(nil).first { $0.id == note.id }?.next
    }

    #expect(try await next(laCarte) == Note.Next(cardId: laCarte.cards[0].id, readyAt: laCarte.cards[0].due))

    // Good pushes the card a day out and buries its sibling 6 h, which is ready first.
    _ = try await client.review(laCarte.cards[0].id, .good)
    #expect(try await next(laCarte) == Note.Next(cardId: laCarte.cards[1].id, readyAt: now + siblingBury))

    // Again: relearning in 10 min, which shortens the sibling's bury to the same time; the learning card goes first.
    _ = try await client.review(laCarte.cards[0].id, .again)
    #expect(try await next(laCarte) == Note.Next(cardId: laCarte.cards[0].id, readyAt: now + 600))
    #expect(try await client.dueCards(100).allSatisfy { $0.noteId != laCarte.id })

    // A held card is skipped; with every card held, there's no next.
    try await client.reportCard(laCarte.cards[0].id, .drop, nil)
    #expect(try await next(laCarte) == Note.Next(cardId: laCarte.cards[1].id, readyAt: laCarte.cards[1].due))
    try await client.reportCard(laCarte.cards[1].id, .drop, nil)
    #expect(try await next(laCarte) == nil)
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

  /// Like the API, the ladder's waiting reviews are the started cards Study serves now, not every started card.
  @Test func reviewsToDoCountOnlyWhatStudyServes() async throws {
    let lastWeek = now - 7 * 86_400
    func started(_ front: String, due: Date) -> Card {
      Card(
        id: UUID(), front: front, back: "b", state: .review, due: due, lastReview: lastWeek,
        createdAt: lastWeek, updatedAt: lastWeek
      )
    }
    let client = APIClient.inMemory(cards: [started("due", due: now - 60), started("later", due: now + 3 * 86_400)], now: now)
    let stats = try await client.stats()
    let served = try await client.dueCards(100).map(\.front)
    #expect(served == ["due"])
    #expect(stats.due == 1)
    #expect(stats.reviewsDone == 0)
    #expect(stats.reviewsTotal == 1)
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

/// Spec 021's mock ladder (AC 20-22 run on it): roles from the launch environment, counts moved by each rating.
struct MockLadderTests {
  func ladder(_ stats: DeckStats) -> [Int] {
    [stats.atRiskDone, stats.atRiskTotal, stats.reviewsDone, stats.reviewsTotal, stats.newToday, stats.milestone, stats.dueNew]
  }

  @Test func ratingsMoveAtRiskThenReviewsThenNew() async throws {
    let environment = ["LA_CARTE_API": "mock", "LA_CARTE_STARTED": "2", "LA_CARTE_AT_RISK": "1", "LA_CARTE_MILESTONE": "1"]
    let client = APIClient.live(environment: environment) { nil }
    let served = try await client.dueCards(100)
    #expect(served.map(\.front) == [Card].fixtures.map(\.front))
    #expect(served.map(\.state) == [.review, .review, .new])
    #expect(ladder(try await client.stats()) == [0, 1, 0, 2, 0, 1, 1])

    _ = try await client.review(served[0].id, .good)
    #expect(ladder(try await client.stats()) == [1, 1, 1, 2, 0, 1, 1])
    _ = try await client.review(served[1].id, .again)
    #expect(ladder(try await client.stats()) == [1, 1, 2, 2, 0, 1, 1])
    _ = try await client.review(served[2].id, .good)
    let stats = try await client.stats()
    #expect(ladder(stats) == [1, 1, 2, 2, 1, 1, 0])
    #expect(stats.reviewedToday == 3)
  }

  @Test func milestoneAndNewTodaySeedTheNewSteps() async throws {
    let environment = ["LA_CARTE_API": "mock", "LA_CARTE_MILESTONE": "2", "LA_CARTE_NEW_TODAY": "4"]
    let stats = try await APIClient.live(environment: environment) { nil }.stats()
    #expect(ladder(stats) == [0, 0, 0, 0, 4, 2, 3])
  }

  @Test func withoutTheEnvironmentTheMockHasNoLadder() async throws {
    let stats = try await APIClient.live(environment: ["LA_CARTE_API": "mock"]) { nil }.stats()
    #expect(ladder(stats) == [0, 0, 0, 0, 0, 15, 3])
  }
}

/// `LA_CARTE_API=mock-lengths` (spec 017): QA expects these four cards first, in this order.
struct LengthFixturesTests {
  @Test func mockLengthsServesTheFourLengthCardsBeforeTheUsualDeck() async throws {
    let client = APIClient.live(environment: ["LA_CARTE_API": "mock-lengths"]) { nil }
    let cards = try await client.dueCards(100)
    #expect(cards.prefix(3).map(\.front) == ["la mer", [Card].lengthFixtures[1].front, "mitochondria"])
    #expect(cards[3].front.count > 500)
    #expect(cards[3].back.count == 120)
    #expect(cards.dropFirst(4).map(\.front) == [Card].fixtures.map(\.front))
  }
}
