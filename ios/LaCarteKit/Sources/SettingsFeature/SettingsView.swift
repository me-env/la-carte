import ComposableArchitecture
import DesignSystem
import SwiftUI

public struct SettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  @FocusState private var focusedField: Field?

  private enum Field {
    case url, token
  }

  public init(store: StoreOf<SettingsFeature>) {
    self.store = store
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.l) {
      header
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
          server
          appearance
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .padding([.horizontal, .top], Theme.Spacing.l)
    .background(Theme.background)
    .tint(Theme.ink)
    .onAppear { store.send(.onAppear) }
  }

  private var server: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
      Text("Server")
        .font(.meta)
        .foregroundStyle(Theme.secondaryInk)
        .accessibilityAddTraits(.isHeader)
      TextField(
        "API URL", text: $store.apiURL.sending(\.urlChanged),
        prompt: Text("http://127.0.0.1:8000").foregroundStyle(Theme.secondaryInk)
      )
      .keyboardType(.URL)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .focused($focusedField, equals: .url)
      .accessibilityIdentifier("settings.url")
      .modifier(SurfaceRow { focusedField = .url })
      SecureField(
        "Token", text: $store.token,
        prompt: Text("Token (optional)").foregroundStyle(Theme.secondaryInk)
      )
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .focused($focusedField, equals: .token)
      .accessibilityIdentifier("settings.token")
      .modifier(SurfaceRow { focusedField = .token })
      Button("Test connection") {
        store.send(.testButtonTapped)
      }
      .font(.body)
      .foregroundStyle(Theme.ink)
      .frame(minHeight: 44)
      .accessibilityIdentifier("settings.test")
      if let status = store.status {
        Text(status)
          .font(.meta)
          .foregroundStyle(Theme.secondaryInk)
          .accessibilityIdentifier("settings.status")
      }
    }
  }

  private var appearance: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
      Text("Appearance")
        .font(.meta)
        .foregroundStyle(Theme.secondaryInk)
        .accessibilityAddTraits(.isHeader)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: Theme.Spacing.s) { themeButtons }
        VStack(spacing: Theme.Spacing.s) { themeButtons }
      }
    }
  }

  private var themeButtons: some View {
    ForEach(AppTheme.allCases, id: \.self) { theme in
      let isSelected = store.theme == theme
      Button {
        store.send(.themeTapped(theme))
      } label: {
        Text(theme.rawValue.capitalized)
          .font(.body)
          .lineLimit(1)
          .foregroundStyle(isSelected ? Theme.background : Theme.ink)
          .padding(.horizontal, Theme.Spacing.s)
          .frame(maxWidth: .infinity, minHeight: 44)
          .background(isSelected ? Theme.ink : Theme.surface, in: .rect(cornerRadius: Theme.Radius.row))
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      .accessibilityIdentifier("settings.theme.\(theme.rawValue)")
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: Theme.Spacing.s) {
      Text("Settings")
        .font(.screenTitle)
        .foregroundStyle(Theme.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("settings.title")
      CircleIconButton("xmark", accessibilityLabel: "Close") {
        store.send(.closeButtonTapped)
      }
      .accessibilityIdentifier("settings.close")
    }
  }
}

/// A field on a `surface` row, radius 12, like the deck's search field. The whole row focuses the field.
private struct SurfaceRow: ViewModifier {
  let focus: () -> Void

  func body(content: Content) -> some View {
    content
      .font(.body)
      .foregroundStyle(Theme.ink)
      .padding(.horizontal, Theme.Spacing.m)
      .padding(.vertical, Theme.Spacing.s)
      .frame(minHeight: 44)
      .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.row))
      .contentShape(.rect(cornerRadius: Theme.Radius.row))
      .onTapGesture(perform: focus)
  }
}

#Preview("Settings") {
  SettingsView(store: Store(initialState: SettingsFeature.State()) { SettingsFeature() })
}
