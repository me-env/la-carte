import SwiftUI

/// The small round icon button used for every chrome action (list, add, close, undo…).
public struct CircleIconButton: View {
  let systemImage: String
  let accessibilityLabel: LocalizedStringKey
  let action: () -> Void

  public init(
    _ systemImage: String,
    accessibilityLabel: LocalizedStringKey,
    action: @escaping () -> Void
  ) {
    self.systemImage = systemImage
    self.accessibilityLabel = accessibilityLabel
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 17, weight: .regular))
        .foregroundStyle(Theme.ink)
        .frame(width: 44, height: 44)
        .contentShape(.circle)
    }
    .buttonStyle(.plain)
    // The same glass circle and 17 pt glyph as the system toolbar buttons on Deck, Settings and the editor.
    .glassEffect(.regular.interactive(), in: .circle)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityShowsLargeContentViewer {
      Label(accessibilityLabel, systemImage: systemImage)
    }
  }
}

#Preview {
  HStack {
    CircleIconButton("list.bullet", accessibilityLabel: "Cards") {}
    CircleIconButton("plus", accessibilityLabel: "Add") {}
  }
  .padding()
  .background(Theme.background)
}
