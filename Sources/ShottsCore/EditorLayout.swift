import CoreGraphics
import Foundation

/// How big the editor shows a picture. The zoom is points per picture pixel: never more than the
/// picture's on-screen size (`1 / scale`), and never less than what keeps its longer side
/// `minimumPicture` points long (or its on-screen size, when that is smaller). The window's
/// content is the bar above the picture, which sits on a field `inset` points wide all round,
/// and is never narrower than `minimumWidth`. Opening, resizing, and the green button all size
/// the window from these two functions, so they agree.
public struct EditorLayout: Sendable {
    public var picture: CGSize
    public var scale: Double
    public var barHeight: Double
    public var minimumWidth: Double
    public var inset: Double
    public var minimumPicture: Double

    public init(picture: CGSize, scale: Double, barHeight: Double, minimumWidth: Double, inset: Double, minimumPicture: Double) {
        self.picture = picture
        self.scale = scale
        self.barHeight = barHeight
        self.minimumWidth = minimumWidth
        self.inset = inset
        self.minimumPicture = minimumPicture
    }

    public var naturalZoom: Double { 1 / scale }

    public var minimumZoom: Double { min(naturalZoom, minimumPicture / max(picture.width, picture.height, 1)) }

    /// The zoom at which the picture fits a content area of this size.
    public func zoom(fitting content: CGSize) -> Double {
        let fit = min((content.width - inset * 2) / picture.width, (content.height - barHeight - inset * 2) / picture.height)
        return min(naturalZoom, max(minimumZoom, fit))
    }

    /// The content size that holds the picture at this zoom: snug around it, no narrower than the bar.
    public func contentSize(zoom: Double) -> CGSize {
        CGSize(width: max(minimumWidth, (picture.width * zoom + inset * 2).rounded()),
               height: (barHeight + picture.height * zoom + inset * 2).rounded())
    }
}
