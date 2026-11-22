import APIClient
import ComposableArchitecture
import DesignSystem
import SwiftUI

public struct NoteEditorView: View {
  @Bindable var store: StoreOf<NoteEditorFeature>
  @FocusState private var focusedField: String?
  /// The preview URL that failed to load, if any; a new URL clears the footer until it fails too.
  @State private var failedPhotoURL: URL?

  public init(store: StoreOf<NoteEditorFeature>) {
    self.store = store
  }

  public var body: some View {
    NavigationStack {
      Form {
        if store.note == nil {
          Section {
            Picker("Type", selection: $store.type.sending(\.typeChanged)) {
              Text("Basic").tag(NoteType.basic)
              Text("Person").tag(NoteType.person)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("editor.type")
          }
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
        }
        switch store.type {
        case .basic:
          Section {
            field("front", prompt: "Word or question")
            field("back", prompt: "Answer")
          }
        case .person:
          photoSection
          Section {
            field("name", prompt: "Name")
            field("description", prompt: "Role, or how you know them")
              .lineLimit(1...3)
          }
        }
        directionsSection
      }
      .scrollContentBackground(.hidden)
      .background(Theme.background)
      .foregroundStyle(Theme.ink)
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(role: .close) {
            store.send(.closeButtonTapped)
          }
          .accessibilityIdentifier("editor.close")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(role: .confirm) {
            store.send(.saveButtonTapped)
          }
          .disabled(!store.canSave)
          .accessibilityLabel("Save")
          .accessibilityIdentifier("editor.save")
        }
      }
      .confirmationDialog(
        "Discard changes?", isPresented: $store.isDiscardDialogPresented, titleVisibility: .visible
      ) {
        Button("Discard", role: .destructive) {
          store.send(.discardTapped)
        }
        .accessibilityIdentifier("editor.discard")
        Button("Keep editing", role: .cancel) {}
          .accessibilityIdentifier("editor.keepEditing")
      }
    }
    .tint(Theme.ink)
    .interactiveDismissDisabled(store.hasChanges)
    .sensoryFeedback(.error, trigger: store.saveFailed) { _, new in new }
    .onAppear {
      if store.note == nil { focusedField = "front" }
    }
  }

  private var title: String {
    switch (store.type, store.note == nil) {
    case (.basic, true): "New card"
    case (.basic, false): "Edit card"
    case (.person, true): "New person"
    case (.person, false): "Edit person"
    }
  }

  /// The preview is its own bare row above the URL's section, so that section keeps its rounded top.
  @ViewBuilder private var photoSection: some View {
    Section {
      CardPhoto(url: store.photoURL, style: .preview) { failedPhotoURL = store.photoURL }
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("editor.photoPreview")
    }
    Section {
      field("photo", prompt: "Photo URL")
        .keyboardType(.URL)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    } footer: {
      if failedPhotoURL != nil, failedPhotoURL == store.photoURL {
        Text("Couldn't load this photo")
          .font(.meta)
          .foregroundStyle(Theme.secondaryInk)
      }
    }
  }

  private var directionsSection: some View {
    Section {
      ForEach(store.catalog, id: \.self) { direction in
        directionRow(direction)
      }
    } header: {
      Text("Directions")
    } footer: {
      VStack(alignment: .leading, spacing: Theme.Spacing.s) {
        if store.directions.isEmpty {
          Text("Choose at least one direction")
            .accessibilityIdentifier("editor.directionsHint")
        } else if store.type == .person {
          Text("Each direction is its own card: it shows that field and asks for the rest.")
        } else {
          Text("Each direction is its own card.")
        }
        if store.saveFailed {
          Text("Couldn't save. Check your connection.")
            .accessibilityIdentifier("editor.error")
        }
      }
      .font(.meta)
      .foregroundStyle(Theme.secondaryInk)
    }
  }

  private func directionRow(_ direction: Direction) -> some View {
    let isOn = store.directions.contains(direction)
    let isUnavailable = store.state.isUnavailable(direction)
    return Button {
      store.send(.directionToggled(direction))
    } label: {
      HStack {
        Text(Self.label(direction, type: store.type, side: " → ", join: " + "))
          .foregroundStyle(isUnavailable ? Theme.secondaryInk : Theme.ink)
        Spacer(minLength: Theme.Spacing.s)
        if isOn {
          Image(systemName: "checkmark")
            .foregroundStyle(Theme.ink)
        }
      }
      .contentShape(.rect)
    }
    .disabled(isUnavailable)
    .listRowBackground(Rectangle().fill(Theme.surface))
    .accessibilityLabel(Self.label(direction, type: store.type, side: " to ", join: " and "))
    .accessibilityAddTraits(isOn ? .isSelected : [])
    .accessibilityIdentifier("editor.direction.\(Self.identifier(direction, type: store.type))")
  }

  /// "Front → Back" ("Front to Back" for VoiceOver). A catalog direction names every other field of the type, so its
  /// label and id don't change while fields are typed: "Photo → Name + Description", `photo-name+description`.
  static func label(_ direction: Direction, type: NoteType, side: String, join: String) -> String {
    [direction.prompt, answer(direction, type: type)]
      .map { $0.map(\.capitalized).joined(separator: join) }
      .joined(separator: side)
  }

  /// `<prompt>-<answer>`, fields joined by `+`.
  static func identifier(_ direction: Direction, type: NoteType) -> String {
    "\(direction.prompt.joined(separator: "+"))-\(answer(direction, type: type).joined(separator: "+"))"
  }

  private static func answer(_ direction: Direction, type: NoteType) -> [String] {
    guard type.isCatalogPrompt(direction.prompt) else { return direction.answer }
    return type.answerOrder.filter { $0 != direction.prompt[0] }
  }

  private func field(_ name: String, prompt: String) -> some View {
    TextField(
      name.capitalized,
      // The field writes its unchanged text back as the sheet goes away; sending that would reach a dismissed editor.
      text: Binding(
        get: { store.fields[name] ?? "" },
        set: { if $0 != store.fields[name] ?? "" { store.send(.fieldChanged(name, $0)) } }
      ),
      prompt: Text(prompt).foregroundStyle(Theme.secondaryInk),
      axis: .vertical
    )
    .focused($focusedField, equals: name)
    .tint(Theme.accent)
    .listRowBackground(Rectangle().fill(Theme.surface))
    .accessibilityIdentifier("editor.\(name)")
  }
}

#Preview("New card") {
  NoteEditorView(store: Store(initialState: NoteEditorFeature.State()) { NoteEditorFeature() })
}

#Preview("Edit person") {
  NoteEditorView(
    store: Store(initialState: NoteEditorFeature.State(note: [Note].fixtures[0])) { NoteEditorFeature() }
  )
}

extension NoteType {
  /// The order of a catalog direction's answer fields in its label and id (spec 014c): name before photo.
  fileprivate var answerOrder: [String] {
    switch self {
    case .basic: fields
    case .person: ["name", "photo", "description"]
    }
  }
}
