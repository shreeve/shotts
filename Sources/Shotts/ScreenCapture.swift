import AppKit
import ScreenCaptureKit
import ShottsUI

/// The one place Shotts reads the screen: every display, once, the moment the user asks for a
/// capture, at full resolution, through ScreenCaptureKit. The pictures live only as long as
/// the area picker.
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

    /// Every display at once, and the windows on each from one reading of the window server,
    /// so all of them show the same moment. Shotts' own windows are left out.
    static func captureDisplays() async throws -> [DisplayImage] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let onScreen = windowList()
        let screens = NSScreen.screens.compactMap { screen -> (NSScreen, SCDisplay)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == CGDirectDisplayID(number.uint32Value) })
            else { return nil }
            return (screen, display)
        }
        // One capture per display, all started before any is awaited, so they overlap.
        let captures = screens.map { screen, display in
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
            configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
            configuration.captureResolution = .best
            configuration.showsCursor = false
            configuration.scalesToFit = false
            return Task { try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) }
        }
        var result: [DisplayImage] = []
        for ((screen, display), capture) in zip(screens, captures) {
            result.append(DisplayImage(screen: screen, image: try await capture.value, scale: screen.backingScaleFactor,
                                       windows: windows(in: onScreen, on: display.displayID)))
        }
        guard !result.isEmpty else { throw Failure.noDisplay }
        return result
    }

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
    /// the primary display's top-left): layer 0, visible, at least 40 points each way, not
    /// Shotts' own, and not ones their app keeps out of captures, which ScreenCaptureKit
    /// would not picture.
    private static func windowList() -> [(id: CGWindowID, frame: CGRect)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? pid_t) != me,
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

    /// The windows that show on one display, in points from its top-left corner as the picker
    /// measures. `CGDisplayBounds` is the display in the window server's space.
    private static func windows(in list: [(id: CGWindowID, frame: CGRect)], on display: CGDirectDisplayID) -> [WindowInfo] {
        let bounds = CGDisplayBounds(display)
        return list.compactMap { id, frame in
            let visible = frame.intersection(bounds)
            guard !visible.isEmpty else { return nil }
            return WindowInfo(id: id, frame: visible.offsetBy(dx: -bounds.minX, dy: -bounds.minY))
        }
    }
}
