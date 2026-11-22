import AskAIClient
import Foundation
import Testing

/// Spec 016b #3: the exact link each app is opened with.
struct AIAppTests {
  let text = "Question: a & b\nAnswer: 1+1 café"
  let encoded = "Question%3A%20a%20%26%20b%0AAnswer%3A%201%2B1%20caf%C3%A9"

  @Test func eachAppHasItsLink() {
    #expect(AIApp.vibe.link(for: text)?.absoluteString == "https://chat.mistral.ai/chat/")
    #expect(AIApp.claude.link(for: text)?.absoluteString == "https://claude.ai/new?q=\(encoded)")
    #expect(AIApp.chatgpt.link(for: text)?.absoluteString == "https://chatgpt.com/?q=\(encoded)")
    #expect(AIApp.perplexity.link(for: text)?.absoluteString == "https://www.perplexity.ai/search")
    #expect(AIApp.grok.link(for: text)?.absoluteString == "https://grok.com/")
    #expect(AIApp.copyOnly.link(for: text) == nil)
  }

  @Test func onlyUnreservedCharactersStayLiteral() {
    let link = AIApp.claude.link(for: "AZaz09-._~ !*'()")
    #expect(link?.absoluteString == "https://claude.ai/new?q=AZaz09-._~%20%21%2A%27%28%29")
  }
}
