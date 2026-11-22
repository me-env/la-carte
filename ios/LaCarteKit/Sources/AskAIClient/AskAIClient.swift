import Dependencies
import DependenciesMacros
import UIKit

/// Hands a card to the user's AI app (spec 016): copies its text, then opens the app picked in Settings.
@DependencyClient
public struct AskAIClient: Sendable {
  public var copy: @Sendable (_ text: String) -> Void
  /// False when no installed app claims the universal link.
  public var open: @Sendable (_ url: URL) async -> Bool = { _ in false }
}

extension AskAIClient: DependencyKey {
  public static let liveValue = AskAIClient(
    copy: { UIPasteboard.general.string = $0 },
    open: { @MainActor url in await UIApplication.shared.open(url, options: [.universalLinksOnly: true]) }
  )
  public static let previewValue = AskAIClient(copy: { _ in }, open: { _ in false })
  public static let testValue = AskAIClient()
}

extension DependencyValues {
  public var askAI: AskAIClient {
    get { self[AskAIClient.self] }
    set { self[AskAIClient.self] = newValue }
  }
}
