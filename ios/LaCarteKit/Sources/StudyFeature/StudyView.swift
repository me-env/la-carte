import APIClient
import ComposableArchitecture
import DesignSystem
import SwiftUI

public struct StudyView: View {
  @Bindable var store: StoreOf<StudyFeature>
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var focusedField: StudyFeature.State.Field?
  /// Where the rating drag came down, in the card's coordinates: the ring's center. Visual only.
  @State private var touchDown: CGPoint?
  @State private var cardSize = CGSize.zero
  /// The edit field's frame in the card, so a tap inside it moves the caret instead of committing.
  @State private var fieldFrame = CGRect.zero

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
    .onChange(of: store.editFailed) { _, failed in
      if failed { AccessibilityNotification.Announcement("Couldn't save the edit").post() }
    }
    .sensoryFeedback(.selection, trigger: store.editing) { _, new in new != nil }
    .sensoryFeedback(.error, trigger: store.editFailed) { _, new in new }
    .sensoryFeedback(trigger: store.swipeRating) { _, new in
      switch new {
      case .hard, .good: .selection
      case .again, .easy: .impact(weight: .medium)
      case nil: nil
      }
    }
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
            prompt(card)
            answerSlot(card)
          }
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
          .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .scrollIndicatorsFlash(trigger: store.isRevealed)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: focusedField) { _, field in
          if let field {
            // Not animated: an animated scroll can read as a drag and dismiss the keyboard (interactively).
            proxy.scrollTo(field, anchor: .center)
          } else {
            store.send(.editEnded)
          }
        }
      }
      .contentShape(.rect)
      .gesture(
        SpatialTapGesture(coordinateSpace: .named(Self.cardSpace)).onEnded { tap in
          guard store.editing == nil || !fieldFrame.contains(tap.location) else { return }
          sendAnimated(.cardTapped)
        }
      )
      .coordinateSpace(.named(Self.cardSpace))
      // Off unless `canRate` (so never while editing); a pan needs movement, so taps pass through.
      .gesture(
        HorizontalPan(isEnabled: store.canRate) { start, translation in
          touchDown = start
          store.send(.swipeChanged(fraction: swipeFraction(translation)))
        } onEnd: { translation in
          store.send(.swipeEnded(fraction: swipeFraction(translation)))
        }
      )
      .onGeometryChange(for: CGSize.self, of: \.size) { cardSize = $0 }
      .accessibilityIdentifier("study.card")
      // After the card's identifier, so the ring keeps its own.
      .overlay { swipeRing }
      #if DEBUG
        .onChange(of: store.canRate, initial: true) { _, canRate in
          guard canRate, let fraction = Self.swipePreview else { return }
          touchDown = nil
          store.send(.swipeChanged(fraction: fraction))
        }
      #endif

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
      TextField("", text: $store.draft.sending(\.draftChanged), axis: .vertical)
        .font(font)
        .foregroundStyle(color)
        .textFieldStyle(.plain)
        .submitLabel(.done)
        .tint(Theme.accent)
        .focused($focusedField, equals: field)
        .onSubmit { store.send(.editEnded) }
        .onAppear { focusedField = field }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.cardSpace)) }) { fieldFrame = $0 }
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
          ratingActions
        }
        .accessibilityIdentifier("study.\(name)")
    }
  }

  @ViewBuilder private var ratingActions: some View {
    if store.canRate {
      ForEach(Rating.allCases, id: \.self) { rating in
        Button(Self.title(rating)) { store.send(.ratingTapped(rating)) }
      }
    }
  }

  /// The prompt fields (spec 014d): a photo replaces the centered word; the first text field is the card face.
  @ViewBuilder private func prompt(_ card: Card) -> some View {
    if store.canEditInline {
      side(.front, text: card.text(.front), font: .cardFace, color: Theme.ink)
    } else {
      let firstText = card.shown(card.prompt).first { $0 != Card.photoField }
      VStack(spacing: Theme.Spacing.s) {
        ForEach(card.shown(card.prompt), id: \.self) { name in
          field(
            name, of: card, font: name == firstText ? .cardFace : .body,
            color: name == firstText ? Theme.ink : Theme.secondaryInk
          )
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityActions { ratingActions }
      .accessibilityIdentifier("study.front")
    }
  }

  /// The answer and, before reveal, a person card's hint share one slot, so the prompt never moves.
  private func answerSlot(_ card: Card) -> some View {
    ZStack {
      if let hint = store.answerHint {
        Text(hint)
          .font(.meta)
          .foregroundStyle(Theme.secondaryInk)
          .opacity(store.isRevealed ? 0 : 1)
          .accessibilityHidden(store.isRevealed)
          .accessibilityIdentifier("study.answerHint")
      }
      answer(card)
        .opacity(store.isRevealed ? 1 : 0)
        .accessibilityHidden(!store.isRevealed)
    }
  }

  @ViewBuilder private func answer(_ card: Card) -> some View {
    if store.canEditInline {
      side(.back, text: card.text(.back), font: .body, color: Theme.secondaryInk)
    } else {
      VStack(spacing: Theme.Spacing.xs) {
        ForEach(card.shown(card.answer), id: \.self) { name in
          field(name, of: card, font: .body, color: Theme.secondaryInk)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityActions { ratingActions }
      .accessibilityIdentifier("study.back")
    }
  }

  /// A photo field shows the image at its public URL, never the URL text.
  @ViewBuilder
  private func field(_ name: String, of card: Card, font: Font, color: ThemeColor) -> some View {
    if name == Card.photoField {
      CardPhoto(url: card.fields[name].flatMap(URL.init(string:)), style: .card)
        .accessibilityIdentifier("study.photo")
    } else {
      Text(card.fields[name] ?? "")
        .font(font)
        .foregroundStyle(color)
    }
  }

  /// Forgot and Got it; Hard and Easy are reached by dragging (spec 011).
  private func ratingRow<Item: View>(_ item: @escaping (Rating) -> Item) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: Theme.Spacing.xl) { item(.again); item(.good) }
      VStack(spacing: Theme.Spacing.s) { item(.again); item(.good) }
    }
  }

  private func ratingButton(_ rating: Rating) -> some View {
    Button { store.send(.ratingTapped(rating)) } label: { ratingLabel(rating) }
      .buttonStyle(.plain)
      .accessibilityIdentifier("study.rate.\(rating.rawValue)")
  }

  private func ratingLabel(_ rating: Rating) -> some View {
    textButtonLabel(Self.title(rating))
  }

  private nonisolated static let cardSpace = "study.card"

  static func title(_ rating: Rating) -> String {
    switch rating {
    case .again: "Forgot"
    case .hard: "Hard"
    case .good: "Got it"
    case .easy: "Easy"
    }
  }

  /// The dots around the touch-down point while a drag is held. With Reduce Motion they jump between the five
  /// bin drawings instead of morphing. Appears and fades out by opacity only; the card never moves.
  private var swipeRing: some View {
    ZStack {
      if let ease = store.swipeEase {
        ConfidenceDots(
          order: reduceMotion ? Self.binOrder(store.swipeRating) : ease,
          radius: StudyFeature.ringRadius * cardSize.width
        )
        .position(touchDown ?? CGPoint(x: cardSize.width / 2, y: cardSize.height / 2))
        .accessibilityElement()
        .accessibilityLabel("Rating")
        .accessibilityValue(store.swipeRating.map(Self.title) ?? "None")
        .accessibilityIdentifier("study.swipeRing")
        .transition(.opacity)
      }
    }
    .allowsHitTesting(false)
    .animation(Theme.Motion.standard, value: store.swipeEase == nil)
  }

  private static func binOrder(_ rating: Rating?) -> Double {
    switch rating {
    case .again: 0
    case .hard: 0.25
    case nil: 0.5
    case .good: 0.75
    case .easy: 1
    }
  }

  private func swipeFraction(_ translation: CGFloat) -> Double {
    cardSize.width > 0 ? translation / cardSize.width : 0
  }

  #if DEBUG
    /// `-studySwipePreview <f>` holds a drag at `f` card widths so QA can screenshot the dots (spec 011).
    /// A negative value must be written `"<real>-0.13</real>"` (or `" -0.13"`): a bare `-0.13` reads as a flag.
    static let swipePreview: Double? =
      UserDefaults.standard.object(forKey: "studySwipePreview") != nil
      ? UserDefaults.standard.double(forKey: "studySwipePreview") : nil
  #endif

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

#Preview("Person photo") {
  StudyView(store: Store(initialState: StudyFeature.State()) { StudyFeature() } withDependencies: {
    $0.apiClient = .inMemory(notes: .fixtures)
  })
}

#Preview("Rating drag held") {
  var state = StudyFeature.State()
  state.cards = IdentifiedArray(uniqueElements: [Card].fixtures)
  state.phase = .studying
  state.isRevealed = true
  state.swipeEase = 0.76
  return StudyView(store: Store(initialState: state) { StudyFeature() })
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
