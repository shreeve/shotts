import CoreGraphics
import Foundation

/// A capture being edited: the bitmap's size, its backing scale, the annotations on it, and a
/// crop. The bitmap itself stays with the UI; Core only knows its size, so undo snapshots of a
/// document cost a few annotations, never pixels.
public struct Document: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// Pixels per point of the display the capture came from (2 on Retina).
    public var scale: Double
    public var annotations: [Annotation]
    /// In image pixels. `nil` means the whole image.
    public var crop: CGRect?

    public init(width: Int, height: Int, scale: Double, annotations: [Annotation] = [], crop: CGRect? = nil) {
        self.width = width
        self.height = height
        self.scale = scale
        self.annotations = annotations
        self.crop = crop
    }

    public var pixelBounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

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
