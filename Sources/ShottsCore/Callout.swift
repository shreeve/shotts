import CoreGraphics
import Foundation

/// Where the text of a callout goes once its arrow is drawn: beside the tail, on the side away
/// from the tip, wrapping before the picture's edge. All values in image pixels.
public struct CalloutLayout: Equatable, Sendable {
    /// The top-left of the text box. When `anchorsRight`, it is the box's right edge that is
    /// fixed at `origin.x + width`; the box grows leftward as the text does.
    public var origin: CGPoint
    /// The widest a line may be before it wraps.
    public var width: Double
    public var anchorsRight: Bool

    /// - Parameters:
    ///   - lineHeight: one line of the text, so the first line centers on the tail.
    ///   - maxWidth: the widest box wanted, whatever room there is.
    public init(tail: CGPoint, tip: CGPoint, lineHeight: Double, maxWidth: Double, in bounds: CGRect) {
        let gap = lineHeight * 0.5
        let roomLeft = tail.x - gap - bounds.minX
        let roomRight = bounds.maxX - (tail.x + gap)
        // Away from the tip, unless there is no room there and the other side has more.
        var onLeft = tip.x >= tail.x
        if onLeft, roomLeft < lineHeight * 3, roomRight > roomLeft { onLeft = false }
        if !onLeft, roomRight < lineHeight * 3, roomLeft > roomRight { onLeft = true }

        if onLeft {
            width = max(min(maxWidth, roomLeft), lineHeight)
            origin = CGPoint(x: tail.x - gap - width, y: 0)
            anchorsRight = true
        } else {
            width = max(min(maxWidth, roomRight), lineHeight)
            origin = CGPoint(x: tail.x + gap, y: 0)
            anchorsRight = false
        }
        origin.y = min(max(tail.y - lineHeight / 2, bounds.minY), max(bounds.minY, bounds.maxY - lineHeight))
    }

    /// The box's right edge, for a right-anchored callout whose text has been measured.
    public var rightEdge: Double { origin.x + width }

    /// Where a box of `size` sits for this layout: against the anchored edge, and moved up if
    /// it would run past the bottom of `bounds`.
    public func origin(for size: CGSize, in bounds: CGRect) -> CGPoint {
        var o = origin
        if anchorsRight { o.x = max(bounds.minX, rightEdge - size.width) }
        if o.y + size.height > bounds.maxY { o.y = max(bounds.minY, bounds.maxY - size.height) }
        return o
    }
}
