import AVFoundation
import ScreenCaptureKit
import ShottsCore
import ShottsUI

/// Records one area of one display to a `Recording`: ScreenCaptureKit streams the area at its
/// full resolution, up to 60 frames a second and only when it changes, with the pointer and
/// the Mac's sound; the microphone, when on, comes through AVFoundation into a file of its own.
/// Frames are written as they come, HEVC at high quality, so nothing piles up in memory. Every
/// timestamp is measured from the first frame, which is the recording's start, with pauses
/// taken out.
nonisolated final class Recorder: NSObject, @unchecked Sendable {
    /// Where sample buffers arrive and are written, one at a time.
    private let queue = DispatchQueue(label: "Shotts recording")
    private var stream: SCStream?
    private var capture: AVCaptureSession?
    private var movie: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var sound: AVAssetWriterInput?
    private var voice: (writer: AVAssetWriter, input: AVAssetWriterInput)?
    /// The clock the microphone's times are on, which need not be the screen's.
    private var voiceClock: CMClock?
    /// The first frame's time, once it comes: everything is measured from it.
    private var start: CMTime?
    /// The pauses, in seconds from the first frame.
    private var pauses = PauseClock()
    /// The latest frame that came while paused, shown once recording resumes: the screen may
    /// not change again for a while, and the frame before the pause is no longer what it shows.
    private var frameWhilePaused: CMSampleBuffer?
    /// Where the last frame written went, so a frame is never written before it.
    private var lastFrame = -1.0
    private var recording: Recording?
    /// Called on the main thread when the stream stops by itself, as when its display goes.
    var onInterrupted: (@MainActor () -> Void)?

    /// Starts recording `rect` (points from the top-left of the display `id`, which has `scale`
    /// pixels a point), leaving out Shotts' windows above ordinary ones (the outline, the panel,
    /// the menu bar item) and those numbered `excluded`, but for those numbered `kept` (what is
    /// drawn on the area).
    func start(display id: CGDirectDisplayID, scale: CGFloat, rect: CGRect, excluding excluded: Set<Int>, keeping kept: Set<Int>,
               microphone: Bool) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw ScreenCapture.Failure.noDisplay }
        let me = ProcessInfo.processInfo.processIdentifier
        let left = content.windows.filter {
            let number = Int($0.windowID)
            return !kept.contains(number) && (excluded.contains(number) || ($0.owningApplication?.processID == me && $0.windowLayer != 0))
        }
        let size = RecordingRule.recordedSize(points: rect.size, scale: scale)

        let folder = try Recording.makeFolder()
        let movieURL = folder.appendingPathComponent("Recording.mov")
        let voiceURL = microphone ? folder.appendingPathComponent("Microphone.m4a") : nil
        recording = Recording(folder: folder, movie: movieURL, microphone: voiceURL, width: size.width, height: size.height,
                              scale: scale, started: .now)

        let movie = try AVAssetWriter(outputURL: movieURL, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                // Near-lossless: every file made later starts from this.
                AVVideoQualityKey: 0.9,
                AVVideoExpectedSourceFrameRateKey: RecordingRule.recordedFrameRate,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        movie.add(video)
        let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000,
        ])
        sound.expectsMediaDataInRealTime = true
        movie.add(sound)
        guard movie.startWriting() else { throw movie.error ?? ScreenCapture.Failure.noDisplay }
        queue.sync {
            self.movie = movie
            self.video = video
            self.sound = sound
        }

        if let voiceURL { try startMicrophone(to: voiceURL) }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rect
        configuration.width = size.width
        configuration.height = size.height
        configuration.scalesToFit = false
        configuration.captureResolution = .best
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = true
        configuration.ignoreShadowsDisplay = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(RecordingRule.recordedFrameRate))
        configuration.queueDepth = 8
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: left), configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    private func startMicrophone(to url: URL) throws {
        guard let device = AVCaptureDevice.default(for: .audio) else { throw Failure.noMicrophone }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw Failure.noMicrophone }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        // One channel of plain samples, whatever the device gives.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw Failure.noMicrophone }
        session.addOutput(output)
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let voice = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000,
        ])
        voice.expectsMediaDataInRealTime = true
        writer.add(voice)
        guard writer.startWriting() else { throw writer.error ?? Failure.noMicrophone }
        queue.sync {
            self.voice = (writer, voice)
            voiceClock = session.synchronizationClock
        }
        capture = session
        session.startRunning()
    }

    enum Failure: LocalizedError {
        case noMicrophone
        case nothingRecorded

        var errorDescription: String? {
            switch self {
            case .noMicrophone: "The microphone could not be used."
            case .nothingRecorded: "Nothing was recorded."
            }
        }
    }

    /// How long it has been recording, from its first frame, not counting pauses.
    var elapsed: TimeInterval {
        queue.sync { now().map { pauses.elapsed(at: $0) } ?? 0 }
    }

    var isPaused: Bool { queue.sync { pauses.isPaused } }

    /// Seconds since the first frame, once it has come.
    private func now() -> Double? {
        start.map { (CMClockGetTime(CMClockGetHostTimeClock()) - $0).seconds }
    }

    /// Stops taking frames and sound until `resume`; the recording goes straight on from here.
    func pause() {
        queue.sync {
            guard let now = now() else { return }
            pauses.pause(at: now)
        }
    }

    func resume() {
        queue.sync {
            guard let now = now(), pauses.isPaused else { return }
            pauses.resume(at: now)
            if let frame = frameWhilePaused {
                frameWhilePaused = nil
                append(frame, to: video, at: pauses.elapsed(at: now))
            }
        }
    }

    /// Stops, and finishes the files: the last frame lasts until now.
    func stop() async throws -> Recording {
        try? await stream?.stopCapture()
        stream = nil
        capture?.stopRunning()
        capture = nil
        let (writers, end) = queue.sync { () -> ([AVAssetWriter], CMTime?) in
            let end = now().map { CMTime(seconds: pauses.elapsed(at: $0), preferredTimescale: 1_000_000_000) }
            video?.markAsFinished()
            sound?.markAsFinished()
            voice?.input.markAsFinished()
            let writers = [movie, voice?.writer].compactMap { $0 }
            movie = nil; video = nil; sound = nil; voice = nil
            return (writers, end)
        }
        guard let recording else { throw Failure.nothingRecorded }
        guard let end, end > .zero else {
            writers.forEach { $0.cancelWriting() }
            Recording.removeFolder(recording.folder)
            throw Failure.nothingRecorded
        }
        for writer in writers {
            writer.endSession(atSourceTime: end)
            await writer.finishWriting()
        }
        guard let failed = writers.first(where: { $0.status != .completed }) else { return recording }
        Recording.removeFolder(recording.folder)
        throw failed.error ?? Failure.nothingRecorded
    }

    // MARK: - Samples, on `queue`

    /// A sample buffer moved to the recording's own time, from its first frame: `by` is
    /// subtracted from every time in it.
    private func retimed(_ buffer: CMSampleBuffer, by start: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - start
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = timing[i].decodeTimeStamp - start }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }

    /// Appends a buffer whose times are on `clock` (the host's, as the screen's are, unless
    /// given), at its place in the recording: measured from the first frame with the pauses
    /// taken out, or `at` seconds when given. Anything from before the first frame, or from
    /// within a pause, is dropped; a frame from within a pause is kept aside for the resume.
    private func append(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput?, clock: CMClock? = nil, at forced: Double? = nil) {
        guard let start, let input else { return }
        let time = buffer.presentationTimeStamp
        let host = clock.map { CMSyncConvertTime(time, from: $0, to: CMClockGetHostTimeClock()) } ?? time
        guard host >= start else { return }
        guard let place = forced ?? pauses.recorded((host - start).seconds) else {
            if input === video { frameWhilePaused = buffer }
            return
        }
        if input === video {
            guard place > lastFrame else { return }
            lastFrame = place
        }
        guard input.isReadyForMoreMediaData,
              let moved = retimed(buffer, by: time - CMTime(seconds: place, preferredTimescale: 1_000_000_000)) else { return }
        input.append(moved)
    }
}

extension Recorder: SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid else { return }
        switch type {
        case .screen:
            // Only frames with a picture: when nothing changes the stream says so without one,
            // and the frame before goes on showing.
            guard let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
                  let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete, buffer.imageBuffer != nil
            else { return }
            if start == nil {
                start = buffer.presentationTimeStamp
                movie?.startSession(atSourceTime: .zero)
                voice?.writer.startSession(atSourceTime: .zero)
            }
            append(buffer, to: video)
        case .audio:
            append(buffer, to: sound)
        default:
            break
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        append(buffer, to: voice?.input, clock: voiceClock)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard let interrupted = onInterrupted else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { interrupted() } }
    }
}
