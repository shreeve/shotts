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
        case let .rectangle(rect):
            let r = rect.standardized
            return r.insetBy(dx: -reach, dy: -reach).contains(p) && !r.insetBy(dx: reach, dy: reach).contains(p)
        case let .ellipse(rect):
            let r = rect.standardized
            guard r.width > 0, r.height > 0 else { return false }
            let nx = (p.x - r.midX) / (r.width / 2)
            let ny = (p.y - r.midY) / (r.height / 2)
            let d = sqrt(nx * nx + ny * ny) // 1 on the ellipse
            let band = reach / min(r.width, r.height) * 2
            return abs(d - 1) <= band
        case .text, .obscure:
            return a.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        case let .pen(points), let .highlighter(points):
            if points.count == 1 { return points[0].distance(to: p) <= reach }
            for i in 1..<points.count where distance(from: p, toSegment: points[i - 1], points[i]) <= reach {
                return true
            }
            return false
        }
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
