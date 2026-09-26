import CoreGraphics
import Foundation

/// The shape of an arrow: one filled outline, a thin tail widening into a broad head whose barbs
/// sweep a little back, so it reads as a friendly pointer rather than a drafting symbol. The
/// renderer fills it and hit testing asks it, so both see the same arrow.
public struct ArrowGeometry: Sendable {
    /// The outline to fill, starting at the tail and going around the tip.
    public var outline: [CGPoint]
    /// How far the head reaches back from the tip.
    public var headLength: Double

    /// - Parameters:
    ///   - width: the stroke width in pixels; the shaft is about this wide at the head.
    ///   - tapered: a thin tail widening toward the head, or an even shaft.
    public init(from: CGPoint, to: CGPoint, width: Double, tapered: Bool = true) {
        let length = from.distance(to: to)
        headLength = min(max(width * 6, 18), length * 0.55)
        guard length > 0 else {
            outline = [to, to, to]
            return
        }
        let ux = (to.x - from.x) / length, uy = (to.y - from.y) / length
        let px = -uy, py = ux
        let headHalfWidth = headLength * 0.62
        // Never wider than the barbs: a short, thick arrow still has a head.
        let shaftHalfAtHead = min(tapered ? width * 0.9 : width * 0.5, headHalfWidth * 0.6)
        let shaftHalfAtTail = min(tapered ? max(width * 0.12, 0.75) : width * 0.5, shaftHalfAtHead)
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

    /// Whether a point is inside the outline.
    public func contains(_ p: CGPoint) -> Bool { polygon(outline, contains: p) }
}

/// Whether a point is inside a polygon (even-odd).
func polygon(_ points: [CGPoint], contains p: CGPoint) -> Bool {
    guard points.count >= 3 else { return false }
    var inside = false
    var j = points.count - 1
    for i in points.indices {
        let a = points[i], b = points[j]
        if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
            inside.toggle()
        }
        j = i
    }
    return inside
}
