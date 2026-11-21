import APIClient
import ComposableArchitecture
import DesignSystem
import SwiftUI

public struct StudyView: View {
  @Bindable var store: StoreOf<StudyFeature>
  @Environment(\.scenePhase) private var scenePhase
  @FocusState private var focusedField: StudyFeature.State.Field?

  public init(store: StoreOf<StudyFeature>) {
    self.store = store
  }

  public var body: some View {
    VStack(spacing: Theme.Spacing.m) {
      topBar
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refreshable { await store.send(.pulledToRefresh).finish() }
    }
    .padding(.horizontal, Theme.Spacing.m)
    .padding(.bottom, Theme.Spacing.m)
    .background(Theme.background)
    .onAppear { store.send(.onAppear) }
    .onChange(of: scenePhase) { _, phase in store.send(.scenePhaseChanged(phase)) }
    .onChange(of: store.editFailed) { _, failed in
      if failed { AccessibilityNotification.Announcement("Couldn't save the edit").post() }
    }
    .sensoryFeedback(.selection, trigger: store.editing) { _, new in new != nil }
    .sensoryFeedback(.error, trigger: store.editFailed) { _, new in new }
  }

  private var topBar: some View {
    HStack(spacing: Theme.Spacing.s) {
      CircleIconButton("list.bullet", accessibilityLabel: "Deck") {
        store.send(.deckButtonTapped)
      }
      .accessibilityIdentifier("study.deck")

      ZStack {
        if store.phase == .studying, store.editing == nil {
          if store.editFailed {
            counterText("Couldn't save the edit")
              .accessibilityIdentifier("study.editError")
              .transition(.opacity)
          } else if !store.cards.isEmpty {
            counterText("\(store.cards.count) to review")
              .accessibilityIdentifier("study.remaining")
          }
        }
      }
      .frame(maxWidth: .infinity)
      .animation(Theme.Motion.standard, value: store.editFailed)

      CircleIconButton("plus", accessibilityLabel: "Add card") {
        store.send(.addButtonTapped)
      }
      .accessibilityIdentifier("study.add")
    }
  }

  private func counterText(_ text: String) -> some View {
    Text(text)
      .font(.meta)
      .foregroundStyle(Theme.secondaryInk)
      .multilineTextAlignment(.center)
      .dynamicTypeSize(...DynamicTypeSize.accessibility2)
  }

  @ViewBuilder private var content: some View {
    switch store.phase {
    case .loading:
      pullable { Color.clear }

    case .studying:
      if let card = store.cards.first {
        studying(card)
      }

    case let .caughtUp(nextDue):
      pullable {
        VStack(spacing: Theme.Spacing.s) {
          Text("All caught up")
            .font(.cardFace)
            .foregroundStyle(Theme.ink)
            .accessibilityIdentifier("study.message")
          Text(Self.nextDueText(nextDue))
            .font(.meta)
            .foregroundStyle(Theme.secondaryInk)
            .accessibilityIdentifier("study.nextDue")
        }
        .multilineTextAlignment(.center)
      }

    case .offline:
      pullable {
        VStack(spacing: Theme.Spacing.m) {
          message("Can't reach your deck")
          CircleIconButton("arrow.clockwise", accessibilityLabel: "Retry") {
            store.send(.retryButtonTapped)
          }
          .accessibilityIdentifier("study.retry")
        }
      }

    case .notSetUp:
      settingsPrompt("Connect your deck", detail: "Add your server URL and token in Settings.")

    case .unauthorized:
      settingsPrompt("Token rejected", detail: "Check your token in Settings.")
    }
  }

  private func message(_ text: String) -> some View {
    Text(text)
      .font(.body)
      .foregroundStyle(Theme.ink)
      .multilineTextAlignment(.center)
      .accessibilityIdentifier("study.message")
  }

  /// "Connect your deck" and "Token rejected": both are fixed in Settings (spec 008).
  private func settingsPrompt(_ text: String, detail: String) -> some View {
    pullable {
      VStack(spacing: Theme.Spacing.m) {
        VStack(spacing: Theme.Spacing.s) {
          message(text)
          Text(detail)
            .font(.meta)
            .foregroundStyle(Theme.secondaryInk)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("study.detail")
        }
        Button { store.send(.openSettingsTapped) } label: { textButtonLabel("Open Settings") }
          .buttonStyle(.plain)
          .accessibilityIdentifier("study.openSettings")
      }
    }
  }

  /// A scroll view the size of the content area, so a centered message can be pulled to refresh.
  private func pullable(@ViewBuilder _ message: () -> some View) -> some View {
    ScrollView {
      message().containerRelativeFrame([.horizontal, .vertical])
    }
  }

  /// The back and a hidden copy of the rating row are always laid out, so the front never moves on reveal.
  /// The rating row shares the card text's `.accessibility2` cap so it never outgrows the card.
  private func studying(_ card: Card) -> some View {
    VStack(spacing: Theme.Spacing.m) {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: Theme.Spacing.m) {
            side(.front, text: card.front, font: .cardFace, color: Theme.ink)
            side(.back, text: card.back, font: .body, color: Theme.secondaryInk)
              .opacity(store.isRevealed ? 1 : 0)
              .accessibilityHidden(!store.isRevealed)
          }
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
          .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .scrollIndicatorsFlash(trigger: store.isRevealed)
        .scrollDismissesKeyboard(.interactively)
        .background {
          // While editing, the commit tap sits behind the field so taps that move the cursor never reach it.
          if store.editing != nil {
            Color.clear.contentShape(.rect).onTapGesture { store.send(.cardTapped) }
          }
        }
        .onChange(of: focusedField) { _, field in
          if let field {
            withAnimation(Theme.Motion.standard) { proxy.scrollTo(field, anchor: .center) }
          } else {
            store.send(.editEnded)
          }
        }
      }
      .contentShape(.rect)
      .gesture(TapGesture().onEnded { sendAnimated(.cardTapped) }, isEnabled: store.editing == nil)
      .accessibilityIdentifier("study.card")

      ZStack {
        ratingRow(ratingLabel).hidden().accessibilityHidden(true)
        if store.editing == nil {
          if store.isRevealed {
            ratingRow(ratingButton)
              .disabled(store.isReviewing)
              .transition(.opacity)
          } else {
            Button { sendAnimated(.revealTapped) } label: { textButtonLabel("Show answer") }
              .buttonStyle(.plain)
              .accessibilityIdentifier("study.reveal")
          }
        }
      }
      .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
  }

  /// One side of the card: its text, or in its place a field that looks the same while that side is edited.
  @ViewBuilder
  private func side(_ field: StudyFeature.State.Field, text: String, font: Font, color: ThemeColor) -> some View {
    let name = field == .front ? "front" : "back"
    let canEdit = store.isRevealed && store.editing == nil
    if store.editing == field {
      TextField("", text: $store.draft, axis: .vertical)
        .font(font)
        .foregroundStyle(color)
        .textFieldStyle(.plain)
        .submitLabel(.done)
        .tint(Theme.accent)
        .focused($focusedField, equals: field)
        .onSubmit { store.send(.editEnded) }
        .onAppear { focusedField = field }
        .id(field)
        .accessibilityLabel(field == .front ? "Front" : "Back")
        .accessibilityIdentifier("study.\(name)Field")
    } else {
      Text(text)
        .font(font)
        .foregroundStyle(color)
        .id(field)
        .allowsHitTesting(store.editing == nil)
        .gesture(TapGesture(count: 2).onEnded { store.send(.textDoubleTapped(field)) }, isEnabled: canEdit)
        .accessibilityActions {
          if canEdit {
            Button("Edit") { store.send(.textDoubleTapped(field)) }
          }
        }
        .accessibilityIdentifier("study.\(name)")
    }
  }

  private func ratingRow<Item: View>(_ item: @escaping (Rating) -> Item) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: Theme.Spacing.l) {
        ForEach(Rating.allCases, id: \.self, content: item)
      }
      Grid(horizontalSpacing: Theme.Spacing.l, verticalSpacing: Theme.Spacing.s) {
        GridRow { item(.again); item(.hard) }
        GridRow { item(.good); item(.easy) }
      }
    }
  }

  private func ratingButton(_ rating: Rating) -> some View {
    Button { store.send(.ratingTapped(rating)) } label: { ratingLabel(rating) }
      .buttonStyle(.plain)
      .accessibilityIdentifier("study.rate.\(rating.rawValue)")
  }

  private func ratingLabel(_ rating: Rating) -> some View {
    textButtonLabel(rating.rawValue.capitalized)
  }

  /// A plain button only hit-tests what it draws: the 44pt band must be in the label's shape, not outside the button.
  private func textButtonLabel(_ title: String) -> some View {
    Text(title)
      .font(.body)
      .foregroundStyle(Theme.ink)
      .frame(minHeight: 44)
      .contentShape(.rect)
  }

  /// Only the reveal fades; moving to the next card is instant so its back never flashes.
  private func sendAnimated(_ action: StudyFeature.Action) {
    withAnimation(Theme.Motion.standard) {
      _ = store.send(action)
    }
  }

  static func nextDueText(_ nextDue: Date?) -> String {
    guard let nextDue else { return "Your deck is empty" }
    return "Next card " + nextDue.formatted(.relative(presentation: .numeric))
  }
}

#Preview("Studying") {
  StudyView(store: Store(initialState: StudyFeature.State()) { StudyFeature() })
}

#Preview("Empty deck") {
  StudyView(store: Store(initialState: StudyFeature.State()) { StudyFeature() } withDependencies: {
    $0.apiClient = .inMemory(cards: [])
  })
}

#Preview("Not set up") {
  StudyView(store: Store(initialState: StudyFeature.State()) { StudyFeature() } withDependencies: {
    $0.apiClient.isConfigured = { false }
  })
}

#Preview("Editing the back") {
  var state = StudyFeature.State()
  state.cards = IdentifiedArray(uniqueElements: [Card].fixtures)
  state.phase = .studying
  state.isRevealed = true
  state.editing = .back
  state.draft = [Card].fixtures[0].back
  return StudyView(store: Store(initialState: state) { StudyFeature() })
}
