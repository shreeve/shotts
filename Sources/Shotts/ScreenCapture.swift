import AppKit
import ScreenCaptureKit
import ShottsUI

/// The one place Shotts reads the screen, through ScreenCaptureKit: each display live while the
/// picker is up (`LiveDisplay`), a clicked window on its own, and the window list.
enum ScreenCapture {
    enum Failure: LocalizedError {
        case noDisplay
        case noWindow

        var errorDescription: String? {
            switch self {
            case .noDisplay: "No display could be captured."
            case .noWindow: "That window is no longer on screen."
            }
        }
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS for permission. The system shows its own dialog, once per code signature, and
    /// records the answer; this returns before the user answers, so it reports nothing.
    static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    /// One window on its own, whatever covers it, at the window's own scale, which comes back
    /// with the picture. With `shadow`, the picture is the window with the shadow macOS draws
    /// around it, on a transparent margin, exactly as the system's own window screenshots come
    /// out. Fails when the window has gone since the displays were pictured.
    static func captureWindow(_ id: CGWindowID, shadow: Bool) async throws -> (image: CGImage, scale: CGFloat) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw Failure.noWindow }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.ignoreShadowsSingleWindow = !shadow
        // The filter's content rectangle is the window plus, with the shadow, its margins; its
        // scale is that of the display holding most of the window, not the one clicked on.
        let size = filter.contentRect.size
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int(size.width * scale)
        configuration.height = Int(size.height * scale)
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.scalesToFit = false
        return (try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration), scale)
    }

    /// The ordinary windows on screen, front to back, in the window server's space (origin at
    /// the primary display's top-left): layer 0, visible, at least 40 points each way, and not
    /// ones their app keeps out of captures, which ScreenCaptureKit would not picture. Shotts'
    /// editors are among them, since what is on screen can be captured; the picker, far above
    /// ordinary windows, is not.
    static func windowList() -> [(id: CGWindowID, frame: CGRect)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  (w[kCGWindowSharingState as String] as? Int) != 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width >= 40, frame.height >= 40
            else { return nil }
            return (id, frame)
        }
    }

    /// The windows in `list` that show on `display`, in points from its top-left corner as the
    /// picker measures. `CGDisplayBounds` is the display in the window server's space.
    static func windows(in list: [(id: CGWindowID, frame: CGRect)], on display: CGDirectDisplayID) -> [WindowInfo] {
        let bounds = CGDisplayBounds(display)
        return list.compactMap { id, frame in
            let visible = frame.intersection(bounds)
            guard !visible.isEmpty else { return nil }
            return WindowInfo(id: id, frame: visible.offsetBy(dx: -bounds.minX, dy: -bounds.minY))
        }
    }
}
