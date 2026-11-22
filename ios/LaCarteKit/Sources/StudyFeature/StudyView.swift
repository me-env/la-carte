import APIClient
import ComposableArchitecture
import DesignSystem
import SwiftUI

public struct StudyView: View {
  @Bindable var store: StoreOf<StudyFeature>
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @FocusState private var focusedField: StudyFeature.State.Field?
  /// Where the rating drag came down, in the card's coordinates: the dial's center. Visual only.
  @State private var touchDown: CGPoint?
  /// A positive release's reward, playing over the next card (spec 019 §6). The rating is already sent: this never
  /// delays the next card, takes no touches, and a new drag cancels it. Visual only.
  @State private var reward: Reward?
  @State private var cardSize = CGSize.zero
  /// A long card scrolls, so a vertical first movement is left to the scroll view (spec 019).
  @State private var isCardScrollable = false
  /// Flashes the scroll indicators on each reveal, never as a card leaves.
  @State private var revealCount = 0
  @State private var reportMenuHeight: CGFloat = 360
  /// Each side's saved text as laid out in the card's column (spec 017): its line count picks the alignment.
  @State private var frontMeasure = TextMeasure()
  @State private var backMeasure = TextMeasure()

  /// Spec 017's candidate layouts for text of 3+ lines, until the user picks one: the leading full-width column (A),
  /// a leading block as wide as its widest line, centred (B), B with an answer of nearly the question's width
  /// moved to the question's left edge (C), or B with the answer kept inside a wide question's width (D).
  enum TextLayout: CaseIterable { case column, blocks, snappedBlocks, questionWidth }
  static var textLayout = TextLayout.questionWidth

  public init(store: StoreOf<StudyFeature>) {
    self.store = store
  }

  public var body: some View {
    // One top bar for every phase; only the content below it changes.
    VStack(spacing: Theme.Spacing.m) {
      topBar
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // No pull-to-refresh (spec 018): content that fits doesn't move under a drag.
        .scrollBounceBehavior(.basedOnSize)
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
      centeredMessage { Color.clear }

    case .studying:
      if let card = store.cards.first {
        studying(card)
      }

    case let .caughtUp(nextDue):
      caughtUp(subtitle: nextDue.map(Self.nextDueText))

    case .empty:
      centeredMessage {
        VStack(spacing: Theme.Spacing.s) {
          message("No cards yet")
          detail("Ask your agent to add some")
        }
      }

    case .offline:
      centeredMessage {
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
    centeredMessage {
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

  /// A scroll view the size of the content area, so a centered message can still scroll at large text sizes.
  /// Width comes from the proposal, not `containerRelativeFrame(.horizontal)`: that one resolved to the full
  /// window width, which the vertical scroll view adopted, pushing the top bar past its margins.
  private func centeredMessage(@ViewBuilder _ message: () -> some View) -> some View {
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
          // Without a container, the card's id change as the scroll view's direct content never runs its
          // transition, so the next card popped in.
          ZStack {
            VStack(spacing: Theme.Spacing.m) {
              prompt(card).placed(promptAlignment, asBlock: Self.textLayout != .column)
              answerSlot(card)
                .placed(answerAlignment, asBlock: answerIsBlock, width: answerWidth)
                // Layout D: the answer's column is the question's widest line as drawn, at that line's place.
                .frame(
                  width: answerWidth == nil ? nil : frontMeasure.width,
                  alignment: Alignment(horizontal: promptAlignment.horizontal, vertical: .center)
                )
                .offset(x: answerSnap)
            }
            .frame(maxWidth: .infinity)
            .background(alignment: .top) {
              VStack {
                probe(card.promptText, font: card.promptFont, into: $frontMeasure)
                probe(card.answerText, font: card.answerFont, width: answerWidth, into: $backMeasure)
              }
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            // Fades under the dial while a drag is held; animated only as the drag starts and ends.
            .opacity(store.cardTextOpacity)
            .animation(Theme.Motion.standard, value: store.swipeEase == nil)
            // The next card fades in from the top; the outgoing one leaves at once so its answer never lingers.
            // The animation rides on the transition alone, so the scroll view's size and offset don't glide.
            .id(card.id)
            .transition(
              .asymmetric(insertion: AnyTransition.opacity.animation(Theme.Motion.standard), removal: .identity)
            )
          }
        }
        .onChange(of: card.id) { _, id in proxy.scrollTo(id, anchor: .top) }
        .onScrollGeometryChange(for: Bool.self, of: { $0.contentSize.height > $0.containerSize.height }) {
          isCardScrollable = $1
        }
        .defaultScrollAnchor(.center, for: .alignment)
        // On reveal only: flashing on `isRevealed` also fired as the next card came in, where the hidden answer laid
        // out below a short question often overflows, so a card that visibly fits showed a scroll bar.
        .scrollIndicatorsFlash(trigger: revealCount)
        .onChange(of: store.isRevealed) { _, revealed in
          if revealed { revealCount += 1 }
        }
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
        RatingPan(isEnabled: store.canRate, isScrollable: isCardScrollable) { start, translation in
          touchDown = start
          reward = nil
          store.send(.swipeChanged(fraction: swipeFraction(translation)))
        } onEnd: { translation in
          let fraction = swipeFraction(translation)
          let ease = StudyFeature.ease(forSwipe: fraction)
          reward = store.canRate ? RatingDial.Release(value: ease).map { Reward(ease: ease, release: $0) } : nil
          store.send(.swipeEnded(fraction: fraction))
        }
      )
      .onGeometryChange(for: CGSize.self, of: \.size) { cardSize = $0 }
      .accessibilityActions {
        if store.canReport {
          Button("Report") { store.send(.cardDoubleTapped) }
        }
      }
      .accessibilityIdentifier("study.card")
      // Above the faded card text; after the card's identifier, so the dial keeps its own.
      .overlay { swipeRing }
      #if DEBUG
        .onChange(of: store.canRate, initial: true) { _, canRate in
          guard canRate, let translation = Self.swipePreview else { return }
          touchDown = nil
          // The preview's translation is already in card widths.
          store.send(.swipeChanged(fraction: StudyFeature.swipeFraction(translation: translation, cardWidth: 1)))
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
    // While editing, a tap or a downward swipe that starts off the field drops focus, which ends the edit.
    .gesture(TapAway(isEnabled: store.editing != nil) { focusedField = nil })
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
      // The draft as text sizes the slot and the field draws over it from the same first baseline: a multi-line
      // field is ~2 pt taller than its text (TextKit pads below the last line), which moved the answer below.
      Text(store.draft.isEmpty ? " " : store.draft)
        .font(font)
        // A leading block keeps the saved text's width, so it doesn't move as the user types.
        .frame(minWidth: editWidth(field), maxWidth: editWidth(field) ?? .infinity)
        .hidden()
        .overlay(alignment: .top) {
          TextField("", text: $store.draft.sending(\.draftChanged), axis: .vertical)
            .font(font)
            .foregroundStyle(color)
            .textFieldStyle(.plain)
            .submitLabel(.done)
            .tint(Theme.accent)
            .focused($focusedField, equals: field)
            .onSubmit { focusedField = nil }
            .onAppear { focusedField = field }
            .id(field)
            .accessibilityLabel(field == .front ? "Front" : "Back")
            .accessibilityIdentifier("study.\(name)Field")
        }
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
      side(.front, text: card.text(.front), font: card.promptFont.font, color: Theme.ink)
    } else {
      let firstText = card.firstPromptText
      VStack(alignment: promptAlignment.horizontal, spacing: Theme.Spacing.s) {
        ForEach(card.shown(card.prompt), id: \.self) { name in
          field(
            name, of: card, side: .front, font: name == firstText ? card.promptFont.font : .body,
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
    ZStack(alignment: Alignment(horizontal: answerAlignment.horizontal, vertical: .center)) {
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
      side(.back, text: card.text(.back), font: card.answerFont.font, color: Theme.secondaryInk)
    } else {
      VStack(alignment: answerAlignment.horizontal, spacing: Theme.Spacing.xs) {
        ForEach(card.shown(card.answer), id: \.self) { name in
          field(name, of: card, side: .back, font: card.answerFont.font, color: Theme.secondaryInk)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityActions { ratingActions }
      .accessibilityIdentifier("study.back")
    }
  }

  /// The question depends only on itself, so it never moves on reveal.
  private var promptAlignment: TextAlignment {
    frontMeasure.isMultiline ? .leading : .center
  }

  /// Under a leading question the answer is leading too; otherwise it follows its own line count.
  private var answerAlignment: TextAlignment {
    promptAlignment == .leading || backMeasure.isMultiline ? .leading : .center
  }

  private var answerIsBlock: Bool {
    switch Self.textLayout {
    case .column: false
    case .blocks, .snappedBlocks: true
    case .questionWidth: answerWidth != nil
    }
  }

  /// Layout D: the width the answer is laid out in, or nil for the column.
  private var answerWidth: CGFloat? {
    Self.textLayout == .questionWidth ? Self.referenceWidth(question: frontMeasure) : nil
  }

  /// Layout D: a question that wraps, or fills at least 85 % of the column on one line, reads as a full-width block,
  /// so its widest line as drawn becomes the answer's column: an answer wider than it would overhang it. Below 85 %
  /// the question is short display text, its side margins are wide, and the answer keeps the full column.
  static func referenceWidth(question: TextMeasure) -> CGFloat? {
    guard question.width > 0, question.wraps || question.width >= 0.85 * question.column else { return nil }
    return question.drawnWidth
  }

  private var answerSnap: CGFloat {
    guard Self.textLayout == .snappedBlocks, promptAlignment == .leading else { return 0 }
    return Self.snap(answer: backMeasure.width, toQuestion: frontMeasure.width, column: cardSize.width)
  }

  /// Layout C: how far to move a leading answer block so its left edge meets the question's, when the two widths are
  /// within 15 % (an "almost aligned" pair looks like a mistake) and the answer still fits the column.
  static func snap(answer: CGFloat, toQuestion question: CGFloat, column: CGFloat) -> CGFloat {
    let wider = max(answer, question)
    guard wider > 0, abs(answer - question) < 0.15 * wider, 2 * answer - question <= column else { return 0 }
    return (answer - question) / 2
  }

  /// A hidden copy of a side's saved text in the column (or `width`), cut to one line, then to two, with the full
  /// text over them: a full text taller than a cut one has more lines. Laid out with the card, so it follows the
  /// width and text size. One callback per side: two writes to the same state in one layout pass lost one of them.
  private func probe(
    _ text: String, font cardFont: CardFont, width: CGFloat? = nil, into measure: Binding<TextMeasure>
  ) -> some View {
    let font = cardFont.font
    let textSize = min(dynamicTypeSize, .accessibility2)  // the card text's `dynamicTypeSize` cap
    return Text(text).font(font).lineLimit(1)
      .frame(maxWidth: width ?? .infinity)
      .overlay(alignment: .top) {
        Text(text).font(font).lineLimit(2).fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity)
          .overlay(alignment: .top) {
            Text(text).font(font).fixedSize(horizontal: false, vertical: true)
              .onGeometryChange(for: TextMeasure.self) { proxy in
                let oneLine = proxy.bounds(of: .named(Self.oneLine))
                return TextMeasure(
                  width: proxy.size.width, height: proxy.size.height,
                  oneLine: oneLine?.height ?? proxy.size.height,
                  twoLines: proxy.bounds(of: .named(Self.twoLines))?.height ?? proxy.size.height,
                  column: oneLine?.width ?? proxy.size.width
                )
              } action: { measured in
                var measured = measured
                let drawn = Self.drawnWidth(of: text, font: cardFont.uiFont(textSize), in: measured.column)
                measured.drawnWidth = min(drawn, measured.width)
                measure.wrappedValue = measured
              }
          }
          // After the overlay, which doesn't change the size: the space is the cut text's, the full text inside it.
          .coordinateSpace(.named(Self.twoLines))
      }
      .coordinateSpace(.named(Self.oneLine))
      .hidden()
      .accessibilityHidden(true)
  }

  nonisolated private static let oneLine = "study.oneLine"
  nonisolated private static let twoLines = "study.twoLines"

  /// The width a side's edit field keeps (the shown block's): a leading block's in B, C and D, a D answer's column;
  /// nil spans the column.
  private func editWidth(_ field: StudyFeature.State.Field) -> CGFloat? {
    if field == .back, Self.textLayout == .questionWidth { return answerWidth }
    let alignment = field == .front ? promptAlignment : answerAlignment
    guard alignment == .leading, Self.textLayout != .column else { return nil }
    return (field == .front ? frontMeasure : backMeasure).width
  }

  struct TextMeasure: Equatable {
    /// The widest line's width as SwiftUI measures it: with the space a wrapped line breaks at.
    var width: CGFloat = 0
    /// The widest line's width as drawn, without that space.
    var drawnWidth: CGFloat = 0
    var height: CGFloat = 0
    /// The text's height cut to one line, and to two.
    var oneLine: CGFloat = 0
    var twoLines: CGFloat = 0
    /// The width the text was laid out in.
    var column: CGFloat = 0

    var wraps: Bool { height > oneLine + 1 }
    /// 3+ lines: the side is leading-aligned.
    var isMultiline: Bool { height > twoLines + 1 }
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
      // A photo stays centred even among leading text.
      .frame(maxWidth: (side == .front ? promptAlignment : answerAlignment) == .leading ? .infinity : nil)
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

  /// A tap still sends `again` / `good`; only the label follows the drag (spec 019).
  private func ratingButton(_ rating: Rating) -> some View {
    Button { store.send(.ratingTapped(rating)) } label: { ratingLabel(rating) }
      .buttonStyle(.plain)
      .accessibilityLabel(Self.title(shownRating(rating)))
      .accessibilityIdentifier("study.rate.\(rating.rawValue)")
  }

  /// The button on the drag's side echoes its grade (semibold once armed); the other side turns secondary.
  /// Every title a side can show is laid out hidden, so the buttons never move as the label changes.
  private func ratingLabel(_ rating: Rating) -> some View {
    let echo = store.rowEcho
    let isEchoed = echo.map { Self.isLeft($0.rating) == Self.isLeft(rating) } ?? false
    return ZStack {
      ForEach(Self.isLeft(rating) ? [Rating.again, .hard] : [.good, .easy], id: \.self) { title in
        Text(Self.title(title)).font(.body).fontWeight(.semibold).hidden()
      }
      Text(Self.title(shownRating(rating)))
        .font(.body)
        .fontWeight(isEchoed && echo?.isArmed == true ? .semibold : .regular)
        .foregroundStyle(echo == nil || isEchoed ? Theme.ink : Theme.secondaryInk)
        .contentTransition(.opacity)
    }
    .frame(minHeight: 44)
    .contentShape(.rect)
    .animation(Theme.Motion.standard, value: echo)
  }

  /// What the `again` or `good` button reads now: the echoed grade on the drag's side, else its own title.
  private func shownRating(_ rating: Rating) -> Rating {
    guard let echo = store.rowEcho, Self.isLeft(echo.rating) == Self.isLeft(rating) else { return rating }
    return echo.rating
  }

  private static func isLeft(_ rating: Rating) -> Bool {
    rating == .again || rating == .hard
  }

  static func title(_ rating: Rating) -> String {
    switch rating {
    case .again: "Forgot"
    case .hard: "Hard"
    case .good: "Got it"
    case .easy: "Easy"
    }
  }

  struct Reward: Equatable {
    var ease: Double
    var release: RatingDial.Release
  }

  /// The dial around the touch-down point while a drag is held, 16 pt outside the drag's full length so the finger
  /// stays inside it. Released on Got it / Easy it stays for its reward (`RatingDial`), then goes at once; on
  /// Hard / Forgot it fades shrinking a little (0.94), neutral; cancelled it shrinks to 0.6 toward the touch point.
  /// The transition is the one set in the last frame it was shown. Reduce Motion: fades.
  private var swipeRing: some View {
    let center = touchDown ?? CGPoint(x: cardSize.width / 2, y: cardSize.height / 2)
    let anchor = UnitPoint(
      x: cardSize.width > 0 ? center.x / cardSize.width : 0.5,
      y: cardSize.height > 0 ? center.y / cardSize.height : 0.5
    )
    return ZStack {
      if let ease = store.swipeEase ?? reward?.ease {
        let rewarding = store.swipeEase == nil
        RatingDial(
          value: ease, radius: StudyFeature.ringRadius * cardSize.width + 16, release: rewarding ? reward?.release : nil
        )
        .accessibilityHidden(true)
        // A separate element, inserted only while held: toggling `accessibilityHidden` on a live element left the
        // reward in the tree.
        .overlay {
          if !rewarding {
            Color.clear
              .accessibilityElement()
              .accessibilityLabel("Rating")
              .accessibilityValue(store.swipeRating.map(Self.title) ?? "None")
              .accessibilityIdentifier("study.swipeRing")
              .transition(.identity)
          }
        }
        .position(center)
        .transition(
          rewarding
            ? .identity
            : reduceMotion
              ? .opacity
              : .opacity.combined(with: .scale(scale: store.swipeRating == nil ? 0.6 : 0.94, anchor: anchor))
        )
      }
    }
    .task(id: reward) {
      guard let reward else { return }
      try? await Task.sleep(for: .seconds(reward.release.duration(reduceMotion: reduceMotion)))
      self.reward = nil
    }
    .allowsHitTesting(false)
    .animation(Theme.Motion.standard, value: store.swipeEase == nil)
  }

  private func swipeFraction(_ translation: CGSize) -> Double {
    StudyFeature.swipeFraction(translation: translation, cardWidth: cardSize.width)
  }

  #if DEBUG
    /// `-studySwipePreview <f>` holds a drag of `(f, 0)` card widths, `-studySwipePreviewUp <f>` one of `(0, −f)`,
    /// so QA can screenshot the dial (specs 011, 019). A negative value must be written `"<real>-0.13</real>"`
    /// (or `" -0.13"`): a bare `-0.13` reads as a flag.
    static let swipePreview: CGSize? = {
      let defaults = UserDefaults.standard
      if defaults.object(forKey: "studySwipePreviewUp") != nil {
        return CGSize(width: 0, height: -defaults.double(forKey: "studySwipePreviewUp"))
      }
      if defaults.object(forKey: "studySwipePreview") != nil {
        return CGSize(width: defaults.double(forKey: "studySwipePreview"), height: 0)
      }
      return nil
    }()
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
    centeredMessage {
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

/// The text the card's size and alignment are measured from (spec 017), always the saved fields, never a draft.
extension Card {
  /// The card face: the prompt's first text field (spec 014d). The other prompt fields follow it.
  var firstPromptText: String? {
    shown(prompt).first { $0 != Card.photoField }
  }

  var promptText: String {
    firstPromptText.flatMap { fields[$0] } ?? ""
  }

  /// All the answer's shown text fields, each trimmed, joined by a space.
  var answerText: String {
    shown(answer).filter { $0 != Card.photoField }
      .compactMap { fields[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .joined(separator: " ")
  }

  var promptFont: CardFont { CardText.promptFont(promptText) }
  var answerFont: CardFont { CardText.answerFont(answerText, prompt: promptText) }
}

extension TextAlignment {
  fileprivate var horizontal: HorizontalAlignment {
    switch self {
    case .leading: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }
}

extension View {
  /// Centred text fills the column; leading text fills it too, or is a block centred on its widest line. A given
  /// `width` is the side's own column (layout D's answer), centred.
  fileprivate func placed(_ alignment: TextAlignment, asBlock: Bool, width: CGFloat? = nil) -> some View {
    let isBlock = alignment == .leading && asBlock
    let frameAlignment = Alignment(horizontal: alignment.horizontal, vertical: .center)
    return multilineTextAlignment(alignment)
      .frame(width: width, alignment: frameAlignment)
      .frame(maxWidth: isBlock ? nil : .infinity, alignment: frameAlignment)
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

#Preview("Card lengths") {
  StudyView(store: Store(initialState: StudyFeature.State()) { StudyFeature() } withDependencies: {
    $0.apiClient = .inMemory(cards: .lengthFixtures)
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
