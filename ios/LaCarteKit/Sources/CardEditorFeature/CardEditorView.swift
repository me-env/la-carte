import APIClient
import ComposableArchitecture
import DesignSystem
import SwiftUI

public struct CardEditorView: View {
  @Bindable var store: StoreOf<CardEditorFeature>
  @FocusState private var focusedField: Field?

  private enum Field: String {
    case front, back
  }

  public init(store: StoreOf<CardEditorFeature>) {
    self.store = store
  }

  public var body: some View {
    NavigationStack {
      Form {
        Section("Front") {
          field(.front, caption: "Front", prompt: "Word or question", text: $store.front)
        }
        Section {
          field(.back, caption: "Back", prompt: "Answer", text: $store.back)
        } header: {
          Text("Back")
        } footer: {
          if store.saveFailed {
            Text("Couldn't save. Check your connection.")
              .font(.meta)
              .foregroundStyle(Theme.secondaryInk)
              .accessibilityIdentifier("editor.error")
          }
        }
      }
      .scrollContentBackground(.hidden)
      .background(Theme.background)
      .foregroundStyle(Theme.ink)
      .navigationTitle(store.card == nil ? "New card" : "Edit card")
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
      if store.card == nil { focusedField = .front }
    }
  }

  private func field(_ field: Field, caption: String, prompt: String, text: Binding<String>) -> some View {
    TextField(caption, text: text, prompt: Text(prompt).foregroundStyle(Theme.secondaryInk), axis: .vertical)
      .focused($focusedField, equals: field)
      .tint(Theme.accent)
      .listRowBackground(Rectangle().fill(Theme.surface))
      .accessibilityIdentifier("editor.\(field.rawValue)")
  }
}

#Preview("New card") {
  CardEditorView(store: Store(initialState: CardEditorFeature.State()) { CardEditorFeature() })
}

#Preview("Edit card") {
  CardEditorView(
    store: Store(initialState: CardEditorFeature.State(card: [Card].fixtures[0])) { CardEditorFeature() }
  )
}
