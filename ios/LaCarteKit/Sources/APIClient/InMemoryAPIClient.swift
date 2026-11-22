import Dependencies
import Foundation

extension APIClient {
  /// A fake deck held in memory, for previews and deterministic UI tests. Each card becomes a `basic` note.
  public static func inMemory(cards: [Card], now: Date = Date()) -> APIClient {
    .inMemory(notes: cards.map(\.basicNote), now: now)
  }

  /// A fake deck of notes held in memory; cards are derived from them, like on the server.
  /// Scheduling is deliberately naive: any review pushes the card one day out. Burying and holding match the API.
  public static func inMemory(notes: [Note], now: Date = Date()) -> APIClient {
    let deck = LockIsolated(notes)
    /// Reported cards: out of study for good, as no agent closes reports here (spec 015).
    let held = LockIsolated<Set<Card.ID>>([])

    @Sendable func cards(_ notes: [Note]) -> [Card] {
      notes.flatMap { note in note.cards.map { Card(note: note, card: $0) } }
    }

    /// When a card can be served: once due, and 6 h after any sibling's last review (spec 014).
    @Sendable func readyAt(_ card: Card, _ notes: [Note]) -> Date {
      let siblings = notes.first { $0.id == card.noteId }?.cards.filter { $0.id != card.id } ?? []
      return siblings.compactMap { $0.lastReview?.addingTimeInterval(siblingBury) }.reduce(card.due, max)
    }

    @Sendable func editCard<T: Sendable>(
      _ id: Card.ID, _ edit: @Sendable (inout Note, Int) throws -> T
    ) throws -> T {
      try deck.withValue { notes in
        guard let noteIndex = notes.firstIndex(where: { $0.cards.contains { $0.id == id } }),
          let cardIndex = notes[noteIndex].cards.firstIndex(where: { $0.id == id })
        else { throw notFound }
        return try edit(&notes[noteIndex], cardIndex)
      }
    }

    return APIClient(
      dueCards: { limit in
        let notes = deck.value
        var servedNotes = Set<Note.ID>()
        // `sorted` is stable, so cards due at the same time keep fixture order.
        let servable = cards(notes)
          .filter { !held.value.contains($0.id) && readyAt($0, notes) <= now }
          .sorted { $0.due < $1.due }
          .filter { servedNotes.insert($0.noteId).inserted }
        return Array(servable.prefix(limit))
      },
      updateCard: { id, front, back in
        try editCard(id) { note, index in
          let card = note.cards[index]
          guard card.prompt.count == 1, card.answer.count == 1 else {
            throw APIError(statusCode: 422, message: "use PATCH /notes/{note_id}")
          }
          note.fields[card.prompt[0]] = front
          note.fields[card.answer[0]] = back
          return Card(note: note, card: card)
        }
      },
      review: { id, rating in
        try editCard(id) { note, index in
          note.cards[index].state = rating == .again ? .relearning : .review
          note.cards[index].lastReview = now
          note.cards[index].due = now.addingTimeInterval(rating == .again ? 600 : 86_400)
          return Card(note: note, card: note.cards[index])
        }
      },
      reportCard: { id, _, _ in
        try editCard(id) { _, _ in }
        held.withValue { _ = $0.insert(id) }
      },
      stats: {
        let notes = deck.value
        let cards = cards(notes)
        let studied = cards.filter { !held.value.contains($0.id) }
        let readyDates = studied.map { readyAt($0, notes) }
        let reviewedToday = cards.filter { $0.lastReview.map(Calendar.current.isDateInToday) ?? false }.count
        return DeckStats(
          total: cards.count,
          due: Set(zip(studied, readyDates).filter { $1 <= now }.map(\.0.noteId)).count,
          new: cards.filter { $0.lastReview == nil }.count,
          reviewedToday: reviewedToday,
          nextDue: readyDates.filter { $0 > now }.min(),
          streak: reviewedToday > 0 ? 1 : 0
        )
      },
      notes: { query in
        deck.value.filter { $0.matches(query) }
      },
      addNote: { draft in
        let directions =
          draft.directions.isEmpty && draft.type == .basic
          ? [Direction(prompt: ["front"], answer: ["back"])] : draft.directions
        let note = Note(
          id: UUID(),
          type: draft.type,
          fields: draft.fields.filter { !$0.value.isEmpty },
          cards: directions.map { Note.Card(id: UUID(), prompt: $0.prompt, answer: $0.answer, due: now) },
          createdAt: now,
          updatedAt: now
        )
        deck.withValue { $0.insert(note, at: 0) }
        return note
      },
      // Ignores `draft.type`: a note's type is fixed at creation, as on the server.
      updateNote: { id, draft in
        try deck.withValue { notes in
          guard let index = notes.firstIndex(where: { $0.id == id }) else { throw notFound }
          let kept = notes[index].cards
          notes[index].fields = notes[index].fields.merging(draft.fields) { $1 }.filter { !$0.value.isEmpty }
          notes[index].cards = draft.directions.map { direction in
            kept.first { $0.direction == direction }
              ?? Note.Card(id: UUID(), prompt: direction.prompt, answer: direction.answer, due: now)
          }
          notes[index].updatedAt = now
          return notes[index]
        }
      },
      deleteNote: { id in
        deck.withValue { $0.removeAll { $0.id == id } }
      },
      isConfigured: { true }
    )
  }
}

/// How long a review buries the card's siblings (`SIBLING_BURY` in `api/src/la_carte_api/deck.py`).
let siblingBury: TimeInterval = 6 * 3600

private let notFound = APIError(statusCode: 404, message: "Not found")

extension Card {
  /// A `basic` note holding this card, with the card's id (as the API's 014 migration does).
  var basicNote: Note {
    Note(
      id: id,
      type: .basic,
      fields: ["front": front, "back": back],
      cards: [
        Note.Card(id: id, prompt: ["front"], answer: ["back"], state: state, due: due, lastReview: lastReview)
      ],
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}

extension Note {
  /// Same matching as the API: case-insensitive substring of any field but `photo`.
  func matches(_ query: String?) -> Bool {
    guard let query, !query.isEmpty else { return true }
    return fields.contains { $0.key != "photo" && $0.value.localizedCaseInsensitiveContains(query) }
  }
}

extension Card {
  /// The card as `/cards` returns it: the note's data plus this direction's schedule.
  init(note: Note, card: Note.Card) {
    func side(_ names: [String]) -> String {
      names.compactMap { note.fields[$0] }.joined(separator: "\n")
    }
    self.init(
      id: card.id,
      noteId: note.id,
      type: note.type,
      prompt: card.prompt,
      answer: card.answer,
      fields: note.fields,
      front: side(card.prompt),
      back: side(card.answer),
      state: card.state,
      due: card.due,
      lastReview: card.lastReview,
      createdAt: note.createdAt,
      updatedAt: note.updatedAt
    )
  }
}

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

extension [Note] {
  /// Sample deck for `LA_CARTE_API=mock-notes`: `[Card].fixtures` as notes, "la carte" also asked `back → front`,
  /// and a made-up person first. Keep it stable: UI screenshots depend on it.
  public static let fixtures: [Note] = {
    let date = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01
    func id(_ suffix: Int) -> UUID { UUID(uuidString: "00000000-0000-0000-0000-0000000000\(suffix)")! }
    let person = Note(
      id: id(11),
      type: .person,
      fields: [
        "photo": neutralPhoto,
        "name": "Ada Example",
        "description": "runs the bakery",
      ],
      cards: [
        Note.Card(id: id(12), prompt: ["photo"], answer: ["name", "description"], due: date),
        Note.Card(id: id(13), prompt: ["name"], answer: ["photo", "description"], due: date),
        Note.Card(id: id(15), prompt: ["description"], answer: ["photo", "name"], due: date),
      ],
      createdAt: date,
      updatedAt: date
    )
    var basics = [Card].fixtures.map(\.basicNote)
    basics[1].cards.append(Note.Card(id: id(14), prompt: ["back"], answer: ["front"], due: date))
    return [person] + basics
  }()
}

/// A generated abstract image (a circle on two flat colors, no face): fixtures never hold a real person's photo.
let neutralPhoto =
  "data:image/png;base64,"
  + "iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAIAAABt+uBvAAABn0lEQVR42u3azU1DMRQGUZfNgjqogSqohDVikSISCQmhoOT52ffvs0e"
  + "aCs562uXrk57UIAAIIIAAAggggAAigAACCCCAAAIIIAJIAuj7/bW/jYBOuaRLNRWXLKkmqhNm1ERpwpiauo63UVOn8WZqy+h4GL28fbS"
  + "VdGyNbjr2QOk6VkY/OsZARXTmjX51ADrQsQQqpTNsdKdjBlRQZ8Dovw5ABzo2QGV1+o0e6RgAFdfpMXqiA9CBzu5AhzqzQBI6j4x6dPYF"
  + "6tTZFKhfZwpISOev0Smd7YDO6uwFNKADEEAAAQQQQAABBBBAAAEEkBiQltGYDkAA5QKpGA3rAARQOlB9oxmd9e+OSR2AooBqGs3rrPwo"
  + "mugAFAtUx8hKZ83T3lDHBSjXyFbHCyjLyFzHESiYyYMmAijGyE8nAsiVyZUmFMjDKEAnFMhKKsYlE2hMKtilBNDYVbkXUHGdZKD6OplA"
  + "EjppQCo6OUBCOglAWjrRQHI6oUCKOnFAojpBQLo6EUDSOu5A6jq+QAvoOAKtoeMFtIyOC9BKOvZAi+ncugL873Jpn08t5wAAAABJRU5E"
  + "rkJggg=="
