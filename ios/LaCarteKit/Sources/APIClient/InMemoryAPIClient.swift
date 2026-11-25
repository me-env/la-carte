import Dependencies
import Foundation

extension APIClient {
  /// A fake deck held in memory, for previews and deterministic UI tests. Each card becomes a `basic` note.
  public static func inMemory(cards: [Card], now: Date = Date()) -> APIClient {
    .inMemory(notes: cards.map(\.basicNote), now: now)
  }

  /// A fake deck of notes held in memory; cards are derived from them, like on the server.
  /// Scheduling is deliberately naive: any review pushes the card one day out. Burying, holding, the queue's order
  /// (learning first, then by due) and `Note.next` match the API; `held` cards start reported.
  /// Spec 021's ladder: cards last reviewed before `now`'s day are started reviews, `atRisk` of them form the day's
  /// at-risk snapshot (no threshold), and `newToday` new cards count as already introduced today.
  public static func inMemory(
    notes: [Note], now: Date = Date(), atRisk: Set<Card.ID> = [], milestone: Int = 15, newToday: Int = 0,
    held: Set<Card.ID> = []
  ) -> APIClient {
    let deck = LockIsolated(notes)
    let started = Set(
      cards(notes).filter { $0.lastReview.map { !DeckStats.calendar.isDate($0, inSameDayAs: now) } ?? false }.map(\.id)
    )
    /// Reported cards: out of study for good, as no agent closes reports here (spec 015).
    let held = LockIsolated(held)

    /// When a card can be served: once due, and, unless (re)learning, until 6 h after a sibling's last review or that
    /// sibling's due, whichever comes first (spec 014). Held siblings don't bury.
    @Sendable func readyAt(_ card: Card, _ notes: [Note]) -> Date {
      guard !card.isLearning else { return card.due }
      let siblings =
        notes.first { $0.id == card.noteId }?.cards.filter { $0.id != card.id && !held.value.contains($0.id) } ?? []
      return siblings.compactMap { sibling in sibling.lastReview.map { min($0 + siblingBury, sibling.due) } }
        .reduce(card.due, max)
    }

    /// Every card not held with its ready time, in queue order: (re)learning first, then by due. `sorted` is
    /// stable, so cards due at the same time keep fixture order.
    @Sendable func candidates(_ notes: [Note]) -> [(card: Card, readyAt: Date)] {
      cards(notes)
        .filter { !held.value.contains($0.id) }
        .sorted { ($0.isLearning ? 0 : 1, $0.due) < ($1.isLearning ? 0 : 1, $1.due) }
        .map { ($0, readyAt($0, notes)) }
    }

    /// The note with `next` filled as the API does: its first card in queue order that is ready, else the one
    /// ready earliest; `nil` when all its cards are held.
    @Sendable func withNext(_ note: Note, _ notes: [Note]) -> Note {
      let own = candidates(notes).filter { $0.card.noteId == note.id }
      let pick = own.first { $0.readyAt <= now } ?? own.min { $0.readyAt < $1.readyAt }
      var note = note
      note.next = pick.map { Note.Next(cardId: $0.card.id, readyAt: $0.readyAt) }
      return note
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
        let servable = candidates(notes)
          .filter { $0.readyAt <= now }
          .map(\.card)
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
        let isToday = { (card: Card) in card.lastReview.map { DeckStats.calendar.isDate($0, inSameDayAs: now) } ?? false }
        let reviewed = cards.filter(isToday)
        let reviewedToday = reviewed.count
        let dueCards = zip(studied, readyDates).filter { $1 <= now }.map(\.0)
        let today = DeckStats.calendar.startOfDay(for: now)
        /// Done = reviewed today; total = done + those of `ids` still waiting (not held, not reviewed today).
        func step(_ ids: Set<Card.ID>) -> (done: Int, total: Int) {
          let done = reviewed.filter { ids.contains($0.id) }.count
          return (done, done + studied.filter { ids.contains($0.id) && !isToday($0) }.count)
        }
        let (atRiskDone, atRiskTotal) = step(atRisk)
        let (reviewsDone, reviewsTotal) = step(started)
        return DeckStats(
          total: cards.count,
          due: Set(dueCards.map(\.noteId)).count,
          new: cards.filter { $0.lastReview == nil }.count,
          reviewedToday: reviewedToday,
          nextDue: readyDates.filter { $0 > now }.min(),
          streak: reviewedToday > 0 ? 1 : 0,
          newToday: newToday + reviewedToday - reviewsDone,
          milestone: milestone,
          dueNew: Set(dueCards.filter { $0.lastReview == nil }.map(\.noteId)).count,
          atRiskTotal: atRiskTotal,
          atRiskDone: atRiskDone,
          reviewsTotal: reviewsTotal,
          reviewsDone: reviewsDone,
          history: reviewedToday > 0 ? "s" : "p",
          historyStart: today,
          streakStart: reviewedToday > 0 ? today : nil
        )
      },
      notes: { query in
        let notes = deck.value
        return notes.filter { $0.matches(query) }.map { withNext($0, notes) }
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
        return deck.withValue { notes in
          notes.insert(note, at: 0)
          return withNext(note, notes)
        }
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
          return withNext(notes[index], notes)
        }
      },
      deleteNote: { id in
        deck.withValue { $0.removeAll { $0.id == id } }
      },
      isConfigured: { true }
    )
  }
}

extension APIClient {
  /// A `LA_CARTE_API=mock*` deck with spec 021's ladder seeded from the launch environment: the first
  /// `LA_CARTE_STARTED` cards are started reviews (served first), the first `LA_CARTE_AT_RISK` of them are at risk,
  /// `LA_CARTE_MILESTONE` (15) is the step size and `LA_CARTE_NEW_TODAY` (0) the new cards already introduced today.
  static func inMemory(
    notes: [Note], environment: [String: String], now: Date = Date(), held: Set<Card.ID> = []
  ) -> APIClient {
    func count(_ key: String) -> Int? { environment[key].flatMap { Int($0) } }
    var notes = notes
    var started: [Card.ID] = []
    let startedCount = count("LA_CARTE_STARTED") ?? 0
    for noteIndex in notes.indices {
      for cardIndex in notes[noteIndex].cards.indices where started.count < startedCount {
        notes[noteIndex].cards[cardIndex].state = .review
        notes[noteIndex].cards[cardIndex].lastReview = now.addingTimeInterval(-2 * 86_400)
        started.append(notes[noteIndex].cards[cardIndex].id)
      }
    }
    return .inMemory(
      notes: notes,
      now: now,
      atRisk: Set(started.prefix(count("LA_CARTE_AT_RISK") ?? 0)),
      milestone: count("LA_CARTE_MILESTONE") ?? 15,
      newToday: count("LA_CARTE_NEW_TODAY") ?? 0,
      held: held
    )
  }
}

@Sendable private func cards(_ notes: [Note]) -> [Card] {
  notes.flatMap { note in note.cards.map { Card(note: note, card: $0) } }
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
  var isLearning: Bool { state == .learning || state == .relearning }

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

extension [Card] {
  /// Sample deck for `LA_CARTE_API=mock-lengths` (spec 017): `fixtures` after a short, a long-question, a
  /// short-question-long-answer and a very long card. Keep it stable: UI screenshots depend on it.
  public static let lengthFixtures: [Card] = {
    let date = Date(timeIntervalSince1970: 1_767_225_600)  // 2026-01-01
    let samples = [
      ("la mer", "the sea"),
      (
        "Which treaty, signed in 1648, ended the Thirty Years' War and is often cited as the origin of the modern "
          + "state system?",
        "The Peace of Westphalia"
      ),
      (
        "mitochondria",
        "The organelle that produces most of the cell's energy (ATP) through cellular respiration, often called the "
          + "powerhouse of the cell."
      ),
      (
        "In 1859, Charles Darwin published On the Origin of Species, arguing that populations change over many "
          + "generations: individuals whose inherited traits suit their environment tend to survive and leave more "
          + "offspring, so those traits become more common over time. Alfred Russel Wallace had reached the same "
          + "idea on his own while working in the Malay Archipelago, and papers by both men were read together at "
          + "the Linnean Society of London the year before. Which mechanism did both of them propose to explain how "
          + "species adapt to their environment?",
        "Natural selection: heritable traits that favor survival and reproduction become more common over "
          + "successive generations."
      ),
    ]
    return samples.enumerated().map { index, pair in
      Card(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(index + 21)")!,
        front: pair.0,
        back: pair.1,
        due: date,
        createdAt: date,
        updatedAt: date
      )
    } + fixtures
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

extension [Note] {
  /// Sample deck for `LA_CARTE_API=mock-labels` (spec 028): one one-card note per deck row label, relative to `now`,
  /// in label order. The last one is reported: pass `labelFixturesReported` as `held`.
  public static func labelFixtures(now: Date, calendar: Calendar = .current) -> [Note] {
    let hour: TimeInterval = 3600
    let today = calendar.startOfDay(for: now)
    func noon(in days: Int) -> Date {
      calendar.date(byAdding: .day, value: days, to: today)!.addingTimeInterval(12 * hour)
    }
    let reviewed = now - 3 * 24 * hour
    let samples: [(front: String, state: Card.State, due: Date, lastReview: Date?)] = [
      ("in queue", .review, now - hour, reviewed),
      ("new", .new, now, nil),
      ("later today", .learning, now + hour / 2, now - hour / 6),
      ("tomorrow", .review, noon(in: 1), reviewed),
      ("in 3 days", .review, noon(in: 3), reviewed),
      ("in 2 weeks", .review, noon(in: 20), reviewed),
      ("in 4 months", .review, noon(in: 125), reviewed),
      ("reported", .review, now - hour, reviewed),
    ]
    return samples.enumerated().map { index, sample in
      Card(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(index + 31)")!,
        front: sample.front,
        back: "a deck row label",
        state: sample.state,
        due: sample.due,
        lastReview: sample.lastReview,
        createdAt: now,
        updatedAt: now
      ).basicNote
    }
  }

  /// The reported card of `labelFixtures`.
  public static let labelFixturesReported = UUID(uuidString: "00000000-0000-0000-0000-000000000038")!
}
