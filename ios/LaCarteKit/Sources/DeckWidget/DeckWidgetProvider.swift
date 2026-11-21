import APIClient
import Foundation
import WidgetKit

/// Fetches `/stats` once per timeline; the live `APIClient` resolves the server from the App Group and the Keychain.
struct DeckWidgetProvider: TimelineProvider {
  func placeholder(in context: Context) -> DeckWidgetEntry {
    .sample
  }

  func getSnapshot(in context: Context, completion: @escaping @Sendable (DeckWidgetEntry) -> Void) {
    if context.isPreview {
      completion(.sample)
      return
    }
    Task { completion(await Self.fetch(now: .now).entry) }
  }

  func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<DeckWidgetEntry>) -> Void) {
    if context.isPreview {
      completion(Timeline(entries: [.sample], policy: .never))
      return
    }
    Task {
      let (entry, refresh) = await Self.fetch(now: .now)
      completion(Timeline(entries: [entry], policy: .after(refresh)))
    }
  }

  private static func fetch(now: Date) async -> (entry: DeckWidgetEntry, refresh: Date) {
    let result: Result<DeckStats, any Error>
    do {
      let stats = try await APIClient.liveValue.stats()
      saveCache(stats)
      result = .success(stats)
    } catch {
      result = .failure(error)
    }
    let entry = DeckWidgetEntry(date: now, content: .make(result: result, cached: loadCache()))
    return (entry, DeckWidgetEntry.nextRefresh(stats: try? result.get(), now: now, calendar: .current))
  }

  private static let cacheKey = "widget.lastStats"

  private static func saveCache(_ stats: DeckStats) {
    AppGroup.defaults.set(try? JSONEncoder().encode(stats), forKey: cacheKey)
  }

  private static func loadCache() -> DeckStats? {
    AppGroup.defaults.data(forKey: cacheKey).flatMap { try? JSONDecoder().decode(DeckStats.self, from: $0) }
  }
}
