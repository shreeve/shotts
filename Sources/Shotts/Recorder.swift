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
    private var firstFrame: CMTime?
    /// Where each sample goes, in seconds from the first frame (Core's `RecordingTimeline`).
    private var timeline = RecordingTimeline()
    /// The latest frame that came while paused, written when recording resumes: the screen may
    /// not change again for a while, and the frame before the pause is no longer what it shows.
    private var heldFrame: CMSampleBuffer?
    /// A frame the writer was not ready for, and its place, offered again with the next sample
    /// and at the stop: the screen sends no frame until it changes again.
    private var unwritten: (buffer: CMSampleBuffer, place: Double)?
    private var recording: Recording?
    /// Called on the main thread when the stream stops by itself, as when its display goes. Set
    /// before `start`, like everything outside `queue`: `start`, `pause`, `resume`, and `stop`
    /// are called one at a time, from the main actor.
    var onInterrupted: (@MainActor () -> Void)?

    /// Starts recording `rect` (points from the top-left of the display `id`, which has `scale`
    /// pixels a point), leaving out Shotts' windows above ordinary ones (the outline, the panel,
    /// the menu bar item) and those numbered `excluded`, but for those numbered `kept` (what is
    /// drawn on the area). Without `sound`, the Mac's sound is not recorded.
    func start(display id: CGDirectDisplayID, scale: CGFloat, rect: CGRect, excluding excluded: Set<Int>, keeping kept: Set<Int>,
               microphone: Bool, sound: Bool = true) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw ScreenCapture.Failure.noDisplay }
        let me = ProcessInfo.processInfo.processIdentifier
        let left = content.windows.filter {
            let number = Int($0.windowID)
            return !kept.contains(number) && (excluded.contains(number) || ($0.owningApplication?.processID == me && $0.windowLayer != 0))
        }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rect
        configuration.scalesToFit = false
        configuration.ignoreShadowsDisplay = false
        try await begin(SCContentFilter(display: display, excludingWindows: left), configuration,
                        size: RecordingRule.recordedSize(points: rect.size, scale: scale), scale: scale, microphone: microphone, sound: sound)
    }

    /// Starts recording one window on its own, wherever it goes and whatever covers it, without
    /// its shadow, at the scale of the display holding most of it; with `sound`, the sound
    /// ScreenCaptureKit gives for it. A window made bigger than it started is scaled down to fit.
    func start(window id: CGWindowID, microphone: Bool = false, sound: Bool = false) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw ScreenCapture.Failure.noWindow }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.ignoreShadowsSingleWindow = true
        try await begin(filter, configuration, size: RecordingRule.recordedSize(points: filter.contentRect.size, scale: scale), scale: scale,
                        microphone: microphone, sound: sound)
    }

    private func begin(_ filter: SCContentFilter, _ configuration: SCStreamConfiguration, size: (width: Int, height: Int), scale: CGFloat,
                       microphone: Bool, sound wantsSound: Bool) async throws {
        let folder = try Recording.makeFolder()
        let movieURL = folder.appendingPathComponent("Recording.mov")
        let voiceURL = microphone ? folder.appendingPathComponent("Microphone.m4a") : nil
        recording = Recording(folder: folder, movie: movieURL, microphone: voiceURL, width: size.width, height: size.height,
                              scale: scale, started: .now)

        let movie = try AVAssetWriter(outputURL: movieURL, fileType: .mov)
        // Written in fragments, so what was recorded before a full disk still plays and is kept.
        // (After a crash the next launch removes it as a leftover; offering it back is not built.)
        movie.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
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
                // A key frame at least every two seconds, however seldom the screen changes, so
                // the window's playhead and trim find a frame at once.
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        movie.add(video)
        var sound: AVAssetWriterInput?
        if wantsSound {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000,
            ])
            input.expectsMediaDataInRealTime = true
            movie.add(input)
            sound = input
        }
        guard movie.startWriting() else { throw movie.error ?? Failure.notWritten }
        queue.sync {
            self.movie = movie
            self.video = video
            self.sound = sound
        }

        if let voiceURL { try startMicrophone(to: voiceURL) }

        configuration.width = size.width
        configuration.height = size.height
        configuration.captureResolution = .best
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        // The color space the files are tagged with, so players show what was on screen.
        configuration.colorSpaceName = CGColorSpace.itur_709
        configuration.showsCursor = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(RecordingRule.recordedFrameRate))
        configuration.queueDepth = 8
        configuration.capturesAudio = wantsSound
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if wantsSound { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        self.stream = stream
        try await stream.startCapture()
    }

    /// Waits for the first frame, which starts the recording; false if none comes in `seconds`,
    /// as from a window that is hidden or minimized.
    func firstFrame(within seconds: Double) async -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            if queue.sync(execute: { firstFrame != nil }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
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
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
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
        case notWritten
        case nothingRecorded

        var errorDescription: String? {
            switch self {
            case .noMicrophone: "The microphone could not be used."
            case .notWritten: "The recording could not be written."
            case .nothingRecorded: "Nothing was recorded."
            }
        }
    }

    /// How long it has been recording, from its first frame, not counting pauses.
    var elapsed: TimeInterval {
        queue.sync { now().map { timeline.elapsed(at: $0) } ?? 0 }
    }

    var isPaused: Bool { queue.sync { timeline.isPaused } }

    /// Seconds since the first frame, once it has come.
    private func now() -> Double? {
        firstFrame.map { (CMClockGetTime(CMClockGetHostTimeClock()) - $0).seconds }
    }

    /// Stops taking frames and sound until `resume`; the recording goes straight on from here.
    func pause() {
        queue.sync {
            guard let now = now() else { return }
            timeline.pause(at: now)
        }
    }

    func resume() {
        queue.sync {
            let frame = heldFrame
            heldFrame = nil
            guard let now = now(), let place = timeline.resume(at: now), let frame else { return }
            writeFrame(frame, at: place)
        }
    }

    /// Stops, and finishes the files: the last frame lasts until now. The video is what makes a
    /// recording: if only the microphone's file fails, the recording is kept without it.
    func stop() async throws -> Recording {
        try? await stream?.stopCapture()
        stream = nil
        capture?.stopRunning()
        capture = nil
        let (movie, voice, end) = queue.sync { () -> (AVAssetWriter?, AVAssetWriter?, CMTime?) in
            // A frame still waiting gets one last chance before the end.
            if let (buffer, place) = unwritten {
                for _ in 0..<50 where video?.isReadyForMoreMediaData == false { usleep(10_000) }
                writeFrame(buffer, at: place)
            }
            unwritten = nil
            heldFrame = nil
            let end = now().map { CMTime(seconds: timeline.elapsed(at: $0), preferredTimescale: 1_000_000_000) }
            video?.markAsFinished()
            sound?.markAsFinished()
            self.voice?.input.markAsFinished()
            defer { self.movie = nil; video = nil; sound = nil; self.voice = nil }
            return (self.movie, self.voice?.writer, end)
        }
        guard var recording else { throw Failure.nothingRecorded }
        guard let movie, let end, end > .zero else {
            movie?.cancelWriting()
            voice?.cancelWriting()
            Recording.removeFolder(recording.folder)
            throw Failure.nothingRecorded
        }
        movie.endSession(atSourceTime: end)
        await movie.finishWriting()
        guard movie.status == .completed else {
            voice?.cancelWriting()
            // A disk that filled up leaves the fragments written before it, which still play.
            if let video = try? await AVURLAsset(url: recording.movie).loadTracks(withMediaType: .video).first,
               let range = try? await video.load(.timeRange), range.duration > .zero {
                return recording.withoutMicrophone()
            }
            Recording.removeFolder(recording.folder)
            throw movie.error ?? Failure.notWritten
        }
        if let voice {
            voice.endSession(atSourceTime: end)
            await voice.finishWriting()
            if voice.status != .completed, let url = recording.microphone {
                try? FileManager.default.removeItem(at: url)
                recording = recording.withoutMicrophone()
            }
        }
        return recording
    }

    // MARK: - Samples, on `queue`

    /// A sample buffer moved to the recording's own time: every time in it shifted by `by`.
    private func retimed(_ buffer: CMSampleBuffer, by shift: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - shift
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = timing[i].decodeTimeStamp - shift }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }

    /// Seconds after the first frame of a sample on `clock` (the host's, as the screen's are,
    /// unless given); nil before the first frame.
    private func time(of buffer: CMSampleBuffer, clock: CMClock? = nil) -> Double? {
        guard let firstFrame else { return nil }
        let pts = buffer.presentationTimeStamp
        let host = clock.map { CMSyncConvertTime(pts, from: $0, to: CMClockGetHostTimeClock()) } ?? pts
        return host >= firstFrame ? (host - firstFrame).seconds : nil
    }

    /// Appends `buffer` to `input` with its first sample at `place` seconds, if the writer will
    /// take it now.
    @discardableResult
    private func append(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput?, at place: Double) -> Bool {
        guard let input, input.isReadyForMoreMediaData,
              let moved = retimed(buffer, by: buffer.presentationTimeStamp - CMTime(seconds: place, preferredTimescale: 1_000_000_000))
        else { return false }
        return input.append(moved)
    }

    /// A frame at `place`, or kept to be offered again when the writer is busy.
    private func writeFrame(_ buffer: CMSampleBuffer, at place: Double) {
        if append(buffer, to: video, at: place) {
            timeline.wrote(frameAt: place)
            unwritten = nil
        } else {
            unwritten = (buffer, place)
        }
    }

    private func received(frame buffer: CMSampleBuffer) {
        if firstFrame == nil {
            firstFrame = buffer.presentationTimeStamp
            movie?.startSession(atSourceTime: .zero)
            voice?.writer.startSession(atSourceTime: .zero)
        }
        guard let time = time(of: buffer) else { return }
        switch timeline.frame(at: time) {
        case let .write(place): writeFrame(buffer, at: place)
        case .hold: heldFrame = buffer
        case .drop: break
        }
    }

    /// Offers the waiting frame again, before anything newer.
    private func retryUnwritten() {
        guard let (buffer, place) = unwritten else { return }
        writeFrame(buffer, at: place)
    }

    private func received(sound buffer: CMSampleBuffer, to input: AVAssetWriterInput?, clock: CMClock? = nil) {
        guard let time = time(of: buffer, clock: clock), let place = timeline.sound(at: time) else { return }
        append(buffer, to: input, at: place)
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
            else { retryUnwritten(); return }
            // A newer frame supersedes one still waiting.
            unwritten = nil
            received(frame: buffer)
        case .audio:
            retryUnwritten()
            received(sound: buffer, to: sound)
        default:
            break
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        retryUnwritten()
        received(sound: buffer, to: voice?.input, clock: voiceClock)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard let interrupted = onInterrupted else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { interrupted() } }
    }
}
