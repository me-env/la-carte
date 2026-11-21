import APIClient
import ComposableArchitecture
import DesignSystem
import SwiftUI

public struct StudyView: View {
  let store: StoreOf<StudyFeature>

  public init(store: StoreOf<StudyFeature>) {
    self.store = store
  }

  public var body: some View {
    VStack(spacing: Theme.Spacing.m) {
      topBar
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding(.horizontal, Theme.Spacing.m)
    .padding(.bottom, Theme.Spacing.m)
    .background(Theme.background)
    .onAppear { store.send(.onAppear) }
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
      Color.clear

    case .studying:
      if let card = store.cards.first {
        studying(card)
      }

    case let .caughtUp(nextDue):
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

    case .offline:
      VStack(spacing: Theme.Spacing.m) {
        Text("Can't reach your deck")
          .font(.body)
          .foregroundStyle(Theme.ink)
          .multilineTextAlignment(.center)
          .accessibilityIdentifier("study.message")
        CircleIconButton("arrow.clockwise", accessibilityLabel: "Retry") {
          store.send(.retryButtonTapped)
        }
        .accessibilityIdentifier("study.retry")
      }
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
      .scrollBounceBehavior(.basedOnSize)
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
          Button("Show answer") { reveal() }
            .font(.body)
            .foregroundStyle(Theme.ink)
            .buttonStyle(.plain)
            .frame(minHeight: 44)
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
    Text(rating.rawValue.capitalized)
      .font(.body)
      .foregroundStyle(Theme.ink)
      .frame(minHeight: 44)
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
