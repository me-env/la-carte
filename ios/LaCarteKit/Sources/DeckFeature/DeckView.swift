import APIClient
import CardEditorFeature
import ComposableArchitecture
import DesignSystem
import SettingsFeature
import SwiftUI

public struct DeckView: View {
  @Bindable var store: StoreOf<DeckFeature>
  @Environment(\.scenePhase) private var scenePhase

  public init(store: StoreOf<DeckFeature>) {
    self.store = store
  }

  public var body: some View {
    VStack(spacing: Theme.Spacing.m) {
      Group {
        header
        searchField
      }
      // Not on the list: the swipe action keeps the system's destructive red.
      .tint(Theme.ink)
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refreshable { await store.send(.pulledToRefresh).finish() }
    }
    .padding(.top, Theme.Spacing.l)
    .background(Theme.background)
    .onAppear { store.send(.onAppear) }
    .onChange(of: scenePhase) { _, phase in store.send(.scenePhaseChanged(phase)) }
    .sheet(item: $store.scope(\.$destination, action: \.destination).editor) { editorStore in
      CardEditorView(store: editorStore)
    }
    .sheet(item: $store.scope(\.$destination, action: \.destination).settings) { settingsStore in
      SettingsView(store: settingsStore)
    }
  }

  private var header: some View {
    HStack(spacing: Theme.Spacing.s) {
      Text("Cards")
        .font(.screenTitle)
        .foregroundStyle(Theme.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("deck.title")
      CircleIconButton("gearshape", accessibilityLabel: "Settings") {
        store.send(.settingsButtonTapped)
      }
      .accessibilityIdentifier("deck.settings")
      CircleIconButton("plus", accessibilityLabel: "Add card") {
        store.send(.addButtonTapped)
      }
      .accessibilityIdentifier("deck.add")
    }
    .padding(.horizontal, Theme.Spacing.m)
  }

  private var searchField: some View {
    HStack(spacing: Theme.Spacing.s) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(Theme.secondaryInk)
        .accessibilityHidden(true)
      TextField("Search", text: $store.query, prompt: Text("Search").foregroundStyle(Theme.secondaryInk))
        .font(.body)
        .foregroundStyle(Theme.ink)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.search)
        .accessibilityIdentifier("deck.search")
    }
    .padding(.horizontal, Theme.Spacing.m)
    .padding(.vertical, Theme.Spacing.s)
    .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.row))
    .padding(.horizontal, Theme.Spacing.m)
  }

  @ViewBuilder private var content: some View {
    if let message = store.message {
      // In a scroll view so the message can be pulled to refresh.
      ScrollView {
        Text(message)
          .font(.body)
          .foregroundStyle(Theme.secondaryInk)
          .multilineTextAlignment(.center)
          .padding(.horizontal, Theme.Spacing.m)
          .accessibilityIdentifier("deck.message")
          .containerRelativeFrame([.horizontal, .vertical])
      }
      .scrollDismissesKeyboard(.immediately)
    } else {
      List {
        ForEach(store.cards) { card in
          row(card)
            .listRowInsets(
              EdgeInsets(
                top: Theme.Spacing.s / 2, leading: Theme.Spacing.m,
                bottom: Theme.Spacing.s / 2, trailing: Theme.Spacing.m
              )
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Rectangle().fill(Theme.background))
            .swipeActions(edge: .trailing) {
              Button("Delete", role: .destructive) {
                withAnimation(.easeInOut(duration: 0.25)) {
                  _ = store.send(.rowSwipedToDelete(card.id))
                }
              }
              .accessibilityIdentifier("deck.row.\(card.id).delete")
            }
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .scrollDismissesKeyboard(.immediately)
    }
  }

  private func row(_ card: Card) -> some View {
    Button {
      store.send(.rowTapped(card.id))
    } label: {
      VStack(alignment: .leading, spacing: Theme.Spacing.s / 2) {
        HStack(spacing: Theme.Spacing.s) {
          Text(Self.dueText(card.due))
            .accessibilityIdentifier("deck.row.\(card.id).due")
          Spacer(minLength: 0)
          Text(card.state.rawValue)
            .accessibilityIdentifier("deck.row.\(card.id).state")
        }
        .font(.meta)
        .foregroundStyle(Theme.secondaryInk)
        Text(card.front)
          .foregroundStyle(Theme.ink)
        Text(card.back)
          .foregroundStyle(Theme.secondaryInk)
      }
      .font(.body)
      .lineLimit(1)
      .padding(Theme.Spacing.m)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.row))
    }
    .buttonStyle(.plain)
    // `.contain` keeps the due/state texts queryable by UI tests inside the tappable row.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("deck.row.\(card.id)")
  }

  static func dueText(_ due: Date, now: Date = .now, locale: Locale = .current) -> String {
    guard due > now else { return "Due now" }
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .numeric
    formatter.locale = locale
    return "Due " + formatter.localizedString(for: due, relativeTo: now)
  }
}

#Preview("Deck") {
  DeckView(store: Store(initialState: DeckFeature.State()) { DeckFeature() })
}

#Preview("Empty deck") {
  DeckView(store: Store(initialState: DeckFeature.State()) { DeckFeature() } withDependencies: {
    $0.apiClient = .inMemory(cards: [])
  })
}
