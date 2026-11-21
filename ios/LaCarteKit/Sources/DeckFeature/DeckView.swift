import APIClient
import ComposableArchitecture
import DesignSystem
import NoteEditorFeature
import SettingsFeature
import SwiftUI

public struct DeckView: View {
  @Bindable var store: StoreOf<DeckFeature>
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  public init(store: StoreOf<DeckFeature>) {
    self.store = store
  }

  public var body: some View {
    NavigationStack {
      content
        // Rows, menus and swipe-delete keep the system tint; the search cursor's pink is `Theme.tintSearchFields()`.
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
    }
    .sensoryFeedback(.impact(weight: .light), trigger: store.deletions)
    .sensoryFeedback(.error, trigger: store.phase) { _, new in new == .offline || new == .unauthorized }
    .onAppear { store.send(.onAppear) }
    .onChange(of: scenePhase) { _, phase in store.send(.scenePhaseChanged(phase)) }
    .sheet(item: $store.scope(\.$destination, action: \.destination).editor) { editorStore in
      NoteEditorView(store: editorStore)
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
        .padding(.horizontal, Theme.Spacing.m)
        .frame(maxWidth: .infinity)
        .containerRelativeFrame(.vertical)
      }
      .scrollDismissesKeyboard(.immediately)
    } else {
      List {
        ForEach(store.notes) { note in
          row(note)
            .listRowInsets(
              EdgeInsets(
                top: Theme.Spacing.s / 2, leading: Theme.Spacing.m,
                bottom: Theme.Spacing.s / 2, trailing: Theme.Spacing.m
              )
            )
            .listRowSeparator(.hidden)
            .listRowBackground(Rectangle().fill(Theme.background))
            .swipeActions(edge: .trailing) {
              Button("Delete", role: .destructive) { delete(note) }
                .accessibilityIdentifier("deck.row.\(note.id).delete")
            }
            .contextMenu {
              Button("Edit", systemImage: "pencil") { store.send(.rowTapped(note.id)) }
                .accessibilityIdentifier("deck.row.\(note.id).edit")
              Button("Delete", systemImage: "trash", role: .destructive) { delete(note) }
                .accessibilityIdentifier("deck.row.\(note.id).contextDelete")
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

  private func delete(_ note: Note) {
    withAnimation(.easeInOut(duration: 0.25)) {
      _ = store.send(.rowSwipedToDelete(note.id))
    }
  }

  private func row(_ note: Note) -> some View {
    Button {
      store.send(.rowTapped(note.id))
    } label: {
      HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: Theme.Spacing.m) {
        if note.type == .person {
          CardPhoto(url: note.photoURL, style: .thumbnail)
            .accessibilityIdentifier("deck.row.\(note.id).photo")
        }
        VStack(alignment: .leading, spacing: Theme.Spacing.s / 2) {
          HStack(spacing: Theme.Spacing.s) {
            Text(Self.dueText(note.due))
              .accessibilityIdentifier("deck.row.\(note.id).due")
            Spacer(minLength: 0)
            Text(note.stateText)
              .accessibilityIdentifier("deck.row.\(note.id).state")
          }
          .font(.meta)
          .foregroundStyle(Theme.secondaryInk)
          Text(note.title)
            .foregroundStyle(Theme.ink)
          Text(note.subtitle)
            .foregroundStyle(Theme.secondaryInk)
        }
        .font(.body)
        .lineLimit(1)
      }
      .padding(Theme.Spacing.m)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.row))
    }
    .buttonStyle(.plain)
    // `.contain` keeps the due/state texts queryable by UI tests inside the tappable row.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("deck.row.\(note.id)")
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
  DeckView(store: Store(initialState: DeckFeature.State()) { DeckFeature() } withDependencies: {
    $0.apiClient = .inMemory(notes: .fixtures)
  })
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
