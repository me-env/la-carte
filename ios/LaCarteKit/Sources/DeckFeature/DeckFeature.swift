import APIClient
import ActivityClient
import ComposableArchitecture
import Foundation
import NoteEditorFeature
import SettingsFeature
import SwiftUI

/// Every note in the deck: search, swipe to delete, tap to edit, add (specs 002, 014c); hosts Settings (spec 003).
@Reducer
public struct DeckFeature {
  @Reducer
  public enum Destination {
    case editor(NoteEditorFeature)
    case settings(SettingsFeature)
  }

  @ObservableState
  public struct State: Equatable {
    var notes: IdentifiedArrayOf<Note> = []
    var query = ""
    var phase: Phase = .loading
    /// Haptic trigger: bumps on every row deleted (spec 009a).
    var deletions = 0
    @Presents var destination: Destination.State?

    public init() {}

    enum Phase: Equatable {
      case loading, loaded, offline, notSetUp, unauthorized
    }

    enum Message: Equatable {
      case noCards, noMatches, offline, notSetUp, unauthorized

      var title: String {
        switch self {
        case .noCards: "No cards yet"
        case .noMatches: "No matches"
        case .offline: "Can't reach your deck"
        case .notSetUp: "Connect your deck"
        case .unauthorized: "Token rejected"
        }
      }

      /// The same detail line Study shows for the same message.
      var detail: String? {
        switch self {
        case .noCards: "Ask your agent to add some"
        case .notSetUp: "Add your server URL and token in Settings."
        case .unauthorized: "Check your token in Settings."
        case .noMatches, .offline: nil
        }
      }

      var systemImage: String {
        switch self {
        case .noCards: "rectangle.stack"
        case .noMatches: "magnifyingglass"
        case .offline: "wifi.slash"
        case .notSetUp: "link"
        case .unauthorized: "key"
        }
      }
    }

    /// What to say instead of rows, if anything.
    var message: Message? {
      switch phase {
      case .loading: nil
      case .offline: .offline
      case .notSetUp: .notSetUp
      case .unauthorized: .unauthorized
      case .loaded where notes.isEmpty: query.isEmpty ? .noCards : .noMatches
      case .loaded: nil
      }
    }

    /// Only Settings can fix a missing or rejected token.
    var showsSettingsButton: Bool {
      phase == .notSetUp || phase == .unauthorized
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case onAppear
    case addButtonTapped
    case settingsButtonTapped
    case rowTapped(Note.ID)
    case rowSwipedToDelete(Note.ID)
    case retryButtonTapped
    case scenePhaseChanged(ScenePhase)
    case notesResponse(Result<[Note], any Error>)
    case deleteResponse(Result<Note.ID, any Error>)
    case destination(PresentationAction<Destination.Action>)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      case deckChanged
    }
  }

  @Dependency(\.activity) var activity
  @Dependency(\.apiClient) var apiClient
  @Dependency(\.continuousClock) var clock

  private enum CancelID { case load }

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.query):
        return loadNotes(&state, after: .seconds(0.3))

      case .onAppear, .scenePhaseChanged(.active):
        return loadNotes(&state)

      case .scenePhaseChanged:
        return .none

      case .retryButtonTapped:
        state.phase = .loading
        return loadNotes(&state)

      case .addButtonTapped:
        state.destination = .editor(NoteEditorFeature.State())
        return .none

      case .settingsButtonTapped:
        state.destination = .settings(SettingsFeature.State())
        return .none

      case let .rowTapped(id):
        guard let note = state.notes[id: id] else { return .none }
        state.destination = .editor(NoteEditorFeature.State(note: note))
        return .none

      case let .rowSwipedToDelete(id):
        state.notes.remove(id: id)
        state.deletions += 1
        // A load still in flight may predate the delete and would bring the row back.
        return .merge(
          .cancel(id: CancelID.load),
          .run { [apiClient] send in
            await send(
              .deleteResponse(
                Result {
                  try await apiClient.deleteNote(id)
                  return id
                }
              )
            )
          }
        )

      case let .notesResponse(.success(notes)):
        state.notes = IdentifiedArray(uniqueElements: notes)
        state.phase = .loaded
        return .none

      case let .notesResponse(.failure(error)):
        state.notes = []
        state.phase = (error as? APIError)?.isUnauthorized == true ? .unauthorized : .offline
        return .none

      case .deleteResponse(.success):
        // The swipe cancelled any load in flight, including a debounced search: catch up with the field.
        return .merge(
          loadNotes(&state),
          .send(.delegate(.deckChanged))
        )

      case .deleteResponse(.failure):
        return loadNotes(&state)

      case let .destination(.presented(.editor(.delegate(.saved(note))))):
        state.notes.updateOrInsert(note, at: 0)
        return .send(.delegate(.deckChanged))

      case .destination(.presented(.settings(.delegate(.serverChanged)))):
        return .merge(
          loadNotes(&state),
          .send(.delegate(.deckChanged))
        )

      // Closing Settings counts as saving it. Runs before `ifLet` clears the destination.
      case .destination(.dismiss) where state.destination?.is(\.settings) == true:
        return .merge(
          loadNotes(&state),
          .send(.delegate(.deckChanged))
        )

      case .binding, .destination, .delegate:
        return .none
      }
    }
    .ifLet(\.$destination, action: \.destination)
    Reduce { state, action in
      guard let event = activityEvent(action, state) else { return .none }
      return .run { [activity] _ in activity.log(event) }
    }
  }

  /// Spec 029: what a deck action tells the activity log; never the search text.
  private func activityEvent(_ action: Action, _ state: State) -> Activity? {
    switch action {
    case let .notesResponse(.success(notes)): .deckLoaded(count: notes.count, query: !state.query.isEmpty)
    case let .notesResponse(.failure(error)): .failed(.notes, error)
    case let .deleteResponse(.success(id)): .noteDeleted(noteID: id)
    case let .deleteResponse(.failure(error)): .failed(.deleteNote, error)
    default: nil
    }
  }

  /// Loads the notes matching the search field; without a server URL and a token, makes no request (spec 008).
  /// Every load shares one cancel id, so a slow response never overwrites a newer one.
  private func loadNotes(_ state: inout State, after delay: Duration = .zero) -> Effect<Action> {
    guard apiClient.isConfigured() else {
      state.notes = []
      state.phase = .notSetUp
      return .cancel(id: CancelID.load)
    }
    let query = state.query
    return .run { [apiClient, clock] send in
      if delay > .zero {
        try await clock.sleep(for: delay)
      }
      await send(.notesResponse(Result { try await apiClient.notes(query.isEmpty ? nil : query) }))
    }
    .cancellable(id: CancelID.load, cancelInFlight: true)
  }
}

extension DeckFeature.Destination.State: Equatable {}

/// What a deck row shows for a note (spec 014c #2).
extension Note {
  /// The key field: `front`, or a person's `name`.
  var title: String {
    fields[type == .person ? "name" : "front"] ?? ""
  }

  var subtitle: String {
    switch type {
    case .basic: fields["back"] ?? ""
    case .person: fields["description"] ?? ""
    }
  }

  var photoURL: URL? {
    fields["photo"].flatMap(URL.init(string:))
  }

  /// The earliest `due` among its cards.
  var due: Date {
    cards.map(\.due).min() ?? createdAt
  }

  /// The card's state when there's one card, else how many directions it's studied in.
  var stateText: String {
    cards.count == 1 ? cards[0].state.rawValue : "\(cards.count) directions"
  }
}
