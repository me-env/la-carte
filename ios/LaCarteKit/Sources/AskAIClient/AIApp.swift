import Foundation

/// The AI app "Ask about this card" opens, picked in Settings (spec 016b).
public enum AIApp: String, CaseIterable, Sendable {
  case vibe, claude, chatgpt, perplexity, grok, copyOnly

  public static let storageKey = "aiApp"

  public var title: String {
    switch self {
    case .vibe: "Vibe"
    case .claude: "Claude"
    case .chatgpt: "ChatGPT"
    case .perplexity: "Perplexity"
    case .grok: "Grok"
    case .copyOnly: "Copy only"
    }
  }

  /// The universal link that opens the app; Claude and ChatGPT get the text prefilled. Nil for "Copy only".
  public func link(for text: String) -> URL? {
    switch self {
    case .vibe: URL(string: "https://chat.mistral.ai/chat/")
    case .claude: URL(string: "https://claude.ai/new?q=\(Self.encoded(text))")
    case .chatgpt: URL(string: "https://chatgpt.com/?q=\(Self.encoded(text))")
    case .perplexity: URL(string: "https://www.perplexity.ai/search")
    case .grok: URL(string: "https://grok.com/")
    case .copyOnly: nil
    }
  }

  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
  )

  /// Only RFC 3986 unreserved characters stay literal.
  private static func encoded(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
  }
}
