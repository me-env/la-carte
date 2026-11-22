import APIClient
import ComposableArchitecture
@testable import DeckFeature
import Foundation
import Testing

@testable import AppFeature
@testable import NoteEditorFeature
@testable import SettingsFeature
@testable import StudyFeature

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppFeatureTests {
  @Test func studyIsTheHomeScreen() async {
    let card = [Card].fixtures[0]
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
      $0.apiClient.dueCards = { _ in [card] }
    }

    await store.send(\.study.onAppear)
    await store.receive(\.study.cardsResponse.success) {
      $0.study.cards = [card]
      $0.study.phase = .studying
    }
  }

  @Test func deckButtonPresentsTheDeck() async {
    let store = TestStore(initialState: AppFeature.State()) { AppFeature() }

    await store.send(\.study.deckButtonTapped)
    await store.receive(\.study.delegate.deckRequested) {
      $0.destination = .deck(DeckFeature.State())
    }
  }

  @Test func addingFromStudyShowsTheNewCardWhenCaughtUp() async {
    let date = Date(timeIntervalSince1970: 1_795_000_000)
    let new = Card(id: UUID(1), front: "chat", back: "cat", due: date, createdAt: date, updatedAt: date)
    let note = Note(
      id: new.id, type: .basic, fields: new.fields,
      cards: [Note.Card(id: new.id, prompt: ["front"], answer: ["back"], due: date)],
      createdAt: date, updatedAt: date
    )
    var state = AppFeature.State()
    state.study.phase = .caughtUp(nextDue: nil)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
      $0.apiClient.addNote = { _ in note }
      $0.apiClient.dueCards = { _ in [new] }
    }

    await store.send(\.study.addButtonTapped)
    await store.receive(\.study.delegate.addCardRequested) {
      $0.destination = .addNote(NoteEditorFeature.State())
    }
    await store.send(\.destination.addNote.fieldChanged, ("front", "chat")) {
      $0.destination?.modify(\.addNote) { $0.fields["front"] = "chat" }
    }
    await store.send(\.destination.addNote.fieldChanged, ("back", "cat")) {
      $0.destination?.modify(\.addNote) {
        $0.fields["back"] = "cat"
        $0.directions = [Direction(prompt: ["front"], answer: ["back"])]
      }
    }
    await store.send(\.destination.addNote.saveButtonTapped) {
      $0.destination?.modify(\.addNote) { $0.isSaving = true }
    }
    await store.receive(\.destination.addNote.saveResponse.success)
    await store.receive(\.destination.addNote.delegate.saved)
    await store.receive(\.study.deckChanged)
    await store.receive(\.destination.dismiss) {
      $0.destination = nil
    }
    await store.receive(\.study.cardsResponse.success) {
      $0.study.cards = [new]
      $0.study.phase = .studying
    }
  }

  @Test func deletingFromTheDeckRefreshesStudy() async {
    let cards = [Card].fixtures
    let notes = [Note].fixtures
    let (deckReload, releaseDeckReload) = AsyncStream.makeStream(of: Void.self)
    var state = AppFeature.State()
    state.study.cards = IdentifiedArray(uniqueElements: cards)
    state.study.phase = .studying
    state.destination = .deck(DeckFeature.State())
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
      $0.apiClient.deleteNote = { _ in }
      // The deck's reload waits for the test's go so the two reloads arrive in a fixed order.
      $0.apiClient.notes = { _ in
        for await _ in deckReload { break }
        return Array(notes.dropFirst())
      }
      $0.apiClient.dueCards = { _ in Array(cards.dropFirst()) }
    }

    await store.send(\.destination.deck.rowSwipedToDelete, notes[0].id) {
      $0.destination?.modify(\.deck) { $0.deletions = 1 }
    }
    await store.receive(\.destination.deck.deleteResponse.success)
    await store.receive(\.destination.deck.delegate.deckChanged)
    await store.receive(\.study.deckChanged)
    await store.receive(\.study.cardsResponse.success) {
      $0.study.cards = IdentifiedArray(uniqueElements: cards.dropFirst())
    }
    releaseDeckReload.yield()
    await store.receive(\.destination.deck.notesResponse.success) {
      $0.destination?.modify(\.deck) {
        $0.notes = IdentifiedArray(uniqueElements: notes.dropFirst())
        $0.phase = .loaded
      }
    }
  }

  @Test func openSettingsFromStudyPresentsSettingsOverStudy() async {
    var state = AppFeature.State()
    state.study.phase = .notSetUp
    let store = TestStore(initialState: state) { AppFeature() }

    await store.send(\.study.openSettingsTapped)
    await store.receive(\.study.delegate.settingsRequested) {
      $0.destination = .settings(SettingsFeature.State())
    }
  }

  @Test func closingSettingsReloadsStudy() async {
    let card = [Card].fixtures[0]
    let configured = LockIsolated(false)
    var state = AppFeature.State()
    state.study.phase = .notSetUp
    state.destination = .settings(SettingsFeature.State())
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { configured.value }
      $0.apiClient.dueCards = { _ in [card] }
    }

    // Still missing the token: stays on "Connect your deck" without a request.
    await store.send(\.destination.dismiss) {
      $0.destination = nil
    }
    await store.receive(\.study.deckChanged)

    await store.send(\.study.openSettingsTapped)
    await store.receive(\.study.delegate.settingsRequested) {
      $0.destination = .settings(SettingsFeature.State())
    }
    configured.setValue(true)
    await store.send(\.destination.dismiss) {
      $0.destination = nil
    }
    await store.receive(\.study.deckChanged)
    await store.receive(\.study.cardsResponse.success) {
      $0.study.cards = [card]
      $0.study.phase = .studying
    }
  }

  @Test func aSuccessfulConnectionTestReloadsStudyWithTheSheetOpen() async {
    let card = [Card].fixtures[0]
    var state = AppFeature.State()
    state.study.phase = .unauthorized
    state.destination = .settings(SettingsFeature.State())
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.apiClient.isConfigured = { true }
      $0.apiClient.stats = { DeckStats(total: 1, due: 1, new: 1, reviewedToday: 0, nextDue: nil) }
      $0.apiClient.dueCards = { _ in [card] }
    }

    await store.send(\.destination.settings.testButtonTapped) {
      $0.destination?.modify(\.settings) { $0.connection = .checking }
    }
    await store.receive(\.destination.settings.statsResponse.success) {
      $0.destination?.modify(\.settings) { $0.connection = .connected(total: 1) }
    }
    await store.receive(\.destination.settings.delegate.serverChanged)
    await store.receive(\.study.deckChanged)
    await store.receive(\.study.cardsResponse.success) {
      $0.study.cards = [card]
      $0.study.phase = .studying
    }
  }

  @Test func themePickedInSettingsReachesTheRoot() async {
    var deck = DeckFeature.State()
    deck.destination = .settings(SettingsFeature.State())
    var state = AppFeature.State()
    state.destination = .deck(deck)
    let store = TestStore(initialState: state) { AppFeature() }
    #expect(store.state.theme == .system)

    await store.send(\.destination.deck.destination.settings.themeTapped, .dark) {
      $0.$theme.withLock { $0 = .dark }
    }
  }
}
