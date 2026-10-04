import AppKit
import ScreenCaptureKit
import ShottsCore
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

    // MARK: - For `shotts`

    /// A display as `shotts` numbers it: 1 is the main display, the rest in the system's order;
    /// `bounds` in points in the window server's space.
    struct NumberedDisplay {
        var number: Int
        var id: CGDirectDisplayID
        var bounds: CGRect
        var scale: Double
    }

    static func numberedDisplays() -> [NumberedDisplay] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let main = CGMainDisplayID()
        let ordered = ids.filter { $0 == main } + ids.filter { $0 != main }
        return ordered.enumerated().map { i, id in
            let bounds = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let scale = mode.map { Double($0.pixelWidth) / Double(max($0.width, 1)) } ?? 1
            return NumberedDisplay(number: i + 1, id: id, bounds: bounds, scale: scale)
        }
    }

    /// The ordinary windows on screen, front to back, as `shotts list` shows them, each on the
    /// display holding most of it.
    static func scriptWindows(on displays: [NumberedDisplay]) -> [ScriptWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var bundles: [pid_t: String] = [:]
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  (w[kCGWindowSharingState as String] as? Int) != 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width >= 40, frame.height >= 40
            else { return nil }
            let pid = w[kCGWindowOwnerPID as String] as? pid_t ?? 0
            if bundles[pid] == nil { bundles[pid] = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "" }
            let display = displays.max { a, b in
                let x = a.bounds.intersection(frame), y = b.bounds.intersection(frame)
                return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
            }
            return ScriptWindow(id: id, app: w[kCGWindowOwnerName as String] as? String ?? "", bundle: bundles[pid] ?? "",
                                title: w[kCGWindowName as String] as? String ?? "",
                                frame: [frame.minX, frame.minY, frame.width, frame.height], display: display?.number ?? 1)
        }
    }

    /// An area of a display as it is now: `rect` in points from the display's top-left, at the
    /// display's `scale`, without the pointer, leaving out Shotts' windows above ordinary ones
    /// (its menu bar item).
    static func captureArea(display id: CGDirectDisplayID, rect: CGRect, scale: Double) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw Failure.noDisplay }
        let me = ProcessInfo.processInfo.processIdentifier
        let left = content.windows.filter { $0.owningApplication?.processID == me && $0.windowLayer != 0 }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rect
        configuration.width = Int((rect.width * scale).rounded())
        configuration.height = Int((rect.height * scale).rounded())
        configuration.scalesToFit = false
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.ignoreShadowsDisplay = false
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: left),
                                                          configuration: configuration)
    }
}
