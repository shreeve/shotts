import CoreGraphics
import Foundation

/// Where the text of a callout goes once its arrow is drawn: beside the tail, on the side away
/// from the tip, wrapping before the picture's edge. A mostly horizontal arrow puts the text
/// left or right of the tail, justified against it and centered on it vertically; a mostly
/// vertical one puts it below or above, centered on it horizontally. All values in image pixels.
public struct CalloutLayout: Sendable {
    enum Side: Equatable, Sendable {
        case left, right, above, below
    }

    var side: Side
    /// The widest a line may be before it wraps.
    public var width: Double
    /// The point the text hangs from, a quarter of a line out from the tail on the text's side:
    /// the middle of the box's near edge.
    public var anchor: CGPoint
    private var lineHeight: Double
    private var bounds: CGRect

    /// - Parameters:
    ///   - lineHeight: one line of the text; a quarter of it is the gap between the tail and the words.
    ///   - maxWidth: the widest box wanted, whatever room there is.
    ///   - picture: where the words must stay, less `margin` on every side; on a picture too
    ///     small for the margin, it shrinks to a quarter of the picture's shorter side.
    public init(tail: CGPoint, tip: CGPoint, lineHeight: Double, maxWidth: Double, in picture: CGRect, margin: Double = 0) {
        let inset = max(0, min(margin, picture.width / 4, picture.height / 4))
        let bounds = picture.insetBy(dx: inset, dy: inset)
        self.lineHeight = lineHeight
        self.bounds = bounds
        let gap = lineHeight * 0.25
        let dx = tip.x - tail.x, dy = tip.y - tail.y
        if abs(dy) > abs(dx) {
            // Vertical: the text sits on the far side of the tail from the tip, centered on it.
            side = dy < 0 ? .below : .above
            width = min(maxWidth, bounds.width)
            anchor = CGPoint(x: tail.x, y: side == .below ? tail.y + gap : tail.y - gap)
        } else {
            let roomLeft = tail.x - gap - bounds.minX
            let roomRight = bounds.maxX - (tail.x + gap)
            // Away from the tip, unless there is no room there and the other side has more.
            var onLeft = dx >= 0
            if onLeft, roomLeft < lineHeight * 3, roomRight > roomLeft { onLeft = false }
            if !onLeft, roomRight < lineHeight * 3, roomLeft > roomRight { onLeft = true }
            side = onLeft ? .left : .right
            width = max(min(maxWidth, onLeft ? roomLeft : roomRight), lineHeight)
            anchor = CGPoint(x: onLeft ? tail.x - gap : tail.x + gap, y: tail.y)
        }
    }

    /// How the text sits in its box: against the tail, or centered under or over it.
    public var alignment: TextAlignment {
        switch side {
        case .left: .right
        case .right: .left
        case .above, .below: .center
        }
    }

    /// Where a box of `size` sits: its near edge on the anchor, centered along that edge, and
    /// never past the picture's edges. Beside the tail the box grows up and down evenly; below
    /// it grows downward, above it grows upward.
    public func origin(for size: CGSize) -> CGPoint {
        var o: CGPoint
        switch side {
        case .left: o = CGPoint(x: anchor.x - size.width, y: anchor.y - size.height / 2)
        case .right: o = CGPoint(x: anchor.x, y: anchor.y - size.height / 2)
        case .above: o = CGPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height)
        case .below: o = CGPoint(x: anchor.x - size.width / 2, y: anchor.y)
        }
        o.x = min(max(o.x, bounds.minX), max(bounds.minX, bounds.maxX - size.width))
        o.y = min(max(o.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height))
        return o
    }

    /// Where the words begin before any are typed: an empty line's box.
    public var origin: CGPoint { origin(for: CGSize(width: 0, height: lineHeight)) }
}
