import CoreGraphics
import Foundation

/// How the lines of a text sit in its box.
public enum TextAlignment: Equatable, Sendable {
    case left, center, right
}

/// One mark on a capture. Every coordinate is in image pixels with the origin at the top-left,
/// the same space as the capture's bitmap.
public struct Annotation: Identifiable, Equatable, Sendable {
    public enum Shape: Equatable, Sendable {
        case arrow(from: CGPoint, to: CGPoint)
        /// Stroked, or solid when `filled`.
        case rectangle(CGRect, filled: Bool = false)
        case ellipse(CGRect, filled: Bool = false)
        /// `size` is the text's layout box, measured by the UI when the text is set, so hit
        /// testing and bounds need no font machinery here. Lines wrap inside its width and sit
        /// against its left or right edge by `alignment`.
        case text(origin: CGPoint, string: String, size: CGSize, alignment: TextAlignment = .left)
        case pen([CGPoint])
        case highlighter([CGPoint])
        /// Pixelates the source under the rectangle.
        case obscure(CGRect)
        /// An arrow with text pegged to its tail: one object. The text box is laid out from
        /// the arrow by the UI (`CalloutLayout`) whenever the tail or the words change.
        case callout(from: CGPoint, to: CGPoint, text: TextBox)
    }

    /// Where a callout's words sit, and what they are.
    public struct TextBox: Equatable, Sendable {
        public var origin: CGPoint
        public var string: String
        public var size: CGSize
        public var alignment: TextAlignment

        public init(origin: CGPoint, string: String, size: CGSize, alignment: TextAlignment) {
            self.origin = origin
            self.string = string
            self.size = size
            self.alignment = alignment
        }

        public var frame: CGRect { CGRect(origin: origin, size: size) }
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
            return Self.bounds(of: [from, to])
        case let .rectangle(rect, _), let .ellipse(rect, _), let .obscure(rect):
            return rect.standardized
        case let .text(origin, _, size, _):
            return CGRect(origin: origin, size: size)
        case let .pen(points), let .highlighter(points):
            return Self.bounds(of: points)
        case let .callout(from, to, text):
            let arrow = Self.bounds(of: [from, to])
            return text.string.isEmpty ? arrow : arrow.union(text.frame)
        }
    }

    public func translated(by delta: CGPoint) -> Annotation {
        var copy = self
        switch shape {
        case let .arrow(from, to):
            copy.shape = .arrow(from: from + delta, to: to + delta)
        case let .rectangle(rect, filled):
            copy.shape = .rectangle(rect.offsetBy(dx: delta.x, dy: delta.y), filled: filled)
        case let .ellipse(rect, filled):
            copy.shape = .ellipse(rect.offsetBy(dx: delta.x, dy: delta.y), filled: filled)
        case let .obscure(rect):
            copy.shape = .obscure(rect.offsetBy(dx: delta.x, dy: delta.y))
        case let .text(origin, string, size, alignment):
            copy.shape = .text(origin: origin + delta, string: string, size: size, alignment: alignment)
        case let .pen(points):
            copy.shape = .pen(points.map { $0 + delta })
        case let .highlighter(points):
            copy.shape = .highlighter(points.map { $0 + delta })
        case let .callout(from, to, text):
            var moved = text
            moved.origin = text.origin + delta
            copy.shape = .callout(from: from + delta, to: to + delta, text: moved)
        }
        return copy
    }

    /// Whether the shape has nothing worth keeping: a click without a drag, words that are only
    /// spaces, or a shape drawn wholly outside the picture, where it would never show or export.
    public func isDegenerate(in picture: CGRect) -> Bool {
        guard bounds.insetBy(dx: -1, dy: -1).intersects(picture) else { return true }
        switch shape {
        case let .arrow(from, to), let .callout(from, to, _):
            return from.distance(to: to) < 3
        case let .rectangle(rect, _), let .ellipse(rect, _), let .obscure(rect):
            return abs(rect.width) < 3 || abs(rect.height) < 3
        case let .text(_, string, _, _):
            return string.allSatisfy(\.isWhitespace)
        case let .pen(points), let .highlighter(points):
            return points.count < 2
        }
    }

    /// The annotation as a drag of `delta` on one of its parts leaves it. An arrow's or callout's
    /// tail end, or a callout's words, move the tail and its head moves the tip, the other end
    /// staying put; the shaft, or anything else, moves the whole. A callout whose tail or tip moved
    /// needs its words laid out again, which takes the UI's text measuring.
    public func dragged(_ part: HitTest.ArrowPart?, by delta: CGPoint) -> Annotation {
        var copy = self
        switch (shape, part) {
        case let (.arrow(from, to), .tail?):
            copy.shape = .arrow(from: from + delta, to: to)
        case let (.arrow(from, to), .head?):
            copy.shape = .arrow(from: from, to: to + delta)
        case let (.callout(from, to, text), .tail?), let (.callout(from, to, text), .text?):
            copy.shape = .callout(from: from + delta, to: to, text: text)
        case let (.callout(from, to, text), .head?):
            copy.shape = .callout(from: from, to: to + delta, text: text)
        default:
            return translated(by: delta)
        }
        return copy
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
