import AppKit
import ScreenCaptureKit
import ShottsUI

/// The one place Shotts reads the screen: every display, once, the moment the user asks for a
/// capture, at full resolution, through ScreenCaptureKit. The pictures live only as long as
/// the area picker.
enum ScreenCapture {
    enum Failure: LocalizedError {
        case noDisplay
        case permission

        var errorDescription: String? {
            switch self {
            case .noDisplay: "No display could be captured."
            case .permission: "Shotts needs Screen Recording permission to capture the screen."
            }
        }
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS for permission; the system shows its own dialog and records the answer for
    /// this app's signature. Returns whether it is granted right now.
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func captureDisplays() async throws -> [DisplayImage] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // Leave Shotts' own windows out, in case an editor is open.
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        var result: [DisplayImage] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == CGDirectDisplayID(number.uint32Value) })
            else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            let scale = screen.backingScaleFactor
            let configuration = SCStreamConfiguration()
            configuration.width = Int(screen.frame.width * scale)
            configuration.height = Int(screen.frame.height * scale)
            configuration.captureResolution = .best
            configuration.showsCursor = false
            configuration.scalesToFit = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            result.append(DisplayImage(screen: screen, image: image, scale: scale))
        }
        guard !result.isEmpty else { throw Failure.noDisplay }
        return result
    }
}
