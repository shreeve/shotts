import CoreGraphics
import Foundation

/// One mark on a capture. Every coordinate is in image pixels with the origin at the top-left,
/// the same space as the capture's bitmap.
public enum TextAlignment: Equatable, Sendable {
    case left, right
}

public struct Annotation: Identifiable, Equatable, Sendable {
    public enum Shape: Equatable, Sendable {
        case arrow(from: CGPoint, to: CGPoint)
        case rectangle(CGRect)
        case ellipse(CGRect)
        /// `size` is the text's layout box, measured by the UI when the text is set, so hit
        /// testing and bounds need no font machinery here. Lines wrap inside its width and sit
        /// against its left or right edge by `alignment`.
        case text(origin: CGPoint, string: String, size: CGSize, alignment: TextAlignment = .left)
        case pen([CGPoint])
        case highlighter([CGPoint])
        /// Pixelates the source under the rectangle.
        case obscure(CGRect)
    }

    public let id: UUID
    public var shape: Shape
    public var style: Style

    public init(id: UUID = UUID(), shape: Shape, style: Style) {
        self.id = id
        self.shape = shape
        self.style = style
    }

    /// The pixel rectangle the shape occupies, before stroke width and shadow.
    public var bounds: CGRect {
        switch shape {
        case let .arrow(from, to):
            return CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                          width: abs(to.x - from.x), height: abs(to.y - from.y))
        case let .rectangle(rect), let .ellipse(rect), let .obscure(rect):
            return rect.standardized
        case let .text(origin, _, size, _):
            return CGRect(origin: origin, size: size)
        case let .pen(points), let .highlighter(points):
            return Self.bounds(of: points)
        }
    }

    public func translated(by delta: CGPoint) -> Annotation {
        var copy = self
        switch shape {
        case let .arrow(from, to):
            copy.shape = .arrow(from: from + delta, to: to + delta)
        case let .rectangle(rect):
            copy.shape = .rectangle(rect.offsetBy(dx: delta.x, dy: delta.y))
        case let .ellipse(rect):
            copy.shape = .ellipse(rect.offsetBy(dx: delta.x, dy: delta.y))
        case let .obscure(rect):
            copy.shape = .obscure(rect.offsetBy(dx: delta.x, dy: delta.y))
        case let .text(origin, string, size, alignment):
            copy.shape = .text(origin: origin + delta, string: string, size: size, alignment: alignment)
        case let .pen(points):
            copy.shape = .pen(points.map { $0 + delta })
        case let .highlighter(points):
            copy.shape = .highlighter(points.map { $0 + delta })
        }
        return copy
    }

    /// Whether the shape has any extent worth keeping: a click without a drag makes nothing.
    public var isDegenerate: Bool {
        switch shape {
        case let .arrow(from, to):
            return from.distance(to: to) < 3
        case let .rectangle(rect), let .ellipse(rect), let .obscure(rect):
            return rect.width < 3 || rect.height < 3
        case let .text(_, string, _, _):
            return string.isEmpty
        case let .pen(points), let .highlighter(points):
            return points.count < 2
        }
    }

    static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

extension CGPoint {
    public static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    public static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    public func distance(to other: CGPoint) -> Double { hypot(other.x - x, other.y - y) }
}
