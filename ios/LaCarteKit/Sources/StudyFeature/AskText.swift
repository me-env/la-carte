import APIClient

/// The card written out for an AI app (spec 016): its id, so an agent can look it up, and both sides as shown.
enum AskText {
  static func make(for card: Card) -> String {
    let answer = card.type == .person ? card.type.fields.filter { !card.prompt.contains($0) } : card.answer
    return "This is the card \(card.id.uuidString.lowercased()) in the La Carte flashcard app.\n"
      + "Question: \(side(card.prompt, of: card))\nAnswer: \(side(answer, of: card))\n\n"
  }

  /// Basic fields as bare text; person fields as `Label: value`, since a lone "Ada" doesn't say what it is.
  private static func side(_ names: [String], of card: Card) -> String {
    card.type.fields
      .filter { names.contains($0) && card.fields[$0]?.isEmpty == false }
      .map { name in
        let value = card.fields[name] ?? ""
        return card.type == .person ? "\(name.prefix(1).uppercased() + name.dropFirst()): \(value)" : value
      }
      .joined(separator: "; ")
  }
}
