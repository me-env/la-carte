@testable import APIClient
import AskAIClient
import ComposableArchitecture
import DesignSystem
import Foundation
import Testing

@testable import SettingsFeature

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SettingsFeatureTests {
  // Alone in its test bundle; see "Main serial executor" in docs/testing.md.
  init() { uncheckedUseMainSerialExecutor = true }

  struct Offline: Error {}
  let stats = DeckStats(total: 42, due: 3, new: 1, reviewedToday: 0, nextDue: nil)

  @Test func urlStartsEmptyAndEditsAreStoredImmediately() async {
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    }
    #expect(store.state.apiURL == "")

    await store.send(.urlChanged("https://cards.example.com")) {
      $0.$apiURL.withLock { $0 = "https://cards.example.com" }
    }
    @Shared(.appStorage(APIClient.urlDefaultsKey)) var stored = ""
    #expect(stored == "https://cards.example.com")
  }

  @Test func appearShowsTheStoredToken() async {
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0.tokenStore.load = { "secret" }
    }

    await store.send(.onAppear) {
      $0.token = "secret"
    }
  }

  @Test func everyTokenEditIsSavedAndEmptySavesNil() async {
    let saved = LockIsolated<[String?]>([])
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0.tokenStore.save = { token in saved.withValue { $0.append(token) } }
    }

    await store.send(\.binding.token, "s") {
      $0.token = "s"
    }
    await store.send(\.binding.token, "s3") {
      $0.token = "s3"
    }
    await store.send(\.binding.token, "") {
      $0.token = ""
    }
    await store.finish()
    #expect(saved.value == ["s", "s3", nil])
  }

  @Test func testingSeesTheTokenJustTyped() async {
    let saved = LockIsolated<String?>(nil)
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: { [stats] in
      $0.tokenStore.save = { saved.setValue($0) }
      $0.apiClient.stats = {
        #expect(saved.value == "s3")
        return stats
      }
    }

    await store.send(\.binding.token, "s3") {
      $0.token = "s3"
    }
    await store.send(.testButtonTapped) {
      $0.connection = .checking
    }
    await store.receive(\.statsResponse.success) {
      $0.connection = .connected(total: 42)
    }
    await store.receive(\.delegate.serverChanged)
  }

  @Test func testingShowsCheckingThenTheCardCountAndTellsTheParent() async {
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: { [stats] in
      $0.apiClient.stats = { stats }
    }

    await store.send(.testButtonTapped) {
      $0.connection = .checking
    }
    #expect(store.state.status == "Checking…")
    await store.receive(\.statsResponse.success) {
      $0.connection = .connected(total: 42)
    }
    #expect(store.state.status == "Connected · 42 cards")
    await store.receive(\.delegate.serverChanged)
  }

  @Test(arguments: [401, 403]) func aRejectedTokenSaysWrongToken(statusCode: Int) async {
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0.apiClient.stats = { throw APIError(statusCode: statusCode, message: "") }
    }

    await store.send(.testButtonTapped) {
      $0.connection = .checking
    }
    await store.receive(\.statsResponse.failure) {
      $0.connection = .unauthorized
    }
    #expect(store.state.status == "Wrong token")
  }

  @Test func anyOtherErrorSaysCantReachServer() async {
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0.apiClient.stats = { throw Offline() }
    }

    await store.send(.testButtonTapped) {
      $0.connection = .checking
    }
    await store.receive(\.statsResponse.failure) {
      $0.connection = .unreachable
    }
    #expect(store.state.status == "Can't reach server")
  }

  @Test func editingAfterACheckClearsTheStatus() async {
    var state = SettingsFeature.State()
    state.connection = .unauthorized
    let store = TestStore(initialState: state) {
      SettingsFeature()
    } withDependencies: {
      $0.tokenStore.save = { _ in }
      // Only cancellation ends this check: if editing didn't cancel it, the store would finish with it in flight.
      $0.apiClient.stats = { try await Task.never() }
    }

    await store.send(\.binding.token, "right") {
      $0.token = "right"
      $0.connection = .idle
    }
    #expect(store.state.status == nil)

    await store.send(.testButtonTapped) {
      $0.connection = .checking
    }
    // Editing mid-check drops the result, which would describe the previous URL.
    await store.send(.urlChanged("http://10.0.0.2:8000")) {
      $0.$apiURL.withLock { $0 = "http://10.0.0.2:8000" }
      $0.connection = .idle
    }
  }

  @Test func themeDefaultsToSystem() {
    #expect(SettingsFeature.State().theme == .system)
  }

  @Test func tappingAThemeStoresItAndANewLaunchReadsItBack() async {
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    }

    await store.send(.themeTapped(.forest)) {
      $0.$theme.withLock { $0 = .forest }
    }
    await store.send(.themeTapped(.light)) {
      $0.$theme.withLock { $0 = .light }
    }
    @Dependency(\.defaultAppStorage) var defaults
    #expect(defaults.string(forKey: "theme") == "light")
    #expect(SettingsFeature.State().theme == .light)
  }

  /// `-theme forest` lands in UserDefaults as the raw string, which is what the key reads.
  @Test func aRawThemeStringInUserDefaultsIsTheStartingTheme() {
    @Dependency(\.defaultAppStorage) var defaults
    defaults.set("forest", forKey: "theme")
    #expect(SettingsFeature.State().theme == .forest)
  }

  @Test func aiAppDefaultsToVibeAndAPickIsStoredForTheNextLaunch() async {
    #expect(SettingsFeature.State().aiApp == .vibe)
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    }

    await store.send(.aiAppPicked(.claude)) {
      $0.$aiApp.withLock { $0 = .claude }
    }
    await store.send(.aiAppPicked(.copyOnly)) {
      $0.$aiApp.withLock { $0 = .copyOnly }
    }
    @Dependency(\.defaultAppStorage) var defaults
    #expect(defaults.string(forKey: "aiApp") == "copyOnly")
    #expect(SettingsFeature.State().aiApp == .copyOnly)
  }

  @Test func thePickerListsTheSixChoicesInOrder() {
    #expect(AIApp.allCases.map(\.title) == ["Vibe", "Claude", "ChatGPT", "Perplexity", "Grok", "Copy only"])
  }

  @Test func closeDismisses() async {
    let dismissed = LockIsolated(false)
    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0.dismiss = DismissEffect { dismissed.setValue(true) }
    }

    await store.send(.closeButtonTapped)
    #expect(dismissed.value)
  }
}
