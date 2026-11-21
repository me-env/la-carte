import APIClient
import ComposableArchitecture
import DesignSystem
import Foundation

/// Points the app at the user's API: URL, token, and a check that both work (spec 003); picks the theme (spec 004).
@Reducer
public struct SettingsFeature {
  @ObservableState
  public struct State: Equatable {
    @Shared(.appStorage(APIClient.urlDefaultsKey)) var apiURL = ""
    @Shared(.theme) var theme
    var token = ""
    var connection: Connection = .idle

    public init() {}

    enum Connection: Equatable {
      case idle, checking, connected(total: Int), unauthorized, unreachable
    }

    var status: String? {
      switch connection {
      case .idle: nil
      case .checking: "Checking…"
      case let .connected(total): "Connected · \(total) \(total == 1 ? "card" : "cards")"
      case .unauthorized: "Wrong token"
      case .unreachable: "Can't reach server"
      }
    }
  }

  public enum Action: BindableAction {
    case binding(BindingAction<State>)
    /// Not a binding: `@Shared` values are written with `withLock`, which `BindingReducer` can't do.
    case urlChanged(String)
    case onAppear
    case testButtonTapped
    case themeTapped(AppTheme)
    case closeButtonTapped
    case statsResponse(Result<DeckStats, any Error>)
    case delegate(Delegate)

    @CasePathable
    public enum Delegate {
      case serverChanged
    }
  }

  @Dependency(\.apiClient) var apiClient
  @Dependency(\.dismiss) var dismiss
  @Dependency(\.tokenStore) var tokenStore

  private enum CancelID { case check }

  public init() {}

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.token):
        let token = state.token.isEmpty ? nil : state.token
        // Main-actor effects run in send order, so writes land in order and before a later Test, Close or swipe.
        return .merge(serverEdited(&state), .run { @MainActor [tokenStore] _ in try? tokenStore.save(token) })

      case let .urlChanged(url):
        state.$apiURL.withLock { $0 = url }
        return serverEdited(&state)

      case .onAppear:
        state.token = tokenStore.load() ?? ""
        return .none

      case .testButtonTapped:
        state.connection = .checking
        return .run { [apiClient] send in
          await send(.statsResponse(Result { try await apiClient.stats() }))
        }
        .cancellable(id: CancelID.check, cancelInFlight: true)

      case let .themeTapped(theme):
        state.$theme.withLock { $0 = theme }
        return .none

      case .closeButtonTapped:
        return .run { [dismiss] _ in await dismiss() }

      case let .statsResponse(.success(stats)):
        state.connection = .connected(total: stats.total)
        return .send(.delegate(.serverChanged))

      case let .statsResponse(.failure(error)):
        state.connection = (error as? APIError)?.isUnauthorized == true ? .unauthorized : .unreachable
        return .none

      case .binding, .delegate:
        return .none
      }
    }
  }

  /// A check result for the previous URL or token would be misleading, so it is dropped.
  private func serverEdited(_ state: inout State) -> Effect<Action> {
    state.connection = .idle
    return .cancel(id: CancelID.check)
  }
}

extension SharedKey where Self == AppStorageKey<AppTheme>.Default {
  /// The theme picked in Settings. Also read from the `-theme <value>` launch argument (UserDefaults argument domain).
  public static var theme: Self {
    Self[.appStorage(AppTheme.storageKey), default: .system]
  }
}
