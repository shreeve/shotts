import AppKit
import ScreenCaptureKit
import ShottsCore

/// A scrolling capture of one area of one display: ScreenCaptureKit streams the area, leaving
/// out Shotts' own windows (the outline, the panel, the menu bar item), and each frame goes to
/// Core's `ScrollStitcher` on a queue of its own, which keeps only the picture it builds and the
/// last frame. The pointer is not in it. Streaming stops at `finish` or `cancel`, and the frames
/// go with it.
nonisolated final class ScrollCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "Shotts scrolling capture")
    private var stream: SCStream?
    /// On `queue`.
    private var stitcher: ScrollStitcher?
    private var lastStep: ScrollStitcher.Step = .started
    /// The picture's pixels per point.
    let scale: CGFloat
    /// Called on the main thread after each frame: the height so far, whether the frame was not
    /// matched, and whether the picture is full.
    var onProgress: (@MainActor (Int, Bool, Bool) -> Void)?
    /// Called on the main thread when the stream stops by itself, as when its display goes.
    var onInterrupted: (@MainActor () -> Void)?

    init(scale: CGFloat) {
        self.scale = scale
    }

    /// Starts streaming `rect` (points from the top-left of the display `id`), leaving out the
    /// windows numbered `excluded` and Shotts' own above ordinary ones.
    func start(display id: CGDirectDisplayID, rect: CGRect, excluding excluded: Set<Int>) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw ScreenCapture.Failure.noDisplay }
        let me = ProcessInfo.processInfo.processIdentifier
        let left = content.windows.filter {
            excluded.contains(Int($0.windowID)) || ($0.owningApplication?.processID == me && $0.windowLayer != 0)
        }
        let width = Int((rect.width * scale).rounded()), height = Int((rect.height * scale).rounded())
        queue.sync { stitcher = ScrollStitcher(width: width, height: height) }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rect
        configuration.width = width
        configuration.height = height
        configuration.scalesToFit = false
        configuration.captureResolution = .best
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // The display's own colors, as a still of it is in.
        configuration.colorSpaceName = CGColorSpace.displayP3
        configuration.showsCursor = false
        configuration.ignoreShadowsDisplay = false
        // Up to 60 a second: the less the content moves between frames, the faster a scroll can
        // be and still match. Frames that come while one is being stitched wait or are dropped,
        // so a big area simply runs at the rate it can.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: left), configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    /// Stops, and makes the picture from what was stitched; nil if no frame came.
    func finish() async -> CGImage? {
        try? await stream?.stopCapture()
        stream = nil
        return queue.sync { () -> CGImage? in
            defer { stitcher = nil }
            guard let stitcher, stitcher.pictureHeight > 0 else { return nil }
            return Self.image(stitcher.picture(), width: stitcher.width, height: stitcher.pictureHeight)
        }
    }

    /// Stops, keeping nothing.
    func cancel() async {
        try? await stream?.stopCapture()
        stream = nil
        queue.sync { stitcher = nil }
    }

    /// BGRA rows as an image, in the display's colors.
    private static func image(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.displayP3)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Frames, on `queue`

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid, stitcher != nil,
              let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let image = buffer.imageBuffer else { return }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image), CVPixelBufferGetWidth(image) == stitcher?.width,
              CVPixelBufferGetHeight(image) == stitcher?.height else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(image)
        let step = stitcher!.add(UnsafeRawBufferPointer(start: base, count: bytesPerRow * CVPixelBufferGetHeight(image)), bytesPerRow: bytesPerRow)
        // Only what changes the panel goes to the main thread.
        guard step != .unmoved || lastStep == .lost else { return }
        lastStep = step
        let height = stitcher!.pictureHeight, lost = step == .lost, full = stitcher!.isFull
        guard let progress = onProgress else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { progress(height, lost, full) } }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard let interrupted = onInterrupted else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { interrupted() } }
    }
}
