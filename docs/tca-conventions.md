# TCA conventions (Composable Architecture 1.26, preparing for 2.0)

We follow Point-Free's current guidance. The package enables the
`ComposableArchitecture2Deprecations` trait, so **any deprecation warning is a bug to fix**, not ignore.
When in doubt, mirror the official examples (SyncUps, Todos) in the TCA repo.

## A feature

```swift
@Reducer
public struct StudyFeature {
  @ObservableState
  public struct State: Equatable {
    var cards: IdentifiedArrayOf<Card> = []
    var isRevealed = false
    @Presents var destination: Destination.State?
  }

  public enum Action: BindableAction {          // BindableAction only if the view binds
    case binding(BindingAction<State>)
    case onAppear                               // view actions: what happened, not what to do
    case revealTapped
    case ratingTapped(Rating)
    case cardsResponse(Result<[Card], any Error>) // effect results: <thing>Response
    case destination(PresentationAction<Destination.Action>)
  }

  @Dependency(\.apiClient) var apiClient

  public var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .onAppear:
        return .run { [apiClient] send in
          await send(.cardsResponse(Result { try await apiClient.dueCards(20) }))
        }
      …
      }
    }
    .ifLet(\.$destination, action: \.destination)
  }
}
```

## Rules

**State & actions**
- `@ObservableState` on every State; State is `Equatable`.
- Collections of child state: `IdentifiedArrayOf`.
- Actions are named for **what happened** (`saveButtonTapped`, `cardsResponse`), never imperative (`loadCards`).
- Effect results: `Result<Value, any Error>` (not the deprecated `TaskResult`).
- Logic shared between actions goes in a private helper method on the reducer, not in "internal" actions sent to self.
- Bindings to `@Shared` state: `BindingReducer` can't write it (the setter is deprecated); send a plain action
  (`$store.apiURL.sending(\.urlChanged)`) and write with `state.$apiURL.withLock { $0 = url }`.

**Effects**
- Only `.run { … }`, `.none`, `.send`, `.cancel(id:)`. Capture dependencies explicitly: `.run { [apiClient] send in … }`.
- Animation: the view wraps the send, `withAnimation(.easeInOut(duration: 0.25)) { _ = store.send(.x) }`
  (`send(_:animation:)` is deprecated under the 2.0 deprecations trait; see `StudyView.reveal()`).
- Debounce: `clock.sleep` + `.cancellable(id:cancelInFlight:)`.
- No `Effect.concatenate`/`.map`/Combine publishers. Never call `reducer.reduce(into:action:)`.
- Never send an action synchronously from within action processing (reentrancy warning).

**Composition & navigation**
- Child scoping: `Scope(\.child, action: \.child)` and `store.scope(\.child, action: \.child)` (1.26 label-less form).
- Collections: `.forEach(\.rows, action: \.rows)` + `ForEach(store.scope(\.rows, action: \.rows))`.
- Tree navigation: `@Presents` + `@Reducer enum Destination` + `.ifLet(\.$destination, action: \.destination)`.
  View: `.sheet(item: $store.scope(\.$destination, action: \.destination).edit)` (enum scope syntax).
- Alerts in a destination: `@ReducerCaseIgnored case alert(AlertState<Alert>)` with an explicit `Action` enum.
- Stack navigation (if ever needed): `StackState` / `StackAction` with `NavigationStack(path:)`.
- Children talk to parents through **delegate actions** (`case delegate(Delegate)`), parents never inspect child internals.
- Dismiss from the child with `@Dependency(\.dismiss)`.

**Dependencies**
- Every side effect (network, clock, uuid, date, persistence) is a dependency. Use the built-ins
  (`\.continuousClock`, `\.date.now`, `\.uuid`) — never `Date()` / `UUID()` in reducers.
- Clients: `@DependencyClient` struct of closures, in its own module, with `liveValue`,
  `testValue` (unimplemented via the macro) and `previewValue`.
- Shared/persisted state (e.g. user settings): `@Shared(.appStorage(…))` / `@Shared(.fileStorage(…))`.

**Views**
- `let store: StoreOf<Feature>` (or `@Bindable var store` when deriving bindings).
- Read state directly (`store.cards`), send with `store.send(.x)`. No `WithViewStore`, no `ViewStore`.
- Views contain zero logic beyond formatting. If an `if` decides behavior, it belongs in the reducer.
- Every feature view has a `#Preview` using a real `Store` (previews get `previewValue` dependencies).
- `accessibilityIdentifier("<feature>.<element>")` on everything a UI test needs.

**Tests** (`Tests/<Feature>Tests`, Swift Testing)
- `@MainActor struct XFeatureTests { @Test func … }` with `TestStore`, exhaustive by default.
- Override only the dependency endpoints the test uses: `$0.apiClient.dueCards = { _ in [...] }`.
- Receive by case key path: `await store.receive(\.cardsResponse.success) { … }`.
- Time: `TestClock`; ids: `.incrementing` UUID generator.
- One test per acceptance criterion that involves logic; name it after the behavior.

## Simplicity checklist (code-reviewer uses this)
- [ ] Could this be fewer types / fewer actions / fewer lines without losing clarity?
- [ ] No unused state, actions, dependencies or `public` surface.
- [ ] No deprecation warnings, no `@preconcurrency`, no force unwraps outside fixtures.
- [ ] Names read like the spec's vocabulary (card, deck, review, due).
