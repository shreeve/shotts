import AppKit
import CoreMedia
import ScreenCaptureKit
import ShottsUI

/// One display, live, while the picker is up: a ScreenCaptureKit stream of it keeps
/// `display.image` the latest frame and `display.windows` the windows on it, so the screen goes
/// on updating, shadows and all, and the selection is cut from the moment it is released. Only
/// the picker's own windows are left out. Streaming stops, and the frames go, when the picker
/// closes.
final class LiveDisplay {
    let display: DisplayImage
    private let id: CGDirectDisplayID
    private var stream: SCStream?
    private let frames: Frames
    /// Stopped, perhaps before the stream had started: a start that finishes afterwards stops
    /// it at once, so no stream outlives the picker.
    private var stopped = false
    /// Called when the stream stops by itself (permission withdrawn, the system's control for
    /// ending screen sharing): the picker would otherwise show a still screen as live.
    var onInterrupted: (() -> Void)?

    init?(screen: NSScreen, windows list: [(id: CGWindowID, frame: CGRect)]) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        id = CGDirectDisplayID(number.uint32Value)
        display = DisplayImage(screen: screen, image: nil, scale: screen.backingScaleFactor,
                               windows: ScreenCapture.windows(in: list, on: id), isLive: true)
        frames = Frames()
        frames.received = { [weak self] image in self?.received(image) }
        frames.stopped = { [weak self] in
            guard let self, !stopped else { return }
            onInterrupted?()
        }
    }

    /// Every display, with the windows on each from one reading of the window server.
    static func all() -> [LiveDisplay] {
        let list = ScreenCapture.windowList()
        return NSScreen.screens.compactMap { LiveDisplay(screen: $0, windows: list) }
    }

    /// Starts streaming, leaving out the windows numbered `excluded` (the picker's).
    func start(in content: SCShareableContent, excluding excluded: Set<Int>) async throws {
        guard let screen = content.displays.first(where: { $0.displayID == id }) else { throw ScreenCapture.Failure.noDisplay }
        let filter = SCContentFilter(display: screen, excludingWindows: content.windows.filter { excluded.contains(Int($0.windowID)) })
        let configuration = SCStreamConfiguration()
        configuration.width = Int(display.pixelBounds.width)
        configuration.height = Int(display.pixelBounds.height)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.captureResolution = .best
        configuration.showsCursor = false
        // Filtered display captures leave window shadows out unless told otherwise.
        configuration.ignoreShadowsDisplay = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 4
        guard !stopped else { return }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: frames)
        try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: DispatchQueue(label: "Shotts frames"))
        self.stream = stream
        try await stream.startCapture()
        if stopped { try? await stream.stopCapture() }
    }

    func stop() {
        stopped = true
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
    }

    /// Waits a moment for the first frame, for a selection released before one arrived.
    func firstFrame() async -> Bool {
        for _ in 0..<60 where display.image == nil { try? await Task.sleep(for: .milliseconds(16)) }
        return display.image != nil
    }

    /// The window list, read for every display at once a few times a second.
    private static var windowList: (read: Date, list: [(id: CGWindowID, frame: CGRect)]) = (.distantPast, [])

    private func received(_ image: CGImage) {
        display.image = image
        // Windows move, open, and close while the user aims; a few readings a second follow them.
        if Date.now.timeIntervalSince(Self.windowList.read) > 0.1 { Self.windowList = (.now, ScreenCapture.windowList()) }
        display.windows = ScreenCapture.windows(in: Self.windowList.list, on: id)
    }
}

/// Receives a stream's frames on its own queue and hands each to the main actor as an image
/// over the frame's own pixels, copying nothing.
private nonisolated final class Frames: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Set once, before streaming starts.
    var received: (@MainActor (CGImage) -> Void)?
    var stopped: (@MainActor () -> Void)?

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard let stopped else { return }
        Task { @MainActor in stopped() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = sampleBuffer.imageBuffer, let image = Self.image(of: buffer), let received else { return }
        Task { @MainActor in received(image) }
    }

    /// The frame as a `CGImage` reading the buffer's memory directly. The image keeps the buffer,
    /// locked for reading, until the image goes.
    static func image(of buffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            return nil
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer), height = CVPixelBufferGetHeight(buffer)
        let retained = Unmanaged.passRetained(buffer).toOpaque()
        guard let provider = CGDataProvider(dataInfo: retained, data: base, size: bytesPerRow * height, releaseData: { info, _, _ in
            guard let info else { return }
            let buffer = Unmanaged<CVPixelBuffer>.fromOpaque(info).takeRetainedValue()
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }) else {
            Unmanaged<CVPixelBuffer>.fromOpaque(retained).release()
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            return nil
        }
        let space = CVImageBufferGetColorSpace(buffer)?.takeUnretainedValue() ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CGImage(width: CVPixelBufferGetWidth(buffer), height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
