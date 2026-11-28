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
  /// The card's visible height: a person card centres itself in it, see `studying`.
  @State private var cardHeight: CGFloat = 0
  /// A basic card's question and question + answer heights: a question that would sit high starts centred (017 lift).
  @State private var questionHeight: CGFloat = 0
  @State private var pairHeight: CGFloat = 0
  /// Flashes the scroll indicators on each reveal, never as a card leaves.
  @State private var revealCount = 0
  @State private var reportMenuHeight: CGFloat = 360
  /// Each side's saved text as laid out in the card's column (spec 017): its line count picks the alignment.
  @State private var frontMeasure = TextMeasure()
  @State private var backMeasure = TextMeasure()

  /// Spec 017's candidate layouts for a leading answer under a centred question, until the user picks one: the
  /// full-width column (A), a block as wide as its widest line, centred (B), B moved to the question's left edge when
  /// nearly as wide (C), or kept inside a wide question's width (D). A leading question always uses the column's edge.
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
    .sensoryFeedback(.success, trigger: store.notice) { _, new in new == .reported || new?.isStepDone == true }
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
              .accessibilityIdentifier(notice.isStepDone ? "study.milestoneNotice" : "study.reportNotice")
              .transition(.opacity)
          } else if store.phase == .studying, !store.cards.isEmpty {
            counter
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
    case let .stepDone(step): "\(step) done"
    }
  }

  /// "8 at risk", "22 to review", "6 new": the ladder's current step, else the loaded batch (spec 021).
  private var counterValue: (count: Int, unit: String) {
    store.ladder?.counter ?? (store.cards.count, "to review")
  }

  /// A glass capsule, the peer of the two circles, that opens the ladder.
  private var counter: some View {
    let (count, unit) = counterValue
    return Button {
      store.send(.remainingTapped)
    } label: {
      counterText(Text("\(Text(count, format: .number).foregroundStyle(Theme.accent)) \(unit)"))
        .monospacedDigit()
        .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(count)))
        .animation(Theme.Motion.standard, value: count)
        .padding(.horizontal, Theme.Spacing.m)
        .frame(minHeight: 44)
        .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(), in: .capsule)
    .accessibilityLabel("Milestones")
    .accessibilityValue("\(count) \(unit)")
    .accessibilityIdentifier("study.remaining")
    .popover(isPresented: $store.isMilestonesShown, arrowEdge: .top) {
      MilestonesList(rows: store.ladder?.rows ?? [])
        .presentationCompactAdaptation(.popover)
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

  /// The back and a hidden copy of the rating row are always laid out, so the front never moves on reveal (except a
  /// person card's text prompt, spec 014d, and a basic question that would sit high: it starts centred, spec 017).
  /// The rating row shares the card text's `.accessibility2` cap so it never outgrows the card.
  private func studying(_ card: Card) -> some View {
    let lift = card.type == .person || reduceMotion
      ? 0 : Self.revealLift(card: cardHeight, question: questionHeight, pair: pairHeight)
    return VStack(spacing: Theme.Spacing.m) {
      ScrollViewReader { proxy in
        ScrollView {
          // Without a container, the card's id change as the scroll view's direct content never runs its
          // transition, so the next card popped in.
          ZStack {
            Group {
              if card.type == .person {
                person(card)
              } else {
                VStack(spacing: Theme.Spacing.m) {
                  // A leading question starts at the column's edge, so every paragraph shares one left edge (#16).
                  prompt(card).placed(promptAlignment, asBlock: false)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { questionHeight = $0 }
                  answer(card)
                    .animation(Theme.Motion.standard) { $0.opacity(store.isRevealed ? 1 : 0) }
                    .accessibilityHidden(!store.isRevealed)
                    .placed(answerAlignment, asBlock: answerIsBlock, width: answerWidth)
                    // Layout D: a leading answer's column is the question's widest line as drawn, at that line's place.
                    .frame(
                      width: answerWidth == nil ? nil : frontMeasure.width,
                      alignment: Alignment(horizontal: promptAlignment.horizontal, vertical: .center)
                    )
                    .offset(x: answerSnap)
                }
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { pairHeight = $0 }
                .offset(y: store.isRevealed ? 0 : lift)
              }
            }
            .frame(maxWidth: .infinity)
            .background(alignment: .top) {
              VStack {
                probe(card.promptText, font: card.promptFont, into: $frontMeasure)
                probe(card.answerText, font: answerFont(card), into: $backMeasure)
              }
            }
            // A person card centres itself, not through the scroll view's alignment (kept for basic cards): that one
            // shifted the whole content at once on reveal, so whatever faded out was drawn away from what moved (014d).
            .frame(minHeight: card.type == .person ? cardHeight : nil)
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
        // Every path that reveals a person card's text prompt or lifts a basic card's question moves it in one
        // transaction (Reduce Motion: none, the cross-fade animates its own opacity).
        .transaction(value: store.isRevealed) { transaction in
          guard store.isRevealed, card.isPersonWithTextPrompt || lift > 0 else { return }
          transaction.animation = reduceMotion ? nil : Theme.Motion.reveal
        }
        .onScrollGeometryChange(for: Bool.self, of: { $0.contentSize.height > $0.containerSize.height }) {
          isCardScrollable = $1
        }
        .onScrollGeometryChange(for: CGFloat.self, of: \.containerSize.height) { cardHeight = $1 }
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
        .animation(Theme.Motion.standard) { $0.foregroundStyle(color) }
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

  /// A basic card's sides: one text field each, editable in place (spec 010). Under a leading question the revealed
  /// answer takes the ink and the question recedes (#16).
  private func prompt(_ card: Card) -> some View {
    let recedes = promptAlignment == .leading && store.isRevealed
    return side(.front, text: card.text(.front), font: card.promptFont.font, color: recedes ? Theme.recededInk : Theme.ink)
  }

  private func answer(_ card: Card) -> some View {
    side(.back, text: card.text(.back), font: answerFont(card).font, color: Self.answerColor(question: promptAlignment))
  }

  private func answerFont(_ card: Card) -> CardFont {
    CardText.answerFont(card.answerText, questionLeads: promptAlignment == .leading)
  }

  static func answerColor(question: TextAlignment) -> ThemeColor {
    question == .leading ? Theme.ink : Theme.secondaryInk
  }

  /// The question depends only on itself, so it never moves on reveal.
  private var promptAlignment: TextAlignment { Self.alignment(of: frontMeasure) }

  private var answerAlignment: TextAlignment { Self.answerAlignment(question: promptAlignment, answer: backMeasure) }

  /// One axis per card (#16): a leading question's answer shares its edge whatever its length; under a centred
  /// question the answer aligns on its own lines.
  static func answerAlignment(question: TextAlignment, answer: TextMeasure) -> TextAlignment {
    question == .leading ? .leading : alignment(of: answer)
  }

  static func alignment(of side: TextMeasure) -> TextAlignment {
    side.isMultiline ? .leading : .center
  }

  private var answerIsBlock: Bool {
    switch Self.textLayout {
    case .column: false
    case .blocks, .snappedBlocks: true
    case .questionWidth: answerWidth != nil
    }
  }

  /// Layout D: the width the answer is laid out in, or nil for the column (always under a leading question, #16).
  private var answerWidth: CGFloat? {
    guard Self.textLayout == .questionWidth, promptAlignment == .center else { return nil }
    return Self.referenceWidth(question: frontMeasure, answer: answerAlignment)
  }

  /// Layout D: a question whose widest line as drawn fills at least 85 % of the column reads as a full-width block,
  /// so that line becomes a leading answer's column: a leading answer wider than it would overhang its left edge.
  /// Below 85 %, wrapped or not, the question is display text with wide margins, and a centred answer (1-2 lines in
  /// the full column) is never constrained: both keep the full column (user, 2026-11-22).
  static func referenceWidth(question: TextMeasure, answer: TextAlignment) -> CGFloat? {
    guard answer == .leading, question.drawnWidth > 0, question.drawnWidth >= 0.85 * question.column
    else { return nil }
    return question.drawnWidth
  }

  private var answerSnap: CGFloat {
    guard Self.textLayout == .snappedBlocks, promptAlignment == .leading, answerAlignment == .leading else { return 0 }
    return Self.snap(answer: backMeasure.width, toQuestion: frontMeasure.width, column: cardSize.width)
  }

  /// How far a basic card's question, centred in the card, moves up to its place in the centred pair (or the top, when
  /// the pair overflows). Up to `Spacing.xl` it still reads as centred, so it starts in place: 0 (spec 017 lift).
  static func revealLift(card: CGFloat, question: CGFloat, pair: CGFloat) -> CGFloat {
    let lift = max(0, (card - question) / 2 - max(0, (card - pair) / 2))
    return lift > Theme.Spacing.xl ? lift : 0
  }

  /// Layout C: how far to move a leading answer block so its left edge meets the question's, when the two widths are
  /// within 15 % (an "almost aligned" pair looks like a mistake) and the answer still fits the column.
  static func snap(answer: CGFloat, toQuestion question: CGFloat, column: CGFloat) -> CGFloat {
    let wider = max(answer, question)
    guard wider > 0, abs(answer - question) < 0.15 * wider, 2 * answer - question <= column else { return 0 }
    return (answer - question) / 2
  }

  /// A hidden copy of a side's saved text in the column, cut to two lines, with the full text over it: a full text
  /// taller than the cut one has more lines. Laid out with the card, so it follows the width and text size. One
  /// callback per side: two writes to the same state in one layout pass lost one of them.
  private func probe(
    _ text: String, font cardFont: CardFont, into measure: Binding<TextMeasure>
  ) -> some View {
    let font = cardFont.font
    let textSize = min(dynamicTypeSize, .accessibility2)  // the card text's `dynamicTypeSize` cap
    return Text(text).font(font).lineLimit(2).fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity)
      .overlay(alignment: .top) {
        Text(text).font(font).fixedSize(horizontal: false, vertical: true)
          .onGeometryChange(for: TextMeasure.self) { proxy in
            let twoLines = proxy.bounds(of: .named(Self.twoLines))
            return TextMeasure(
              width: proxy.size.width, height: proxy.size.height,
              twoLines: twoLines?.height ?? proxy.size.height,
              column: twoLines?.width ?? proxy.size.width
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
      .hidden()
      .accessibilityHidden(true)
  }

  nonisolated private static let twoLines = "study.twoLines"

  /// The width a side's edit field keeps (the shown block's): a leading answer block's in B and C, a leading D answer's
  /// column; nil spans the column, as the question always does.
  private func editWidth(_ field: StudyFeature.State.Field) -> CGFloat? {
    guard field == .back else { return nil }
    if Self.textLayout == .questionWidth { return answerWidth }
    guard answerAlignment == .leading, Self.textLayout != .column else { return nil }
    return backMeasure.width
  }

  struct TextMeasure: Equatable {
    /// The widest line's width as SwiftUI measures it: with the space a wrapped line breaks at.
    var width: CGFloat = 0
    /// The widest line's width as drawn, without that space.
    var drawnWidth: CGFloat = 0
    var height: CGFloat = 0
    /// The text's height cut to two lines.
    var twoLines: CGFloat = 0
    /// The width the text was laid out in.
    var column: CGFloat = 0

    /// 3+ lines: the side is leading-aligned.
    var isMultiline: Bool { height > twoLines + 1 }
  }

  /// A person card (spec 014d): photo, name and description end centred as one composition under the photo.
  /// A photo prompt keeps its photo still and cross-fades the hint into the caption below it; a text prompt is
  /// centred with its hint, then moves into its row as the other rows open around it.
  @ViewBuilder private func person(_ card: Card) -> some View {
    let rows = card.personRows
    if card.prompt.contains(Card.photoField) {
      VStack(spacing: Theme.Spacing.m) {
        photo(of: card, side: .front)
          .accessibilityElement(children: .contain)
          .accessibilityActions { ratingActions }
          .accessibilityIdentifier("study.front")
        ZStack(alignment: .top) {
          if let hint = store.answerHint {
            answerHint(hint)
              .opacity(store.isRevealed ? 0 : 1)
              .accessibilityHidden(store.isRevealed)
          }
          VStack(spacing: 0) {
            let captionRows = rows.filter { $0 != Card.photoField }
            ForEach(captionRows, id: \.self) { name in
              personText(name, of: card, revealed: true)
                .padding(.top, Self.gap(before: name, in: captionRows))
            }
          }
          .frame(maxWidth: .infinity)
          .accessibilityElement(children: .contain)
          .accessibilityActions { ratingActions }
          .accessibilityIdentifier("study.back")
          .opacity(store.isRevealed ? 1 : 0)
          .accessibilityHidden(!store.isRevealed)
        }
      }
    } else if reduceMotion {
      // No move, no morph: both are laid out in place and only their opacity changes.
      CrossFadeStack(showsSecond: store.isRevealed) {
        personQuestion(card, rows: rows, revealed: false, hidden: store.isRevealed)
          .animation(Theme.Motion.standard) { $0.opacity(store.isRevealed ? 0 : 1) }
          .allowsHitTesting(!store.isRevealed)
        personQuestion(card, rows: rows, revealed: true, hidden: !store.isRevealed)
          .animation(Theme.Motion.standard) { $0.opacity(store.isRevealed ? 1 : 0) }
          .allowsHitTesting(store.isRevealed)
      }
    } else {
      personQuestion(card, rows: rows, revealed: store.isRevealed)
    }
  }

  /// A text prompt and its hint before reveal; after it, the prompt in its row among the inserted ones. One `ForEach`
  /// keyed by field name, so the prompt keeps its identity and moves. `hidden` (a Reduce Motion layer not shown) is
  /// applied to each element, never to the layer: an outer `accessibilityHidden(false)` un-hid the hidden style and hint.
  private func personQuestion(_ card: Card, rows: [String], revealed: Bool, hidden: Bool = false) -> some View {
    let shown = revealed ? rows : rows.filter(card.prompt.contains)
    let promptIsName = card.prompt.contains(Card.nameField)
    return VStack(spacing: 0) {
      ForEach(shown, id: \.self) { name in
        let isPrompt = card.prompt.contains(name)
        Group {
          if name == Card.photoField {
            photo(of: card, side: .back)
              .accessibilityActions { ratingActions }
              .accessibilityHidden(hidden)
          } else if isPrompt {
            personPrompt(name, of: card, revealed: revealed, hidden: hidden)
          } else {
            personText(name, of: card, revealed: revealed)
              .accessibilityActions { ratingActions }
              .accessibilityIdentifier("study.back")
              .accessibilityHidden(hidden)
          }
        }
        .padding(.top, Self.gap(before: name, in: shown))
        // Not tokens: new rows fade in once the prompt has moved past them, so nothing overlaps it. A description
        // travels further, under the name's row.
        .transition(isPrompt ? .identity : .opacity.animation(.easeOut(duration: 0.2).delay(promptIsName ? 0.2 : 0.3)))
      }
    }
  }

  /// A text prompt's row, its hint under it before reveal. The hint stays in the row and folds to no height as it
  /// fades: removed, it faded where it was while the prompt moved across it.
  private func personPrompt(_ name: String, of card: Card, revealed: Bool, hidden: Bool) -> some View {
    VStack(spacing: 0) {
      Group {
        if name == Card.nameField {
          personText(name, of: card, revealed: revealed)
            .accessibilityHidden(hidden)
        } else {
          // A description re-wraps and changes colour: its two styles cross-fade on one moving frame. A `Text` with
          // `.contentTransition(.opacity)` drew the old style at its old place, a copy left behind.
          CrossFadeStack(showsSecond: revealed) {
            // In sequence, never two legible copies: the caption starts once the prompt style is almost gone. Both
            // done before the rows above fade in (0.3 s delay): the larger prompt style reaches into the name's row.
            personText(name, of: card, revealed: false)
              .animation(.easeOut(duration: 0.1)) { $0.opacity(revealed ? 0 : 1) }
              .accessibilityHidden(revealed || hidden)
            personText(name, of: card, revealed: true)
              .animation(.easeIn(duration: 0.15).delay(0.08)) { $0.opacity(revealed ? 1 : 0) }
              .accessibilityHidden(!revealed || hidden)
          }
        }
      }
      .accessibilityActions { ratingActions }
      .accessibilityIdentifier("study.front")
      if let hint = store.answerHint {
        answerHint(hint)
          .padding(.top, Theme.Spacing.m)
          // Gone before the prompt reaches it (0.15 s ease-in still showed under the moving name).
          .animation(.easeOut(duration: 0.1)) { $0.opacity(revealed ? 0 : 1) }
          .frame(height: revealed ? 0 : nil, alignment: .top)
          .allowsHitTesting(!revealed)
          .accessibilityHidden(revealed || hidden)
      }
    }
  }

  /// One text row: a prompt's style before reveal, the composition's after it. The name morphs its font (one line).
  private func personText(_ name: String, of card: Card, revealed: Bool) -> some View {
    let isQuestion = !revealed && card.prompt.contains(name)
    let isName = name == Card.nameField
    let alignment: TextAlignment = isQuestion ? promptAlignment : .center
    let fills = !isQuestion || promptAlignment == .center || Self.textLayout == .column
    return Text(card.fields[name] ?? "")
      .font(isQuestion ? card.promptFont.font : isName ? .cardFaceSmall : .body)
      .foregroundStyle(isQuestion || isName ? Theme.ink : Theme.secondaryInk)
      .contentTransition(isName ? .interpolate : .identity)
      .multilineTextAlignment(alignment)
      .frame(maxWidth: fills ? .infinity : nil, alignment: Alignment(horizontal: alignment.horizontal, vertical: .center))
      .frame(maxWidth: isQuestion ? nil : captionWidth)
  }

  /// What a person card asks to recall, centred under the prompt.
  private func answerHint(_ hint: String) -> some View {
    Text(hint)
      .font(.subheadline)
      .foregroundStyle(Theme.secondaryInk)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
      .accessibilityIdentifier("study.answerHint")
  }

  /// A row's space above it in a person card: none first, `m` under the photo, `s` between name and description.
  static func gap(before name: String, in rows: [String]) -> CGFloat {
    guard let index = rows.firstIndex(of: name), index > 0 else { return 0 }
    return rows[index - 1] == Card.photoField ? Theme.Spacing.m : Theme.Spacing.s
  }

  /// Name and description share one centred measure under the photo, not a full-width paragraph.
  private var captionWidth: CGFloat {
    Self.captionWidth(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
  }

  /// The photo's width plus `l` on each side; the frame keeps it within the column.
  static func captionWidth(isAccessibilitySize: Bool) -> CGFloat {
    (isAccessibilitySize ? Theme.Photo.cardCompact : Theme.Photo.card) + 2 * Theme.Spacing.l
  }

  /// The photo at its public URL, centred; a failed load is reported for its side (spec 014d).
  private func photo(of card: Card, side: StudyFeature.State.Field) -> some View {
    let url = card.fields[Card.photoField] ?? ""
    return CardPhoto(url: URL(string: url), style: .card) {
      store.send(.photoLoadFailed(cardID: card.id, url: url, side: side))
    }
    .accessibilityIdentifier("study.photo")
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
        LaCarteLaunchMark()
          .frame(width: 64, height: 64)
          .padding(.bottom, Theme.Spacing.m)
          .accessibilityIdentifier("study.logo")
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

  /// A person card's fields as revealed (spec 014d): photo, name, description, the empty ones left out.
  var personRows: [String] {
    shown(type.fields).filter { prompt.contains($0) || answer.contains($0) }
  }

  /// The person cards whose question moves on reveal (spec 014d); a photo prompt stays put.
  var isPersonWithTextPrompt: Bool {
    type == .person && !prompt.contains(Card.photoField)
  }

  var promptFont: CardFont { CardText.promptFont(promptText) }
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

/// The milestones popover: the ladder's rows only, no title, no buttons, no sentences (spec 021).
struct MilestonesList: View {
  let rows: [Ladder.Row]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.m) {
        ForEach(rows) { row($0) }
      }
      .padding(Theme.Spacing.m)
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(idealWidth: 220)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityIdentifier("study.milestones")
  }

  @ViewBuilder private func row(_ row: Ladder.Row) -> some View {
    if row.isDone {
      HStack {
        Text(row.label)
        Spacer()
        Image(systemName: "checkmark")
          .fontWeight(.medium)
      }
      .font(.body)
      .foregroundStyle(Theme.secondaryInk)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(row.label), done")
      .accessibilityIdentifier("study.milestone.\(row.kind.rawValue)")
    } else {
      VStack(alignment: .leading, spacing: Theme.Spacing.s) {
        HStack {
          Text(row.label)
            .foregroundStyle(Theme.ink)
          Spacer()
          Text("\(row.done)/\(row.total)")
            .foregroundStyle(Theme.secondaryInk)
            .monospacedDigit()
        }
        .font(.body)
        ProgressView(value: Double(row.done), total: Double(row.total))
          .tint(Theme.ink)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(row.label), \(row.done) of \(row.total)")
      .accessibilityIdentifier("study.milestone.\(row.kind.rawValue)")
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

/// Lays its two subviews over each other, centred, sized by the one shown: a cross-fade between two layouts where
/// neither is re-laid out or left behind (spec 014d).
private struct CrossFadeStack: Layout {
  var showsSecond: Bool

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    subviews[showsSecond ? 1 : 0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
  }

  /// Each at the width offered to the stack, not the shown one's: a fading prompt style keeps its wrapping.
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for subview in subviews {
      subview.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(width: proposal.width, height: nil))
    }
  }
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

#Preview("Milestones") {
  let stats = DeckStats(
    total: 120, due: 64, new: 40, reviewedToday: 52, nextDue: nil, newToday: 9, dueNew: 40, atRiskTotal: 14,
    atRiskDone: 14, reviewsTotal: 52, reviewsDone: 52
  )
  var state = StudyFeature.State()
  state.cards = IdentifiedArray(uniqueElements: [Card].fixtures)
  state.phase = .studying
  state.ladder = Ladder(stats: stats)
  state.isMilestonesShown = true
  return StudyView(store: Store(initialState: state) { StudyFeature() })
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
