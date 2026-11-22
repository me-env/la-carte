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
  /// The edit field's global frame: a touch that starts inside it moves the caret instead of ending the edit.
  @State private var fieldFrame = CGRect.zero
  @State private var reportMenuHeight: CGFloat = 360

  public init(store: StoreOf<StudyFeature>) {
    self.store = store
  }

  public var body: some View {
    // One top bar for every phase; only the content below it changes.
    VStack(spacing: Theme.Spacing.m) {
      topBar
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refreshable { await store.send(.pulledToRefresh).finish() }
    }
    .padding(.horizontal, Theme.Spacing.m)
    .padding(.bottom, Theme.Spacing.m)
    // Top-aligned: while the content is empty (last card rated, caught-up not loaded yet) the stack shrinks to
    // the top bar, which must stay at the top of the safe area, not drop to the middle.
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Theme.background)
    .sheet(isPresented: $store.isReportMenuShown) { reportMenu }
    .onAppear { store.send(.onAppear) }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { focusedField = nil }
      store.send(.scenePhaseChanged(phase))
    }
    .onChange(of: store.editFailed) { _, failed in
      if failed { AccessibilityNotification.Announcement("Couldn't save the edit").post() }
    }
    .sensoryFeedback(.selection, trigger: store.editing) { _, new in new != nil }
    .sensoryFeedback(.error, trigger: store.editFailed) { _, new in new }
    .sensoryFeedback(.success, trigger: store.notice) { _, new in new == .reported }
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
        // The notice outlives the session: reporting the last card still shows "Reported" once caught up.
        if store.editing == nil {
          if store.phase == .studying, store.editFailed {
            counterText("Couldn't save the edit")
              .accessibilityIdentifier("study.editError")
              .transition(.opacity)
          } else if let notice = store.notice {
            counterText(Self.text(notice))
              .accessibilityIdentifier("study.reportNotice")
              .transition(.opacity)
          } else if store.phase == .studying, !store.cards.isEmpty {
            counterText(Text("\(Text(store.cards.count, format: .number).foregroundStyle(Theme.accent)) to review"))
              .accessibilityIdentifier("study.remaining")
          }
        }
      }
      .frame(maxWidth: .infinity)
      .animation(Theme.Motion.standard, value: store.editFailed)
      .animation(Theme.Motion.standard, value: store.notice)

      CircleIconButton("plus", accessibilityLabel: "Add card") {
        store.send(.addButtonTapped)
      }
      .accessibilityIdentifier("study.add")
    }
  }

  static func text(_ notice: StudyFeature.State.Notice) -> String {
    switch notice {
    case .reported: "Reported"
    case .failed: "Couldn't send the report"
    case .copied: "Copied"
    case let .copiedNotInstalled(app): "Copied · \(app) isn't installed"
    }
  }

  private func counterText(_ text: String) -> some View {
    counterText(Text(text))
  }

  /// Secondary ink; an interpolated `Text` keeps its own style (the count's accent, design-system rule 4).
  private func counterText(_ text: Text) -> some View {
    text
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
      caughtUp(subtitle: nextDue.map(Self.nextDueText))

    case .empty:
      pullable {
        VStack(spacing: Theme.Spacing.s) {
          message("No cards yet")
          detail("Ask your agent to add some")
        }
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

  private func detail(_ text: String) -> some View {
    Text(text)
      .font(.meta)
      .foregroundStyle(Theme.secondaryInk)
      .multilineTextAlignment(.center)
      .accessibilityIdentifier("study.detail")
  }

  /// "Connect your deck" and "Token rejected": both are fixed in Settings (spec 008).
  private func settingsPrompt(_ text: String, detail: String) -> some View {
    pullable {
      VStack(spacing: Theme.Spacing.m) {
        VStack(spacing: Theme.Spacing.s) {
          message(text)
          self.detail(detail)
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
        // Not `.interactively`: on a card that fits, the keyboard never followed the drag and stayed up.
        .scrollDismissesKeyboard(.immediately)
        // Focus is the one source of truth for ending an edit: Done, a tap outside, a keyboard swipe, leaving
        // the app all just drop focus, and the drop sends a single `editEnded`.
        .onChange(of: focusedField) { _, field in
          if let field {
            // Not animated: an animated scroll can read as a drag and dismiss the keyboard (interactively).
            proxy.scrollTo(field, anchor: .center)
          } else if store.editing != nil {
            store.send(.editEnded)
          }
        }
        .onChange(of: store.editing) { _, editing in
          if editing == nil { focusedField = nil }
        }
      }
      .contentShape(.rect)
      // Before the single tap, so it waits for a second tap; only on when revealed, so revealing isn't delayed.
      // The text's own double tap (010, edit) is on a child view, so it wins there.
      .gesture(TapGesture(count: 2).onEnded { store.send(.cardDoubleTapped) }, isEnabled: store.canReport)
      .gesture(
        TapGesture().onEnded { sendAnimated(.cardTapped) },
        isEnabled: store.editing == nil
      )
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
      .accessibilityActions {
        if store.canReport {
          Button("Report") { store.send(.cardDoubleTapped) }
        }
      }
      .accessibilityIdentifier("study.card")
      // Behind the card text, so the dots never cross it; after the card's identifier, so the ring keeps its own.
      .background { swipeRing }
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
    .contentShape(.rect)
    // While editing, a tap or a downward swipe that starts outside the field drops focus, which ends the edit.
    // Simultaneous, so the scroll view and the field keep their own touches.
    .simultaneousGesture(
      DragGesture(minimumDistance: 0, coordinateSpace: .global).onEnded { drag in
        guard !fieldFrame.contains(drag.startLocation) else { return }
        let isTap = abs(drag.translation.width) < 10 && abs(drag.translation.height) < 10
        if isTap || drag.translation.height > 30 { focusedField = nil }
      },
      isEnabled: store.editing != nil
    )
  }

  /// A sheet sized to its rows: it dims the screen and leaves the centered card visible above it, where a dialog
  /// anchored to the card would pop over the answer. No destructive role: every report is reversible (spec 015).
  private var reportMenu: some View {
    List {
      Section {
        menuItem("Ask about this card", id: "ask") { store.send(.askTapped) }
      }
      Section {
        ForEach(Self.reportReasons, id: \.reason) { reason, title in
          menuItem(title, id: reason.rawValue) { store.send(.reportReasonTapped(reason)) }
        }
      }
    }
    .listSectionSpacing(.compact)
    // 44 pt rows (the minimum tap target), not the taller default, so the sheet stays below the card's answer.
    .environment(\.defaultMinListRowHeight, 44)
    .contentMargins(.top, Theme.Spacing.m, for: .scrollContent)
    .scrollContentBackground(.hidden)
    .scrollBounceBehavior(.basedOnSize)
    .onScrollGeometryChange(for: CGFloat.self, of: \.contentSize.height) { _, height in reportMenuHeight = height }
    .presentationDetents([.height(reportMenuHeight)])
    .presentationBackground(Theme.background)
    .alert("What's wrong?", isPresented: $store.isReportCommentShown) {
      TextField("", text: $store.reportComment)
      Button("Report") { store.send(.reportCommentSubmitted) }
        .disabled(store.reportComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("study.report.send")
      Button("Cancel", role: .cancel) {}
    }
    .task(id: store.isReportCommentShown) {
      if store.isReportCommentShown { await Self.identifyAlertTextField("study.report.comment") }
    }
  }

  private func menuItem(_ title: String, id: String, action: @escaping () -> Void) -> some View {
    Button(title, action: action)
      .font(.body)
      .foregroundStyle(Theme.ink)
      .listRowInsets(EdgeInsets(top: 0, leading: Theme.Spacing.m, bottom: 0, trailing: Theme.Spacing.m))
      .listRowBackground(Rectangle().fill(Theme.surface))
      .accessibilityIdentifier("study.report.\(id)")
  }

  /// The menu's reasons in order; `brokenPhoto` is filed by the app alone, never offered.
  static let reportReasons: [(reason: ReportReason, title: String)] = [
    (.wrong, "This is wrong"),
    (.drop, "I don't want this card"),
    (.doubt, "I doubt this is correct"),
    (.rephrase, "I want it phrased differently"),
    (.other, "Other…"),
  ]

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
        .onSubmit { focusedField = nil }
        .onAppear { focusedField = field }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { fieldFrame = $0 }
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
            name, of: card, side: .front, font: name == firstText ? .cardFace : .body,
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
          field(name, of: card, side: .back, font: .body, color: Theme.secondaryInk)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityActions { ratingActions }
      .accessibilityIdentifier("study.back")
    }
  }

  /// A photo field shows the image at its public URL, never the URL text.
  @ViewBuilder
  private func field(
    _ name: String, of card: Card, side: StudyFeature.State.Field, font: Font, color: ThemeColor
  ) -> some View {
    if name == Card.photoField {
      let url = card.fields[name] ?? ""
      CardPhoto(url: URL(string: url), style: .card) {
        store.send(.photoLoadFailed(cardID: card.id, url: url, side: side))
      }
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

  private func caughtUp(subtitle: String?) -> some View {
    pullable {
      VStack(spacing: Theme.Spacing.s) {
        Text("All caught up")
          .font(.cardFace)
          .foregroundStyle(Theme.ink)
          .accessibilityIdentifier("study.message")
        if let subtitle {
          Text(subtitle)
            .font(.meta)
            .foregroundStyle(Theme.secondaryInk)
            .accessibilityIdentifier("study.nextDue")
        }
      }
      .multilineTextAlignment(.center)
    }
  }

  /// SwiftUI drops `accessibilityIdentifier` on an alert's text field, so it's set on the UIKit field once shown.
  private static func identifyAlertTextField(_ id: String) async {
    for _ in 0..<40 {
      let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
      for window in windows {
        var top = window.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        if let field = (top as? UIAlertController)?.textFields?.first {
          field.accessibilityIdentifier = id
          return
        }
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  static func nextDueText(_ nextDue: Date) -> String {
     "Next card " + nextDue.formatted(.relative(presentation: .numeric))
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
