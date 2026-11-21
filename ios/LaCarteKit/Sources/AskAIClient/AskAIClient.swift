import Dependencies
import DependenciesMacros
import UIKit

/// Hands a card to the user's AI app (spec 016): for now, by copying its text to the clipboard.
@DependencyClient
public struct AskAIClient: Sendable {
  public var copy: @Sendable (_ text: String) -> Void
}

extension AskAIClient: DependencyKey {
  public static let liveValue = AskAIClient(copy: { UIPasteboard.general.string = $0 })
  public static let previewValue = AskAIClient(copy: { _ in })
  public static let testValue = AskAIClient()
}

extension DependencyValues {
  public var askAI: AskAIClient {
    get { self[AskAIClient.self] }
    set { self[AskAIClient.self] = newValue }
  }
}
