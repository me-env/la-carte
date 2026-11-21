import SwiftUI

/// The small round icon button used for every chrome action (list, add, close, undo…).
public struct CircleIconButton: View {
  let systemImage: String
  let accessibilityLabel: LocalizedStringKey
  let action: () -> Void

  @Environment(\.self) private var environment

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
        .font(.system(size: 15, weight: .regular))
        .foregroundStyle(Theme.ink)
        .frame(width: 44, height: 44)
        .background(Theme.surface, in: .circle)
        .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: environment.colorScheme == .dark ? 1 : 0))
        .shadow(color: Theme.shadow.resolve(in: environment), radius: 8, y: 2)
    }
    .buttonStyle(.plain)
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
