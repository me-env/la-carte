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
    NavigationStack {
      content
        // Rows, menus and swipe-delete keep the system tint; the pink below is for the search field only.
        .tint(Color?.none)
        .background(Theme.background)
        .refreshable { await store.send(.pulledToRefresh).finish() }
        .navigationTitle("Cards")
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            Button("Settings", systemImage: "gearshape") { store.send(.settingsButtonTapped) }
              .tint(Theme.ink)
              .accessibilityIdentifier("deck.settings")
          }
          ToolbarItem(placement: .primaryAction) {
            Button("Add card", systemImage: "plus") { store.send(.addButtonTapped) }
              .tint(Theme.ink)
              .accessibilityIdentifier("deck.add")
          }
        }
        .searchable(text: $store.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .tint(Theme.accent)
    }
    .sensoryFeedback(.impact(weight: .light), trigger: store.deletions)
    .sensoryFeedback(.error, trigger: store.phase) { _, new in new == .offline || new == .unauthorized }
    .onAppear { store.send(.onAppear) }
    .onChange(of: scenePhase) { _, phase in store.send(.scenePhaseChanged(phase)) }
    .sheet(item: $store.scope(\.$destination, action: \.destination).editor) { editorStore in
      CardEditorView(store: editorStore)
    }
    .sheet(item: $store.scope(\.$destination, action: \.destination).settings) { settingsStore in
      SettingsView(store: settingsStore)
    }
  }

  @ViewBuilder private var content: some View {
    if let message = store.message {
      // In a scroll view so the message can be pulled to refresh.
      ScrollView {
        Group {
          if message == .noMatches {
            ContentUnavailableView.search(text: store.query)
          } else {
            unavailable(message)
          }
        }
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
              Button("Delete", role: .destructive) { delete(card) }
                .accessibilityIdentifier("deck.row.\(card.id).delete")
            }
            .contextMenu {
              Button("Edit", systemImage: "pencil") { store.send(.rowTapped(card.id)) }
                .accessibilityIdentifier("deck.row.\(card.id).edit")
              Button("Delete", systemImage: "trash", role: .destructive) { delete(card) }
                .accessibilityIdentifier("deck.row.\(card.id).contextDelete")
            }
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .scrollDismissesKeyboard(.immediately)
    }
  }

  private func unavailable(_ message: DeckFeature.State.Message) -> some View {
    ContentUnavailableView {
      Label {
        Text(message.title)
          .accessibilityIdentifier("deck.message")
      } icon: {
        Image(systemName: message.systemImage)
      }
    } actions: {
      if store.showsSettingsButton {
        Button("Open Settings") { store.send(.settingsButtonTapped) }
          .font(.body)
          .foregroundStyle(Theme.ink)
          .frame(minHeight: 44)
          .accessibilityIdentifier("deck.openSettings")
      }
    }
  }

  private func delete(_ card: Card) {
    withAnimation(.easeInOut(duration: 0.25)) {
      _ = store.send(.rowSwipedToDelete(card.id))
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

#Preview("Not set up") {
  DeckView(store: Store(initialState: DeckFeature.State()) { DeckFeature() } withDependencies: {
    $0.apiClient.isConfigured = { false }
  })
}

#Preview("Empty deck") {
  DeckView(store: Store(initialState: DeckFeature.State()) { DeckFeature() } withDependencies: {
    $0.apiClient = .inMemory(cards: [])
  })
}
