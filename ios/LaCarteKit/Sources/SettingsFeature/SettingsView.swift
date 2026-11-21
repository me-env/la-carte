import ComposableArchitecture
import DesignSystem
import SwiftUI

public struct SettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  @FocusState private var focusedField: Field?
  @State private var isTokenRevealed = false

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
        prompt: Text("Server URL").foregroundStyle(Theme.secondaryInk)
      )
      .keyboardType(.URL)
      .textContentType(.URL)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .focused($focusedField, equals: .url)
      .accessibilityIdentifier("settings.url")
      .modifier(SurfaceRow { focusedField = .url })
      tokenField
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

  /// Masked unless the user reveals it. Not a `SecureField`: iOS offers to save any typed secure text as a password
  /// when Settings closes, whatever its content type (QA 008 bug 2).
  private var tokenField: some View {
    HStack(spacing: Theme.Spacing.s) {
      Group {
        if isTokenRevealed {
          TextField("Token", text: $store.token, prompt: Text("Token").foregroundStyle(Theme.secondaryInk))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focusedField, equals: .token)
            .onAppear { focusedField = .token }
        } else {
          // One dot per character, as a secure field shows.
          let dots = String(repeating: "•", count: store.token.count)
          Text(store.token.isEmpty ? "Token" : dots)
            .foregroundStyle(store.token.isEmpty ? Theme.secondaryInk : Theme.ink)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Token")
            .accessibilityValue(dots)
            .accessibilityAddTraits(.isButton)
        }
      }
      .privacySensitive()
      .accessibilityIdentifier("settings.token")
      Button {
        isTokenRevealed.toggle()
      } label: {
        Image(systemName: isTokenRevealed ? "eye.slash" : "eye")
          .foregroundStyle(Theme.secondaryInk)
          .frame(width: 44, height: 44)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      // The 44pt button spans the row's full height instead of growing it.
      .padding(.vertical, -Theme.Spacing.s)
      .accessibilityLabel(isTokenRevealed ? "Hide token" : "Show token")
      .accessibilityIdentifier("settings.token.reveal")
    }
    .modifier(SurfaceRow { isTokenRevealed = true })
    .onChange(of: focusedField) { old, new in
      if old == .token, new != .token { isTokenRevealed = false }
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
    HStack(spacing: Theme.Spacing.s) {
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
