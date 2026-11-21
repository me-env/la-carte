import APIClient
import ComposableArchitecture
import Foundation

/// Adds a note or fixes an existing one: its type's fields and the directions to study (specs 002, 014c).
@Reducer
public struct NoteEditorFeature {
  @ObservableState
  public struct State: Equatable {
    let note: Note?
    var type: NoteType
    /// Every field of `type`, `""` when absent.
    var fields: [String: String]
    /// The directions that are on, in `catalog` order.
    var directions: [Direction]
    var isSaving = false
    var saveFailed = false
    /// A plain flag rather than `ConfirmationDialogState`, whose buttons can't carry accessibility identifiers.
    var isDiscardDialogPresented = false

    public init(note: Note? = nil) {
      let type = note?.type ?? .basic
      self.note = note
      self.type = type
      self.fields = type.emptyFields.merging(note?.fields ?? [:]) { $1 }
      self.directions = []
      self.directions = sortedInCatalogOrder(note?.cards.map(\.direction) ?? type.defaultDirections)
    }

    /// The type's directions, then any other direction the note already has (e.g. added by an agent).
    var catalog: [Direction] {
      let extras = (note?.cards.map(\.direction) ?? []).filter { !type.directionCatalog.contains($0) }
      return type.directionCatalog + extras
    }

    /// An off direction whose fields aren't all filled can't be turned on.
    func isUnavailable(_ direction: Direction) -> Bool {
      !directions.contains(direction) && !isFilled(direction.prompt + direction.answer)
    }

    var canSave: Bool {
      !isSaving
        && isFilled(type.requiredFields)
        && !directions.isEmpty
        && directions.allSatisfy { isFilled($0.prompt + $0.answer) }
        && isPhotoValid
    }

    /// For a new note, the current type's empty fields and default directions count as unchanged.
    var hasChanges: Bool {
      let originalFields = type.emptyFields.merging(note?.fields ?? [:]) { $1 }
      let originalDirections = note?.cards.map(\.direction) ?? type.defaultDirections
      return fields.mapValues(\.trimmed) != originalFields || Set(directions) != Set(originalDirections)
    }

    var draft: NoteDraft {
      NoteDraft(type: type, fields: fields.mapValues(\.trimmed), directions: directions)
    }

    /// What the preview shows: the photo field once it's a URL the API accepts.
    var photoURL: URL? {
      let photo = fields["photo"]?.trimmed ?? ""
      return photo.isEmpty || !isPhotoValid ? nil : URL(string: photo)
    }

    /// The API only takes http(s) URLs; a photo the note already has was accepted, so it stays valid.
    private var isPhotoValid: Bool {
      let photo = fields["photo"]?.trimmed ?? ""
      guard !photo.isEmpty, photo != note?.fields["photo"] else { return true }
      guard let url = URL(string: photo), let scheme = url.scheme?.lowercased() else { return false }
      return (scheme == "http" || scheme == "https") && url.host() != nil
    }

    private func isFilled(_ names: [String]) -> Bool {
      names.allSatisfy { !(fields[$0]?.trimmed ?? "").isEmpty }
    }

    fileprivate func sortedInCatalogOrder(_ directions: [Direction]) -> [Direction] {
      catalog.filter { directions.contains($0) }
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    case typeChanged(NoteType)
    case fieldChanged(String, String)
    case directionToggled(Direction)
    case saveButtonTapped
    case closeButtonTapped
    case discardTapped
    case saveResponse(Result<Note, any Error>)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      case saved(Note)
    }
  }

  @Dependency(\.apiClient) var apiClient
  @Dependency(\.dismiss) var dismiss

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case let .typeChanged(type):
        guard state.note == nil, type != state.type else { return .none }
        state.type = type
        state.fields = type.emptyFields
        state.directions = type.defaultDirections
        return .none

      case let .fieldChanged(name, value):
        state.fields[name] = value
        return .none

      case let .directionToggled(direction):
        if let index = state.directions.firstIndex(of: direction) {
          state.directions.remove(at: index)
        } else if !state.isUnavailable(direction) {
          state.directions = state.sortedInCatalogOrder(state.directions + [direction])
        }
        return .none

      case .saveButtonTapped:
        guard state.canSave else { return .none }
        state.isSaving = true
        state.saveFailed = false
        let (id, draft) = (state.note?.id, state.draft)
        return .run { [apiClient] send in
          await send(
            .saveResponse(
              Result {
                if let id {
                  try await apiClient.updateNote(id, draft)
                } else {
                  try await apiClient.addNote(draft)
                }
              }
            )
          )
        }

      case .closeButtonTapped:
        guard state.hasChanges else { return .run { [dismiss] _ in await dismiss() } }
        state.isDiscardDialogPresented = true
        return .none

      case .discardTapped:
        return .run { [dismiss] _ in await dismiss() }

      case let .saveResponse(.success(note)):
        return .run { [dismiss] send in
          await send(.delegate(.saved(note)))
          await dismiss()
        }

      case .saveResponse(.failure):
        state.isSaving = false
        state.saveFailed = true
        return .none

      case .binding, .delegate:
        return .none
      }
    }
  }
}

extension NoteType {
  /// The directions the editor offers, a UI choice: the API takes any. Never a reverse unless the user picks it.
  var directionCatalog: [Direction] {
    switch self {
    case .basic:
      [Direction(prompt: ["front"], answer: ["back"]), Direction(prompt: ["back"], answer: ["front"])]
    case .person:
      [
        Direction(prompt: ["photo"], answer: ["name"]),
        Direction(prompt: ["photo"], answer: ["name", "role"]),
        Direction(prompt: ["role"], answer: ["name"]),
      ]
    }
  }

  var defaultDirections: [Direction] {
    switch self {
    case .basic: [Direction(prompt: ["front"], answer: ["back"])]
    case .person: []
    }
  }

  var requiredFields: [String] {
    switch self {
    case .basic: ["front", "back"]
    case .person: ["name"]
    }
  }

  fileprivate var emptyFields: [String: String] {
    Dictionary(uniqueKeysWithValues: fields.map { ($0, "") })
  }
}

extension String {
  fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
