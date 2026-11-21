import APIClient
import ComposableArchitecture
import DesignSystem
import SwiftUI

public struct StudyView: View {
  let store: StoreOf<StudyFeature>
  @Environment(\.scenePhase) private var scenePhase

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
    // While the content is empty (last card rated, caught-up not loaded yet) the stack would shrink to the top bar.
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.background)
    .onAppear { store.send(.onAppear) }
    .onChange(of: scenePhase) { _, phase in store.send(.scenePhaseChanged(phase)) }
  }

  private var topBar: some View {
    HStack(spacing: Theme.Spacing.s) {
      CircleIconButton("list.bullet", accessibilityLabel: "Deck") {
        store.send(.deckButtonTapped)
      }
      .accessibilityIdentifier("study.deck")

      ZStack {
        if store.phase == .studying, !store.cards.isEmpty {
          Text("\(store.cards.count) to review")
            .font(.meta)
            .foregroundStyle(Theme.secondaryInk)
            .multilineTextAlignment(.center)
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .accessibilityIdentifier("study.remaining")
        }
      }
      .frame(maxWidth: .infinity)

      CircleIconButton("plus", accessibilityLabel: "Add card") {
        store.send(.addButtonTapped)
      }
      .accessibilityIdentifier("study.add")
    }
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
  /// Width comes from the proposal, not `containerRelativeFrame(.horizontal)`: that one resolved to the full
  /// window width, which the vertical scroll view adopted, pushing the top bar past its margins.
  private func pullable(@ViewBuilder _ message: () -> some View) -> some View {
    ScrollView {
      message()
        .frame(maxWidth: .infinity)
        .containerRelativeFrame(.vertical)
    }
  }

  /// The back and a hidden copy of the rating row are always laid out, so the front never moves on reveal.
  /// The rating row shares the card text's `.accessibility2` cap so it never outgrows the card.
  private func studying(_ card: Card) -> some View {
    VStack(spacing: Theme.Spacing.m) {
      ScrollView {
        VStack(spacing: Theme.Spacing.m) {
          Text(card.front)
            .font(.cardFace)
            .foregroundStyle(Theme.ink)
            .accessibilityIdentifier("study.front")
          Text(card.back)
            .font(.body)
            .foregroundStyle(Theme.secondaryInk)
            .opacity(store.isRevealed ? 1 : 0)
            .accessibilityHidden(!store.isRevealed)
            .accessibilityIdentifier("study.back")
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
      }
      .defaultScrollAnchor(.center, for: .alignment)
      .scrollIndicatorsFlash(trigger: store.isRevealed)
      .contentShape(.rect)
      .onTapGesture { reveal() }
      .accessibilityIdentifier("study.card")

      ZStack {
        ratingRow(ratingLabel).hidden().accessibilityHidden(true)
        if store.isRevealed {
          ratingRow(ratingButton)
            .disabled(store.isReviewing)
            .transition(.opacity)
        } else {
          Button { reveal() } label: { textButtonLabel("Show answer") }
            .buttonStyle(.plain)
            .accessibilityIdentifier("study.reveal")
        }
      }
      .dynamicTypeSize(...DynamicTypeSize.accessibility2)
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
  private func reveal() {
    withAnimation(.easeInOut(duration: 0.25)) {
      _ = store.send(.revealTapped)
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
