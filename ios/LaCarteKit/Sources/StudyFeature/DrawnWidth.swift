import UIKit

extension StudyView {
  /// The widest line of `text` as drawn, laid out in TextKit the way SwiftUI lays out a `Text` (spec 017, layout D).
  /// SwiftUI's measured width keeps the space a wrapped line breaks at, which isn't drawn: a centred line sits half a
  /// space inside it, so an answer column that wide overhangs the question's first letter.
  static func drawnWidth(of text: String, font: UIFont, in width: CGFloat) -> CGFloat {
    let style = NSMutableParagraphStyle()
    style.lineBreakStrategy = .standard
    let storage = NSTextStorage(string: text, attributes: [.font: font, .paragraphStyle: style])
    let layout = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    layout.addTextContainer(container)
    storage.addLayoutManager(layout)

    let string = text as NSString
    var widest: CGFloat = 0
    layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, glyphs, _ in
      let line = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
      let ink = string.substring(with: line).replacing(/\s+$/, with: "")
      guard !ink.isEmpty else { return }
      let drawn = NSRange(location: line.location, length: ink.utf16.count)
      let drawnGlyphs = layout.glyphRange(forCharacterRange: drawn, actualCharacterRange: nil)
      widest = max(widest, layout.boundingRect(forGlyphRange: drawnGlyphs, in: container).width)
    }
    return widest
  }
}
