import CoreGraphics
import Foundation

/// Which annotation a point lands on, topmost first. Strokes count within `tolerance` pixels of
/// the ink the renderer draws; solid kinds (text, obscure, filled rectangles and ellipses) count
/// anywhere inside. Stroke widths come from `Style`'s pixel metrics at the document's scale, the
/// same numbers the renderer uses.
public enum HitTest {
    public static func annotation(at point: CGPoint, in document: Document, tolerance: Double) -> Annotation.ID? {
        document.annotations.last { hits(point, $0, scale: document.scale, tolerance: tolerance) }?.id
    }

    static func hits(_ p: CGPoint, _ a: Annotation, scale: Double, tolerance: Double) -> Bool {
        let width = a.style.stroke(scale: scale)
        let reach = tolerance + width / 2
        /// A rectangle's or ellipse's stroke line: drawn inside it, centered half a width in.
        func strokeLine(_ rect: CGRect) -> CGRect {
            let r = rect.standardized
            return r.insetBy(dx: min(width / 2, r.width / 2), dy: min(width / 2, r.height / 2))
        }
        switch a.shape {
        case .arrow, .callout, .line:
            return arrowPart(at: p, of: a, scale: scale, tolerance: tolerance) != nil
        case let .rectangle(rect, filled):
            let line = strokeLine(rect)
            return line.insetBy(dx: -reach, dy: -reach).contains(p) && (filled || !line.insetBy(dx: reach, dy: reach).contains(p))
        case let .ellipse(rect, filled):
            let line = strokeLine(rect)
            guard line.width > 0, line.height > 0 else { return line.insetBy(dx: -reach, dy: -reach).contains(p) }
            // Distance to the ellipse to first order: its implicit function over its gradient.
            let a = line.width / 2, b = line.height / 2
            let nx = (p.x - line.midX) / a, ny = (p.y - line.midY) / b
            let f = nx * nx + ny * ny - 1
            let gradient = 2 * hypot(nx / a, ny / b)
            return (filled && f <= 0) || (gradient > 0 ? abs(f) / gradient <= reach : false)
        case .text, .obscure:
            return a.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        case let .pen(points):
            return near(p, points, within: reach)
        case let .highlighter(points):
            return near(p, points, within: tolerance + a.style.highlighterWidth(scale: scale) / 2)
        }
    }

    /// The parts of an arrow or callout, each dragged differently (`Annotation.dragged`).
    public enum ArrowPart: Equatable, Sendable {
        /// The shaft: dragging it moves the whole.
        case shaft
        /// A callout's words: dragging them moves the tail, the tip staying put.
        case text
        /// The head: dragging it moves the tip, the tail staying put.
        case head
        /// The tail's end: dragging it moves the tail, the tip staying put.
        case tail
    }

    /// Which part of an arrow, callout, or line a point lands on: a callout's words, the tail's
    /// end, the head (a line's far end), else the shaft. The end grips each take at most a third
    /// of the length, so even a short one keeps a shaft to move it by.
    public static func arrowPart(at p: CGPoint, of a: Annotation, scale: Double, tolerance: Double) -> ArrowPart? {
        let from: CGPoint, to: CGPoint
        var isLine = false
        switch a.shape {
        case let .arrow(f, t):
            (from, to) = (f, t)
        case let .line(f, t):
            (from, to, isLine) = (f, t, true)
        case let .callout(f, t, text):
            if !text.string.isEmpty, text.frame.insetBy(dx: -tolerance, dy: -tolerance).contains(p) { return .text }
            (from, to) = (f, t)
        default:
            return nil
        }
        let width = a.style.stroke(scale: scale)
        let geometry = isLine ? nil : a.style.arrow(from: from, to: to, scale: scale)
        let third = from.distance(to: to) / 3
        // An end without a head is a round grip, drawn as a dot when selected.
        let grip = min(max(width * 2, tolerance * 3), max(third, tolerance))
        if p.distance(to: from) <= grip { return .tail }
        if isLine, p.distance(to: to) <= grip { return .head }
        guard distance(from: p, toSegment: from, to) <= tolerance + width / 2 || geometry?.contains(p) == true else { return nil }
        if let geometry, p.distance(to: to) <= min(geometry.headLength + tolerance, max(third, tolerance)) { return .head }
        return .shaft
    }

    static func near(_ p: CGPoint, _ points: [CGPoint], within reach: Double) -> Bool {
        guard let first = points.first else { return false }
        if points.count == 1 { return first.distance(to: p) <= reach }
        return zip(points, points.dropFirst()).contains { distance(from: p, toSegment: $0, $1) <= reach }
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return p.distance(to: a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return p.distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }
}
