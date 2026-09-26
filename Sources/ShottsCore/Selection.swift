import CoreGraphics
import Foundation

/// The rules of dragging out an area, shared by the capture overlay and the crop tool.
public enum SelectionRule {
    /// The rectangle between where a drag started and where the pointer is, normalized so
    /// dragging in any direction works, and square when `square` (Shift) is held: the square's
    /// side is the longer of the two, growing away from the anchor.
    public static func rect(anchor: CGPoint, pointer: CGPoint, square: Bool = false) -> CGRect {
        var dx = pointer.x - anchor.x
        var dy = pointer.y - anchor.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        return CGRect(x: anchor.x, y: anchor.y, width: dx, height: dy).standardized
    }

    /// Moves a rectangle by `delta` without letting it leave `bounds` (Space-drag during a
    /// selection). A rectangle larger than the bounds pins to the bounds' origin.
    public static func moved(_ rect: CGRect, by delta: CGPoint, within bounds: CGRect) -> CGRect {
        var r = rect.offsetBy(dx: delta.x, dy: delta.y)
        r.origin.x = min(max(r.origin.x, bounds.minX), max(bounds.minX, bounds.maxX - r.width))
        r.origin.y = min(max(r.origin.y, bounds.minY), max(bounds.minY, bounds.maxY - r.height))
        return r
    }

    /// Snaps a rectangle to whole pixels and clips it to the image.
    public static func pixelRect(_ rect: CGRect, scale: Double, within pixelBounds: CGRect) -> CGRect {
        let scaled = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        return scaled.integral.intersection(pixelBounds)
    }

    /// A selection this small is a click, not an area.
    public static func isUsable(_ rect: CGRect) -> Bool { rect.width >= 4 && rect.height >= 4 }
}
