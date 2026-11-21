import SwiftUI
import UIKit

/// A person's photo from a public URL (spec 014) in a fixed frame, so loading or failing never moves the layout.
public struct CardPhoto: View {
  public enum Style {
    /// 44 pt circle: the deck row.
    case thumbnail
    /// 88 pt circle: the note editor.
    case preview
    /// 4:5 portrait, rounded: the card face (spec 014d).
    case card
  }

  let url: URL?
  let style: Style
  let onFailure: (() -> Void)?

  @State private var image: Image?
  @State private var failed = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  /// `onFailure` runs when `url` can't be loaded (never for a missing URL).
  public init(url: URL?, style: Style, onFailure: (() -> Void)? = nil) {
    self.url = url
    self.style = style
    self.onFailure = onFailure
  }

  public var body: some View {
    ZStack {
      if let image {
        image
          .resizable()
          .scaledToFill()
          .transition(.opacity)
      } else if url == nil || failed {
        symbol
      } else {
        Rectangle().fill(Theme.hairline)
      }
    }
    .frame(width: size.width, height: size.height)
    // A 2 pt stroke on the edge, clipped to its inner 1 pt: white photos don't bleed into the paper.
    .overlay(shape.stroke(Theme.hairline, lineWidth: 2))
    .clipShape(shape)
    .task(id: url) { await load() }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(failed ? "Photo, not loaded" : "Photo")
    .accessibilityAddTraits(.isImage)
  }

  /// Not `AsyncImage`: it can stay on its empty phase when a load fails, and it has no timeout.
  private func load() async {
    image = nil
    failed = false
    guard let url else { return }
    do {
      let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10))
      guard let uiImage = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
      withAnimation(reduceMotion ? nil : Theme.Motion.standard) { image = Image(uiImage: uiImage) }
    } catch {
      guard !Task.isCancelled else { return }
      failed = true
      onFailure?()
    }
  }

  private var symbol: some View {
    Image(systemName: "person.fill")
      .resizable()
      .scaledToFit()
      .frame(width: size.width / 3, height: size.height / 3)
      .foregroundStyle(Theme.secondaryInk)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var size: CGSize {
    switch style {
    case .thumbnail: return CGSize(width: Theme.Photo.thumbnail, height: Theme.Photo.thumbnail)
    case .preview: return CGSize(width: Theme.Photo.preview, height: Theme.Photo.preview)
    case .card:
      let width = dynamicTypeSize.isAccessibilitySize ? Theme.Photo.cardCompact : Theme.Photo.card
      return CGSize(width: width, height: width * 5 / 4)
    }
  }

  private var shape: AnyShape {
    switch style {
    case .thumbnail, .preview: AnyShape(Circle())
    case .card: AnyShape(RoundedRectangle(cornerRadius: Theme.Radius.photo, style: .continuous))
    }
  }
}

#Preview {
  HStack(spacing: Theme.Spacing.m) {
    CardPhoto(url: nil, style: .thumbnail)
    CardPhoto(url: URL(string: "https://invalid.example/photo.jpg"), style: .preview)
    CardPhoto(url: nil, style: .card)
  }
  .padding()
  .background(Theme.background)
}
