import DesignSystem
import SwiftUI
import WidgetKit

/// Draws a `StreakGrid`: 4 rows of 7 marks at a 19 pt pitch (133 × 76 pt), one shape per unit, all about the same ink
/// area (spec 024). Decorative: the widget's accessibility label says what it shows.
struct StreakGridView: View {
  let grid: StreakGrid
  @Environment(\.widgetRenderingMode) private var renderingMode

  static let pitch: CGFloat = 19

  var body: some View {
    VStack(spacing: 0) {
      ForEach(0..<4, id: \.self) { row in
        HStack(spacing: 0) {
          ForEach(0..<7, id: \.self) { column in
            mark(grid.marks[row * 7 + column])
              .frame(width: Self.pitch, height: Self.pitch)
          }
        }
      }
    }
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private func mark(_ mark: StreakGrid.Mark) -> some View {
    switch (mark.unit, mark.status) {
    case (_, .frozenRun), (_, .frozenOlder):
      Circle().strokeBorder(style(mark.status), lineWidth: 1.5).frame(width: 9, height: 9)
    case (_, .todayPending):
      Circle().fill(style(.missed))
        .overlay { Circle().strokeBorder(today, lineWidth: 2).widgetAccentable() }
        .frame(width: 9, height: 9)
    case (_, .todayStudied):
      Circle().fill(today).widgetAccentable().frame(width: 9, height: 9)
    case (.day, _):
      Circle().fill(style(mark.status)).frame(width: 9, height: 9)
    case (.week, _):
      RoundedRectangle(cornerRadius: 2).fill(style(mark.status)).frame(width: 8.5, height: 8.5)
    case (.month, _):
      Pentagon().fill(style(mark.status)).frame(width: 11, height: 11).offset(y: 0.25)
    case (.year, _):
      Star().fill(style(mark.status)).frame(width: 14.8, height: 14.8).offset(y: 0.5)
    }
  }

  private func style(_ status: StreakGrid.Status) -> AnyShapeStyle {
    switch status {
    case .run, .frozenRun: renderingMode.ink
    case .older, .frozenOlder: AnyShapeStyle(renderingMode.secondaryInk.opacity(0.6))
    case .missed, .todayPending, .todayStudied: AnyShapeStyle(renderingMode.secondaryInk.opacity(0.35))
    }
  }

  /// The widget's one pink element; on tinted Home Screens the system tints it instead (`widgetAccentable`).
  private var today: AnyShapeStyle {
    renderingMode == .fullColor ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary)
  }
}

extension WidgetRenderingMode {
  /// Tinted and clear Home Screens re-color the widget; plain hierarchical styles stay readable there.
  var ink: AnyShapeStyle { self == .fullColor ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(.primary) }
  var secondaryInk: AnyShapeStyle { self == .fullColor ? AnyShapeStyle(Theme.secondaryInk) : AnyShapeStyle(.secondary) }
}

/// A regular pentagon, point up, its circumcircle filling the frame; corners rounded by 1.2 pt (the month mark).
struct Pentagon: Shape {
  func path(in rect: CGRect) -> Path {
    let radius = min(rect.width, rect.height) / 2
    return .roundedPolygon((0..<5).map { point(in: rect, radius: radius, step: $0, of: 5) }, cornerRadius: 1.2)
  }
}

/// A 5-point star, its outer points on the frame's circle and its inner ones at half that radius; corners rounded by
/// 1.2 pt (the year mark).
struct Star: Shape {
  func path(in rect: CGRect) -> Path {
    let radius = min(rect.width, rect.height) / 2
    let points = (0..<10).map { point(in: rect, radius: $0.isMultiple(of: 2) ? radius : radius / 2, step: $0, of: 10) }
    return .roundedPolygon(points, cornerRadius: 1.2)
  }
}

/// The `step`th of `count` points evenly spaced on a circle around the rect's centre, starting straight up.
private func point(in rect: CGRect, radius: CGFloat, step: Int, of count: Int) -> CGPoint {
  let angle = -Double.pi / 2 + 2 * .pi * Double(step) / Double(count)
  return CGPoint(x: rect.midX + radius * cos(angle), y: rect.midY + radius * sin(angle))
}

extension Path {
  /// A closed polygon through `points` with each corner replaced by an arc of `cornerRadius`.
  fileprivate static func roundedPolygon(_ points: [CGPoint], cornerRadius: CGFloat) -> Path {
    var path = Path()
    let last = points[points.count - 1]
    path.move(to: CGPoint(x: (last.x + points[0].x) / 2, y: (last.y + points[0].y) / 2))
    for (i, corner) in points.enumerated() {
      path.addArc(tangent1End: corner, tangent2End: points[(i + 1) % points.count], radius: cornerRadius)
    }
    path.closeSubpath()
    return path
  }
}
