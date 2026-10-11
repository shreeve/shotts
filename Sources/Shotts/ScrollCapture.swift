import AppKit
import ScreenCaptureKit
import ShottsCore

/// A scrolling capture of one area of one display: ScreenCaptureKit streams the area, leaving
/// out Shotts' own windows (the outline, the panel, the menu bar item), and each frame goes to
/// Core's `ScrollStitcher` on a queue of its own, which keeps only the picture it builds. The
/// pointer is not in it. Streaming stops at `finish` or `cancel`, and the frames go with it.
///
/// The stream is started and stopped on the main actor; only the frames are handled off it.
final class ScrollCapture {
    /// The picture's pixels per point.
    let scale: CGFloat
    /// Called after each frame that changes what the panel shows: the height so far, whether
    /// the frame was not matched, and whether the picture is full.
    var onProgress: ((Int, Bool, Bool) -> Void)?
    /// Called when the stream stops by itself, as when its display goes.
    var onInterrupted: (() -> Void)?
    private let frames = Stitching()
    private var stream: SCStream?
    /// Finished or cancelled, perhaps before the stream had started: a start that finishes
    /// afterwards stops it at once, so no stream outlives the capture.
    private var stopped = false

    init(scale: CGFloat) {
        self.scale = scale
        frames.progress = { [weak self] height, lost, full in self?.onProgress?(height, lost, full) }
        frames.stopped = { [weak self] in
            guard let self, !stopped else { return }
            onInterrupted?()
        }
    }

    /// Starts streaming `rect` (points from the top-left of the display `id`), leaving out the
    /// windows numbered `excluded` and Shotts' own above ordinary ones. Once finished or
    /// cancelled, it starts nothing and throws nothing.
    func start(display id: CGDirectDisplayID, rect: CGRect, excluding excluded: Set<Int>) async throws {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !stopped else { return }
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw ScreenCapture.Failure.noDisplay }
            let me = ProcessInfo.processInfo.processIdentifier
            let left = content.windows.filter {
                excluded.contains(Int($0.windowID)) || ($0.owningApplication?.processID == me && $0.windowLayer != 0)
            }
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = rect
            configuration.width = Int((rect.width * scale).rounded())
            configuration.height = Int((rect.height * scale).rounded())
            configuration.scalesToFit = false
            configuration.captureResolution = .best
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = false
            configuration.ignoreShadowsDisplay = false
            // Up to 60 a second: the less the content moves between frames, the faster a scroll
            // can be and still match. Frames that come while one is being stitched wait or are
            // dropped, so a big area simply runs at the rate it can.
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.queueDepth = 3
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: left), configuration: configuration, delegate: frames)
            try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: frames.queue)
            self.stream = stream
            try await stream.startCapture()
            if stopped { try? await stream.stopCapture() }
        } catch {
            guard stopped else { throw error }
        }
    }

    /// Stops, and makes the picture from what was stitched; nil if no frame came.
    func finish() async -> CGImage? {
        await stop()
        return await frames.end(keeping: true)
    }

    /// Stops, keeping nothing.
    func cancel() async {
        await stop()
        _ = await frames.end(keeping: false)
    }

    private func stop() async {
        stopped = true
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }
}

/// Receives a scrolling capture's frames on its own queue and stitches them. The stitcher is
/// made from the first frame, at that frame's size, in its colors, as a still's are.
private nonisolated final class Stitching: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "Shotts scrolling capture")
    /// Set once, before streaming starts.
    var progress: (@MainActor (Int, Bool, Bool) -> Void)?
    var stopped: (@MainActor () -> Void)?
    // On `queue`.
    private var stitcher: ScrollStitcher?
    private var space: CGColorSpace?
    private var ended = false
    private var lastStep = ScrollStitcher.Step.started

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard let stopped else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { stopped() } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Once full, nothing more is added: no frame is read.
        guard type == .screen, !ended, stitcher?.isFull != true, buffer.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let image = buffer.imageBuffer, CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        if stitcher == nil {
            stitcher = ScrollStitcher(width: width, height: height)
            space = CVImageBufferGetColorSpace(image)?.takeUnretainedValue()
        }
        guard let stitcher, stitcher.width == width, stitcher.height == height, let base = CVPixelBufferGetBaseAddress(image) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(image)
        let step = stitcher.add(UnsafeRawBufferPointer(start: base, count: bytesPerRow * height), bytesPerRow: bytesPerRow)
        // Only what changes the panel goes to the main thread: a still frame only after one not
        // matched. `.full` comes once, as no frame is read after it.
        guard step != .unmoved || lastStep == .lost else { return }
        lastStep = step
        let pictureHeight = stitcher.pictureHeight, lost = step == .lost, full = stitcher.isFull
        guard let progress else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { progress(pictureHeight, lost, full) } }
    }

    /// Ends stitching, after any frame being stitched, without holding up the caller's thread:
    /// the picture as an image over the stitched pixels, `keeping` it; nil if no frame came.
    func end(keeping: Bool) async -> CGImage? {
        await withCheckedContinuation { done in
            queue.async { [self] in
                ended = true
                let picture = keeping ? stitcher.flatMap { Self.image(of: $0, in: space) } : nil
                stitcher = nil
                done.resume(returning: picture)
            }
        }
    }

    /// The stitcher's picture as an image that owns its pixels and frees them when it goes.
    private static func image(of stitcher: ScrollStitcher, in space: CGColorSpace?) -> CGImage? {
        guard let pixels = stitcher.takePicture() else { return nil }
        guard let provider = CGDataProvider(dataInfo: nil, data: pixels.baseAddress!, size: pixels.count, releaseData: { _, data, _ in
            UnsafeMutableRawPointer(mutating: data).deallocate()
        }) else {
            pixels.deallocate()
            return nil
        }
        return CGImage(width: stitcher.width, height: stitcher.pictureHeight, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stitcher.width * 4,
                       space: space ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
