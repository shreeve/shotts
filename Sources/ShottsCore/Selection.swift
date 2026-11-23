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

    /// Where a line from `anchor` toward `pointer` ends: at the pointer, or with `snapped`
    /// (Shift) on the nearest multiple of 45°, as far along it as the pointer reaches.
    public static func lineEnd(anchor: CGPoint, pointer: CGPoint, snapped: Bool) -> CGPoint {
        guard snapped else { return pointer }
        let dx = pointer.x - anchor.x, dy = pointer.y - anchor.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = dx * cos(angle) + dy * sin(angle)
        return CGPoint(x: anchor.x + length * cos(angle), y: anchor.y + length * sin(angle))
    }

    /// The arrow keys in the picker: the point `pixels` whole pixels on from the pixel under `point`
    /// (both in points, at `scale` pixels a point), at that pixel's middle so the pixel shown
    /// under the crosshair is the one meant, and never past `bounds`.
    public static func nudged(_ point: CGPoint, by pixels: CGPoint, scale: Double, within bounds: CGRect) -> CGPoint {
        func axis(_ v: Double, _ d: Double, _ lo: Double, _ hi: Double) -> Double {
            let first = (lo * scale).rounded(.up), last = (hi * scale).rounded(.up) - 1
            return (min(max((v * scale).rounded(.down) + d, first), last) + 0.5) / scale
        }
        return CGPoint(x: axis(point.x, pixels.x, bounds.minX, bounds.maxX), y: axis(point.y, pixels.y, bounds.minY, bounds.maxY))
    }

    /// Snaps a rectangle to whole pixels and clips it to the image.
    public static func pixelRect(_ rect: CGRect, scale: Double, within pixelBounds: CGRect) -> CGRect {
        let scaled = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        return scaled.integral.intersection(pixelBounds)
    }

    /// A selection under `minimum` either way is a click, not an area. The picker measures in
    /// points; the crop tool passes four points' worth of picture pixels.
    public static func isUsable(_ rect: CGRect, minimum: Double = 4) -> Bool { rect.width >= minimum && rect.height >= minimum }

    /// What a click without a drag takes, at `point` on a display of `bounds`: the frontmost of
    /// `windows` (frames on the display, front to back) under it, or, on the desktop, the whole
    /// display. Captured, or with Command recorded, either way.
    public static func clickTarget(at point: CGPoint, windows: [CGRect], bounds: CGRect) -> (rect: CGRect, isWindow: Bool) {
        if let window = windows.first(where: { $0.contains(point) }) { return (window, true) }
        return (bounds, false)
    }
}

/// A clicked window captured with its shadow. ScreenCaptureKit's `contentRect` for a window is
/// the window alone, without the shadow around it, and a picture that size gets the window and
/// its shadow squeezed into it. So the picture is made `margin` points larger each way, which
/// ScreenCaptureKit fills with the window at its own size and its whole shadow from the top-left
/// corner, and then trimmed to what is not fully transparent.
public enum WindowShadow {
    /// Room for the shadow, in points, added to the window's width and height: macOS's largest
    /// shadow, the active window's, reaches about 60 points below a window.
    public static let margin: Double = 200

    /// The smallest rectangle, in pixels from the top-left corner, holding every pixel of the
    /// picture that is not fully transparent; nil when it is all transparent. `alpha` holds
    /// `height` rows of `bytesPerRow` bytes, one per pixel, top row first.
    public static func visibleBounds(alpha: UnsafeBufferPointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) -> CGRect? {
        func rowIsClear(_ y: Int) -> Bool {
            let start = y * bytesPerRow
            for x in 0..<width where alpha[start + x] != 0 { return false }
            return true
        }
        var top = 0
        while top < height, rowIsClear(top) { top += 1 }
        guard top < height else { return nil }
        var bottom = height - 1
        while rowIsClear(bottom) { bottom -= 1 }
        var left = width, right = -1
        for y in top...bottom {
            let start = y * bytesPerRow
            var x = 0
            while x < left, alpha[start + x] == 0 { x += 1 }
            left = min(left, x)
            x = width - 1
            while x > right, alpha[start + x] == 0 { x -= 1 }
            right = max(right, x)
        }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }
}
