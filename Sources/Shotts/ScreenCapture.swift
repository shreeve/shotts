import AppKit
import ScreenCaptureKit

/// The one place Shotts reads the screen: the rectangle the user just selected, at the
/// display's full resolution, through ScreenCaptureKit.
enum ScreenCapture {
    struct Capture {
        var image: CGImage
        var scale: Double
    }

    enum Failure: LocalizedError {
        case noDisplay
        case permission

        var errorDescription: String? {
            switch self {
            case .noDisplay: "The screen you selected on could not be found."
            case .permission: "Shotts needs Screen Recording permission to capture the screen."
            }
        }
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS for permission; the system shows its own dialog and records the answer for
    /// this app's signature. Returns whether it is granted right now.
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// `rect` is in points from the screen's top-left corner, as `AreaSelection` reports it.
    static func capture(rect: CGRect, on screen: NSScreen) async throws -> Capture {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw Failure.noDisplay
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw Failure.noDisplay }

        // Leave Shotts' own windows out, in case an overlay is still fading.
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let scale = screen.backingScaleFactor
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rect
        configuration.width = Int(rect.width * scale)
        configuration.height = Int(rect.height * scale)
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.scalesToFit = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return Capture(image: image, scale: scale)
    }
}
