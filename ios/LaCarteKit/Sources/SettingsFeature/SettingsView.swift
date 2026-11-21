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
    NavigationStack {
      Form {
        server
        appearance
      }
      .scrollContentBackground(.hidden)
      .background(Theme.background)
      .foregroundStyle(Theme.ink)
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(role: .close) {
            store.send(.closeButtonTapped)
          }
          .accessibilityIdentifier("settings.close")
        }
      }
    }
    .tint(Theme.ink)
    .onAppear { store.send(.onAppear) }
  }

  private var server: some View {
    Section("Server") {
      TextField(
        "API URL", text: $store.apiURL.sending(\.urlChanged),
        prompt: Text("Server URL").foregroundStyle(Theme.secondaryInk)
      )
      .keyboardType(.URL)
      .textContentType(.URL)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .focused($focusedField, equals: .url)
      .tint(Theme.accent)
      .accessibilityIdentifier("settings.url")
      tokenField
      Button("Test connection") {
        store.send(.testButtonTapped)
      }
      .accessibilityIdentifier("settings.test")
      if let status = store.status {
        Text(status)
          .foregroundStyle(Theme.secondaryInk)
          .accessibilityIdentifier("settings.status")
      }
    }
    .listRowBackground(Rectangle().fill(Theme.surface))
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
            .tint(Theme.accent)
            .onAppear { focusedField = .token }
        } else {
          // One dot per character, as a secure field shows.
          let dots = String(repeating: "•", count: store.token.count)
          Text(store.token.isEmpty ? "Token" : dots)
            .foregroundStyle(store.token.isEmpty ? Theme.secondaryInk : Theme.ink)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { isTokenRevealed = true }
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
      // Borderless, so a tap elsewhere in the row doesn't trigger it.
      .buttonStyle(.borderless)
      // The 44pt button spans the row's full height instead of growing it.
      .padding(.vertical, -Theme.Spacing.s)
      .accessibilityLabel(isTokenRevealed ? "Hide token" : "Show token")
      .accessibilityIdentifier("settings.token.reveal")
    }
    .onChange(of: focusedField) { old, new in
      if old == .token, new != .token { isTokenRevealed = false }
    }
  }

  private var appearance: some View {
    Section("Appearance") {
      Picker("Theme", selection: Binding(get: { store.theme }, set: { store.send(.themeTapped($0)) })) {
        ForEach(AppTheme.allCases, id: \.self) { theme in
          Text(theme.rawValue.capitalized).tag(theme)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("settings.theme")
    }
    .listRowBackground(Rectangle().fill(Theme.surface))
  }
}

#Preview("Settings") {
  SettingsView(store: Store(initialState: SettingsFeature.State()) { SettingsFeature() })
}
