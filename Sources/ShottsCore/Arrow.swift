import CoreGraphics
import Foundation

/// The shape of an arrow: one filled outline, a thin tail widening into a broad head whose barbs
/// sweep a little back, so it reads as a friendly pointer rather than a drafting symbol.
public struct ArrowGeometry: Equatable, Sendable {
    public var tip: CGPoint
    /// The outline to fill, starting at the tail and going around the tip.
    public var outline: [CGPoint]

    /// - Parameters:
    ///   - width: the stroke width in pixels; the shaft is about this wide at the head.
    ///   - tapered: a thin tail widening toward the head, or an even shaft.
    public init(from: CGPoint, to: CGPoint, width: Double, tapered: Bool = true) {
        tip = to
        let length = from.distance(to: to)
        guard length > 0 else {
            outline = [to, to, to]
            return
        }
        let ux = (to.x - from.x) / length, uy = (to.y - from.y) / length
        let px = -uy, py = ux
        let headLength = min(max(width * 6, 18), length * 0.55)
        let headHalfWidth = headLength * 0.62
        let shaftHalfAtHead = tapered ? width * 0.9 : width * 0.5
        let shaftHalfAtTail = tapered ? max(width * 0.12, 0.75) : width * 0.5
        func at(_ distanceFromTip: Double, _ offset: Double) -> CGPoint {
            CGPoint(x: to.x - ux * distanceFromTip + px * offset, y: to.y - uy * distanceFromTip + py * offset)
        }
        outline = [
            at(length, shaftHalfAtTail),            // tail, left edge
            at(headLength * 0.9, shaftHalfAtHead),  // where the shaft meets the head
            at(headLength * 1.08, headHalfWidth),   // left barb, swept back
            to,                                     // tip
            at(headLength * 1.08, -headHalfWidth),  // right barb
            at(headLength * 0.9, -shaftHalfAtHead),
            at(length, -shaftHalfAtTail),           // tail, right edge
        ]
    }
}
