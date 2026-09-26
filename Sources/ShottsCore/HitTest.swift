import CoreGraphics
import Foundation

/// Which annotation a point lands on, topmost first. Strokes count within `tolerance` pixels
/// of the line; filled kinds (text, obscure) count anywhere inside.
public enum HitTest {
    public static func annotation(at point: CGPoint, in document: Document, tolerance: Double) -> Annotation.ID? {
        for annotation in document.annotations.reversed() where hits(point, annotation, tolerance: tolerance) {
            return annotation.id
        }
        return nil
    }

    static func hits(_ p: CGPoint, _ a: Annotation, tolerance: Double) -> Bool {
        let reach = tolerance + a.style.strokeWidth / 2
        switch a.shape {
        case let .arrow(from, to):
            return distance(from: p, toSegment: from, to) <= reach
                || ArrowGeometry(from: from, to: to, width: a.style.strokeWidth, tapered: a.style.taperedArrows).outline.contains(p)
        case let .rectangle(rect, filled):
            // A stroked shape is hit on its line; a solid one anywhere inside.
            let r = rect.standardized
            return r.insetBy(dx: -reach, dy: -reach).contains(p) && (filled || !r.insetBy(dx: reach, dy: reach).contains(p))
        case let .ellipse(rect, filled):
            let r = rect.standardized
            guard r.width > 0, r.height > 0 else { return false }
            let nx = (p.x - r.midX) / (r.width / 2)
            let ny = (p.y - r.midY) / (r.height / 2)
            let d = sqrt(nx * nx + ny * ny) // 1 on the ellipse
            let band = reach / min(r.width, r.height) * 2
            return filled ? d <= 1 + band : abs(d - 1) <= band
        case .text, .obscure:
            return a.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        case let .pen(points), let .highlighter(points):
            if points.count == 1 { return points[0].distance(to: p) <= reach }
            for i in 1..<points.count where distance(from: p, toSegment: points[i - 1], points[i]) <= reach {
                return true
            }
            return false
        case .callout:
            return calloutPart(at: p, of: a, tolerance: tolerance) != nil
        }
    }

    public enum CalloutPart: Equatable, Sendable {
        /// The shaft: dragging it moves the whole callout.
        case arrow
        /// The words: dragging them moves the tail, the tip staying put.
        case text
        /// The head: dragging it moves the tip, the tail and words staying put.
        case head
        /// The tail's end: dragging it moves the tail, the tip staying put.
        case tail
    }

    /// Which part of a callout a point lands on: its words, the tail's end, its head, else its arrow.
    public static func calloutPart(at p: CGPoint, of a: Annotation, tolerance: Double) -> CalloutPart? {
        guard case let .callout(from, to, text) = a.shape else { return nil }
        if !text.string.isEmpty, text.frame.insetBy(dx: -tolerance, dy: -tolerance).contains(p) { return .text }
        // The end of the tail is a grip of its own, the size of the dot that marks it when selected.
        if p.distance(to: from) <= max(a.style.strokeWidth * 2, tolerance * 3) { return .tail }
        let geometry = ArrowGeometry(from: from, to: to, width: a.style.strokeWidth, tapered: a.style.taperedArrows)
        let headLength = max(a.style.strokeWidth * 6, 18)
        if p.distance(to: to) <= headLength + tolerance, geometry.outline.contains(p) || p.distance(to: to) <= tolerance + headLength / 2 {
            return .head
        }
        let reach = tolerance + a.style.strokeWidth / 2
        if distance(from: p, toSegment: from, to) <= reach || geometry.outline.contains(p) {
            return .arrow
        }
        return nil
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return p.distance(to: a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return p.distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }
}

extension Array where Element == CGPoint {
    /// Whether a point is inside this polygon (even-odd).
    func contains(_ p: CGPoint) -> Bool {
        guard count >= 3 else { return false }
        var inside = false
        var j = count - 1
        for i in 0..<count {
            let a = self[i], b = self[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
