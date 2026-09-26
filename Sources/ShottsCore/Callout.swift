import CoreGraphics
import Foundation

/// Where the text of a callout goes once its arrow is drawn: beside the tail, on the side away
/// from the tip, wrapping before the picture's edge. A mostly horizontal arrow puts the text
/// left or right of the tail, justified against it; a mostly vertical one puts it below or
/// above, centered on it. All values in image pixels.
public struct CalloutLayout: Equatable, Sendable {
    public enum Side: Equatable, Sendable {
        case left, right, above, below
    }

    public var side: Side
    /// The top-left of the text box for a one-line text. The box keeps this width; `origin(for:in:)`
    /// gives where a taller box goes.
    public var origin: CGPoint
    /// The widest a line may be before it wraps; the box's width.
    public var width: Double
    private var lineHeight: Double
    private var bounds: CGRect

    /// - Parameters:
    ///   - lineHeight: one line of the text, so a horizontal callout's first line centers on the tail.
    ///   - maxWidth: the widest box wanted, whatever room there is.
    public init(tail: CGPoint, tip: CGPoint, lineHeight: Double, maxWidth: Double, in bounds: CGRect) {
        self.lineHeight = lineHeight
        self.bounds = bounds
        let gap = lineHeight * 0.5
        let dx = tip.x - tail.x, dy = tip.y - tail.y
        if abs(dy) > abs(dx) {
            // Vertical: the text sits on the far side of the tail from the tip, centered.
            side = dy < 0 ? .below : .above
            width = min(maxWidth, bounds.width)
            let x = min(max(tail.x - width / 2, bounds.minX), max(bounds.minX, bounds.maxX - width))
            let y = side == .below ? tail.y + gap : tail.y - gap - lineHeight
            origin = CGPoint(x: x, y: y)
        } else {
            let roomLeft = tail.x - gap - bounds.minX
            let roomRight = bounds.maxX - (tail.x + gap)
            // Away from the tip, unless there is no room there and the other side has more.
            var onLeft = dx >= 0
            if onLeft, roomLeft < lineHeight * 3, roomRight > roomLeft { onLeft = false }
            if !onLeft, roomRight < lineHeight * 3, roomLeft > roomRight { onLeft = true }
            side = onLeft ? .left : .right
            width = max(min(maxWidth, onLeft ? roomLeft : roomRight), lineHeight)
            origin = CGPoint(x: onLeft ? tail.x - gap - width : tail.x + gap, y: tail.y - lineHeight / 2)
        }
        origin.y = min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - lineHeight))
    }

    /// The box's right edge, half a line short of the tail for a leftward callout.
    public var rightEdge: Double { origin.x + width }

    /// The box's bottom edge for a one-line text, half a line short of the tail when above it.
    public var bottomEdge: Double { origin.y + lineHeight }

    public var anchorsRight: Bool { side == .left }

    /// How the text sits in its box: against the tail, or centered under or over it.
    public var alignment: TextAlignment {
        switch side {
        case .left: .right
        case .right: .left
        case .above, .below: .center
        }
    }

    /// Where a box of `size` sits: the same width, growing downward below or beside the tail,
    /// upward above it, and never past the picture's edges.
    public func origin(for size: CGSize) -> CGPoint {
        var o = origin
        if side == .above { o.y = bottomEdge - size.height }
        o.y = min(max(o.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height))
        return o
    }
}
