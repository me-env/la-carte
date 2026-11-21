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
    VStack(alignment: .leading, spacing: Theme.Spacing.l) {
      header
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
          field(.front, caption: "Front", prompt: "Word or question", text: $store.front)
          field(.back, caption: "Back", prompt: "Answer", text: $store.back)
          if store.saveFailed {
            Text("Couldn't save. Check your connection.")
              .font(.meta)
              .foregroundStyle(Theme.secondaryInk)
              .accessibilityIdentifier("editor.error")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .padding([.horizontal, .top], Theme.Spacing.l)
    .background(Theme.background)
    .tint(Theme.ink)
    .onAppear {
      if store.card == nil { focusedField = .front }
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: Theme.Spacing.s) {
      Text(store.card == nil ? "New card" : "Edit card")
        .font(.screenTitle)
        .foregroundStyle(Theme.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("editor.title")
      CircleIconButton("checkmark", accessibilityLabel: "Save") {
        store.send(.saveButtonTapped)
      }
      .disabled(!store.canSave)
      .accessibilityIdentifier("editor.save")
      CircleIconButton("xmark", accessibilityLabel: "Close") {
        store.send(.closeButtonTapped)
      }
      .accessibilityIdentifier("editor.close")
    }
  }

  private func field(_ field: Field, caption: String, prompt: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
      Text(caption)
        .font(.meta)
        .foregroundStyle(Theme.secondaryInk)
        .accessibilityHidden(true)
      TextField(caption, text: text, prompt: Text(prompt).foregroundStyle(Theme.secondaryInk), axis: .vertical)
        .font(.body)
        .foregroundStyle(Theme.ink)
        .focused($focusedField, equals: field)
        .accessibilityIdentifier("editor.\(field.rawValue)")
    }
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
