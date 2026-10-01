import CoreGraphics
import Foundation

/// A capture being edited: the bitmap's size, its backing scale, the annotations on it, and a
/// crop. The bitmap itself stays with the UI; Core only knows its size, so undo snapshots of a
/// document cost a few annotations, never pixels.
public struct Document: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// Pixels per point of the display the capture came from (2 on Retina).
    public let scale: Double
    public var annotations: [Annotation]
    /// In whole image pixels, inside the image; `setCrop` keeps it so. `nil` means the whole image.
    public private(set) var crop: CGRect?

    public init(width: Int, height: Int, scale: Double, annotations: [Annotation] = [], crop: CGRect? = nil) {
        self.width = width
        self.height = height
        self.scale = scale
        self.annotations = annotations
        setCrop(crop)
    }

    public var pixelBounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    /// The scale of a picture opened from a file, which carries none of its own: its DPI when that
    /// says more than 1x (`pixelWidth` over the `pointWidth` its DPI gives); otherwise, a picture
    /// wider than the screen is taken for a capture from a display of `screenScale`.
    public static func scale(ofFile pixelWidth: Int, pointWidth: Double, screenWidth: Double?, screenScale: Double) -> Double {
        let dpi = Double(pixelWidth) / pointWidth
        if dpi.isFinite, dpi > 1 { return dpi }
        if let screenWidth, Double(pixelWidth) > screenWidth { return max(screenScale, 1) }
        return 1
    }

    /// Whether the user has drawn on it or cropped it.
    public var isEdited: Bool { !annotations.isEmpty || crop != nil }

    /// Option-F10 brings back one closed capture: a capture closing takes its place, unless that
    /// would put annotated work out for a capture with none.
    public static func keepsAsLast(_ closed: Document, over kept: Document?) -> Bool {
        closed.isEdited || !(kept?.isEdited ?? false)
    }

    /// The part of the image the export shows.
    public var visibleRect: CGRect { crop?.intersection(pixelBounds) ?? pixelBounds }

    public var isBlank: Bool { annotations.isEmpty && crop == nil }

    public func annotation(_ id: Annotation.ID) -> Annotation? {
        annotations.first { $0.id == id }
    }

    public mutating func add(_ annotation: Annotation) {
        annotations.append(annotation)
    }

    public mutating func replace(_ annotation: Annotation) {
        guard let i = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        annotations[i] = annotation
    }

    public mutating func remove(_ id: Annotation.ID) {
        annotations.removeAll { $0.id == id }
    }

    /// Sets a crop, clamped to the image; a crop covering the whole image clears it.
    public mutating func setCrop(_ rect: CGRect?) {
        guard let rect else { crop = nil; return }
        let clamped = rect.standardized.intersection(pixelBounds).integral
        crop = (clamped.isEmpty || clamped == pixelBounds) ? nil : clamped
    }
}
