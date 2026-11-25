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
      setDirections(note?.cards.map(\.direction) ?? type.defaultDirections)
    }

    /// One direction per field of the type, then any other direction the note already has (e.g. from an agent).
    var catalog: [Direction] {
      type.fields.map { Self.normalized(Direction(prompt: [$0], answer: []), type: type, fields: fields) }
        + (note?.cards.map(\.direction) ?? []).filter { !type.isCatalogPrompt($0.prompt) }
    }

    /// An off direction that would show or ask for an empty field can't be turned on.
    func isUnavailable(_ direction: Direction) -> Bool {
      !directions.contains(direction) && !isComplete(direction)
    }

    var canSave: Bool {
      !isSaving
        && isFilled(type.requiredFields)
        && !directions.isEmpty
        && directions.allSatisfy(isComplete)
        && isPhotoValid
    }

    /// For a new note, the current type's empty fields and default directions count as unchanged.
    var hasChanges: Bool {
      let originalFields = type.emptyFields.merging(note?.fields ?? [:]) { $1 }
      let originalDirections = (note?.cards.map(\.direction) ?? type.defaultDirections)
        .map { Self.normalized($0, type: type, fields: originalFields) }
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

    private func isComplete(_ direction: Direction) -> Bool {
      !direction.prompt.isEmpty && !direction.answer.isEmpty && isFilled(direction.prompt + direction.answer)
    }

    /// Keeps the directions that are on in catalog order, each catalog one asking for the current other fields.
    fileprivate mutating func setDirections(_ directions: [Direction]) {
      let on = directions.map { Self.normalized($0, type: type, fields: fields) }
      self.directions = catalog.filter { on.contains($0) }
    }

    /// A catalog direction shows its one field and asks for every other non-empty one (person model, spec 014).
    private static func normalized(_ direction: Direction, type: NoteType, fields: [String: String]) -> Direction {
      guard type.isCatalogPrompt(direction.prompt) else { return direction }
      let answer = type.fields.filter { $0 != direction.prompt[0] && !(fields[$0]?.trimmed ?? "").isEmpty }
      return Direction(prompt: direction.prompt, answer: answer)
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
        state.setDirections(type.defaultDirections)
        return .none

      case let .fieldChanged(name, value):
        state.fields[name] = value
        state.setDirections(state.directions)
        return .none

      case let .directionToggled(direction):
        if let index = state.directions.firstIndex(of: direction) {
          state.directions.remove(at: index)
        } else if !state.isUnavailable(direction) {
          state.setDirections(state.directions + [direction])
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
  /// Basic starts with both directions, like a note an agent adds (spec 027); person starts with nothing.
  var defaultDirections: [Direction] {
    switch self {
    case .basic: [Direction(prompt: ["front"], answer: ["back"]), Direction(prompt: ["back"], answer: ["front"])]
    case .person: []
    }
  }

  var requiredFields: [String] {
    switch self {
    case .basic: ["front", "back"]
    case .person: ["name"]
    }
  }

  /// The editor offers one direction per field: that field as the prompt, the rest as the answer.
  func isCatalogPrompt(_ prompt: [String]) -> Bool {
    prompt.count == 1 && fields.contains(prompt[0])
  }

  fileprivate var emptyFields: [String: String] {
    Dictionary(uniqueKeysWithValues: fields.map { ($0, "") })
  }
}

extension String {
  fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
