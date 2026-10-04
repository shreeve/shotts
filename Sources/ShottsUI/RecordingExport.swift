import AVFoundation
import CoreVideo
import ShottsCore
import VideoToolbox

/// One recording as Shotts keeps it while its window is open: the area's video, at its full
/// size and up to 60 frames a second, with the Mac's sound on a track of its own; and the
/// microphone, when it was on, in a file of its own, so the two can be kept or left out apart.
/// Both start at the recording's first frame. Everything is in one temporary folder, which
/// goes when the window closes; the files made from the recording go there too.
public nonisolated struct Recording: Sendable {
    public let folder: URL
    /// HEVC video, and the Mac's sound if any came.
    public let movie: URL
    /// AAC, when the microphone was on.
    public let microphone: URL?
    /// In pixels.
    public let width: Int
    public let height: Int
    /// Pixels per point on the display it was recorded from.
    public let scale: Double
    public let started: Date

    public init(folder: URL, movie: URL, microphone: URL?, width: Int, height: Int, scale: Double, started: Date) {
        self.folder = folder
        self.movie = movie
        self.microphone = microphone
        self.width = width
        self.height = height
        self.scale = scale
        self.started = started
    }

    /// The same recording with no microphone, for when its file could not be finished.
    public func withoutMicrophone() -> Recording {
        Recording(folder: folder, movie: movie, microphone: nil, width: width, height: height, scale: scale, started: started)
    }

    /// Where recordings are kept, each in a folder of its own. Nothing in it outlives its
    /// window; at launch, what a crash left is removed (`removeLeftovers`).
    public static let parentFolder = FileManager.default.temporaryDirectory.appendingPathComponent("Shotts Recordings", isDirectory: true)

    /// The folders this process is using, each held by a lock on a file in it, kept open until
    /// the folder goes. Another Shotts starting, which removes leftovers, leaves a held folder
    /// alone; a crash lets go of the lock, so a crash's folders are taken.
    nonisolated(unsafe) private static var held: [URL: Int32] = [:]
    private static let heldLock = NSLock()
    private static let lockName = ".in-use"

    /// A new, empty folder for one recording, held until `removeFolder`, readable by its user
    /// alone: it holds the screen and the microphone as they were recorded.
    public static func makeFolder() throws -> URL {
        let folder = parentFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let private0700: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try FileManager.default.createDirectory(at: parentFolder, withIntermediateDirectories: true, attributes: private0700)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: private0700)
        let fd = open(folder.appendingPathComponent(lockName).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 {
            heldLock.withLock { held[folder] = fd }
        } else if fd >= 0 {
            close(fd)
        }
        return folder
    }

    /// Lets go of a folder and deletes it, with everything made in it.
    public static func removeFolder(_ folder: URL) {
        if let fd = heldLock.withLock({ held.removeValue(forKey: folder) }) { close(fd) }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Removes the folders no running Shotts holds: what a crash left behind. A folder with no
    /// lock yet may be one another Shotts has just made and is about to lock, so it is left
    /// for a minute.
    public static func removeLeftovers() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: parentFolder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in folders {
            let fd = open(folder.appendingPathComponent(lockName).path, O_RDWR | O_CLOEXEC)
            if fd >= 0 {
                let free = flock(fd, LOCK_EX | LOCK_NB) == 0
                close(fd)
                guard free else { continue }
            } else if let made = try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate, made.timeIntervalSinceNow > -60 {
                continue
            }
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

/// Makes the files a recording is saved, copied, and dragged as: H.264 MP4 or animated GIF, at
/// the size, frame rate, and sound the settings say, from the recording kept at full quality.
public nonisolated enum RecordingExport {
    /// What a recording holds.
    public nonisolated struct Contents: Sendable, Equatable {
        public var duration: Double
        public var hasSystemSound: Bool
        public var hasMicrophone: Bool
    }

    public nonisolated enum Failure: LocalizedError {
        case noVideo
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .noVideo: "The recording has no video."
            case let .failed(why): why
            }
        }
    }

    public static func contents(of recording: Recording) async throws -> Contents {
        let movie = AVURLAsset(url: recording.movie)
        guard try await !movie.loadTracks(withMediaType: .video).isEmpty else { throw Failure.noVideo }
        let duration = try await movie.load(.duration).seconds
        let system = try await hasSound(movie)
        var microphone = false
        if let url = recording.microphone { microphone = try await hasSound(AVURLAsset(url: url)) }
        return Contents(duration: duration, hasSystemSound: system, hasMicrophone: microphone)
    }

    /// Whether an asset has a sound track with anything in it: with nothing playing, the Mac's
    /// may come to none.
    private static func hasSound(_ asset: AVAsset) async throws -> Bool {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return false }
        return try await track.load(.timeRange).duration > .zero
    }

    /// Writes the recording to `url` as the settings say. `progress` runs off the main thread,
    /// from 0 to 1. Cancelling the task stops the work and leaves no file. Returns what was
    /// written: its size and how many frames.
    @discardableResult
    public static func write(_ recording: Recording, settings: RecordingSettings, to url: URL,
                             progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Written {
        let movie = AVURLAsset(url: recording.movie)
        guard let video = try await movie.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let whole = try await movie.load(.duration)
        // The part kept, which the file starts at the beginning of.
        let kept = settings.trim.map {
            CMTimeRange(start: CMTime(seconds: $0.start, preferredTimescale: 600), end: min(CMTime(seconds: $0.end, preferredTimescale: 600), whole))
        } ?? CMTimeRange(start: .zero, duration: whole)
        // A track does not keep its asset: the job holds them while it reads.
        var assets: [AVAsset] = [movie]
        var sounds: [(track: AVAssetTrack, range: CMTimeRange)] = []
        if settings.format == .mp4 {
            if settings.sound.includesSystem, let track = try await movie.loadTracks(withMediaType: .audio).first {
                sounds.append((track, try await track.load(.timeRange)))
            }
            if settings.sound.includesMicrophone, let url = recording.microphone {
                let microphone = AVURLAsset(url: url)
                assets.append(microphone)
                if let track = try await microphone.loadTracks(withMediaType: .audio).first {
                    sounds.append((track, try await track.load(.timeRange)))
                }
            }
        }
        let videoRange = try await video.load(.timeRange)
        let size = settings.size(recorded: (recording.width, recording.height))
        let job = Job(assets: assets, video: (video, videoRange), sounds: sounds, kept: kept, size: size, rate: settings.frameRate, to: url, progress: progress)
        try? FileManager.default.removeItem(at: url)
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (done: CheckedContinuation<Written, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let frames = try settings.format == .mp4 ? job.writeMP4() : job.writeGIF()
                            done.resume(returning: Written(width: size.width, height: size.height, frames: frames))
                        } catch {
                            done.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                job.cancel()
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    public nonisolated struct Written: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var frames: Int
    }

    /// One file being made, on a thread of its own: it reads the recording in order and writes
    /// as it goes, holding no more than a frame or two.
    private nonisolated final class Job: @unchecked Sendable {
        let assets: [AVAsset]
        let video: (track: AVAssetTrack, range: CMTimeRange)
        let sounds: [(track: AVAssetTrack, range: CMTimeRange)]
        /// The part of the recording kept, and so the file's length.
        let kept: CMTimeRange
        var duration: CMTime { kept.duration }
        let size: (width: Int, height: Int)
        let rate: Int
        let url: URL
        let progress: @Sendable (Double) -> Void
        private let lock = NSLock()
        private var cancelled = false

        init(assets: [AVAsset], video: (track: AVAssetTrack, range: CMTimeRange), sounds: [(track: AVAssetTrack, range: CMTimeRange)], kept: CMTimeRange, size: (width: Int, height: Int), rate: Int, to url: URL,
             progress: @escaping @Sendable (Double) -> Void) {
            self.assets = assets
            self.video = video
            self.sounds = sounds
            self.kept = kept
            self.size = size
            self.rate = rate
            self.url = url
            self.progress = progress
        }

        func cancel() { lock.withLock { cancelled = true } }

        private func checkCancelled() throws {
            if lock.withLock({ cancelled }) { throw CancellationError() }
        }

        private var seconds: Double { max(duration.seconds, 0.001) }

        /// The kept part of a track that covers `range`.
        private func part(of range: CMTimeRange) -> CMTimeRange {
            let start = max(kept.start, range.start), end = min(kept.end, range.end)
            return end > start ? CMTimeRange(start: start, end: end) : CMTimeRange(start: kept.start, duration: .zero)
        }

        /// The recording's frames at this job's rate, each scaled to this job's size into
        /// `format`, with the time it shows from. A frame is handed on once the next has come,
        /// when it is known whether it lasts until a tick.
        private func frames(in format: OSType, progress span: ClosedRange<Double>, _ body: (CVPixelBuffer, Double) throws -> Void) throws {
            let composition = AVMutableComposition()
            guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw Failure.failed("The recording could not be read.")
            }
            try track.insertTimeRange(part(of: video.range), of: video.track, at: .zero)
            let reader = try AVAssetReader(asset: composition)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: format])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? Failure.failed("The recording could not be read.") }
            defer { reader.cancelReading() }
            let scaler = try Scaler(width: size.width, height: size.height, format: format)
            var held: (image: CVPixelBuffer, time: Double)?
            var reported = -1.0
            func hand(until next: Double) throws {
                guard let (image, time) = held, let tick = FrameSampler.tick(for: time, until: next, rate: rate) else { return }
                try body(try scaler.scale(image), tick)
            }
            while let sample = output.copyNextSampleBuffer() {
                try checkCancelled()
                guard let image = sample.imageBuffer else { continue }
                let time = sample.presentationTimeStamp.seconds
                try hand(until: time)
                held = (image, time)
                // In steps of a hundredth: each goes to the main thread.
                let done = span.lowerBound + (span.upperBound - span.lowerBound) * min(time / seconds, 1)
                if done - reported >= 0.01 {
                    reported = done
                    progress(done)
                }
            }
            if reader.status == .failed { throw reader.error ?? Failure.failed("The recording could not be read.") }
            try hand(until: max(seconds, (held?.time ?? 0) + 0.001))
        }

        // MARK: MP4

        /// Returns how many frames it wrote.
        func writeMP4() throws -> Int {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            // The file's index goes first, so a preview in Messages or Mail plays before the
            // whole file has come.
            writer.shouldOptimizeForNetworkUse = true
            let colors = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
                AVVideoColorPropertiesKey: colors,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: RecordingRule.h264BitRate(width: size.width, height: size.height, frameRate: rate),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                    AVVideoExpectedSourceFrameRateKey: rate,
                    AVVideoMaxKeyFrameIntervalKey: rate * 2,
                ],
            ])
            videoInput.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
            writer.add(videoInput)

            // The sound, one track mixed from those chosen: many players play only a file's first.
            var sound: (reader: AVAssetReader, output: AVAssetReaderAudioMixOutput, input: AVAssetWriterInput)?
            if sounds.contains(where: { part(of: $0.range).duration > .zero }) {
                let composition = AVMutableComposition()
                var tracks: [AVAssetTrack] = []
                for source in sounds where part(of: source.range).duration > .zero {
                    guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                    try track.insertTimeRange(part(of: source.range), of: source.track, at: .zero)
                    tracks.append(track)
                }
                let reader = try AVAssetReader(asset: composition)
                let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                    AVLinearPCMIsBigEndianKey: false,
                ])
                reader.add(output)
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 160_000,
                ])
                input.expectsMediaDataInRealTime = false
                writer.add(input)
                guard reader.startReading() else { throw reader.error ?? Failure.failed("The recording's sound could not be read.") }
                sound = (reader, output, input)
            }
            defer { sound?.reader.cancelReading() }

            guard writer.startWriting() else { throw writer.error ?? Failure.failed("The file could not be written.") }
            // A file given up on part way is cancelled, not left half-written.
            defer { if writer.status == .writing { writer.cancelWriting() } }
            writer.startSession(atSourceTime: .zero)
            let end = duration
            var soundDone = sound == nil
            /// Moves one buffer of sound along, if the writer wants one; the writer takes video
            /// and sound interleaved, so each waits on the other.
            func pumpSound() -> Bool {
                guard !soundDone, let sound, sound.input.isReadyForMoreMediaData else { return false }
                if let buffer = sound.output.copyNextSampleBuffer() {
                    if buffer.presentationTimeStamp < end { sound.input.append(buffer) }
                } else {
                    soundDone = true
                    sound.input.markAsFinished()
                }
                return true
            }
            func waitForWriter(_ input: AVAssetWriterInput) throws {
                while !input.isReadyForMoreMediaData {
                    try checkCancelled()
                    if writer.status == .failed { throw writer.error ?? Failure.failed("The file could not be written.") }
                    if !pumpSound() { usleep(1000) }
                }
            }

            var count = 0
            try frames(in: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, progress: 0...0.98) { image, tick in
                count += 1
                try waitForWriter(videoInput)
                let time = CMTime(value: CMTimeValue((tick * Double(rate)).rounded()), timescale: CMTimeScale(rate))
                guard adaptor.append(image, withPresentationTime: time) else {
                    throw writer.error ?? Failure.failed("The file could not be written.")
                }
            }
            videoInput.markAsFinished()
            while !soundDone {
                try checkCancelled()
                if !pumpSound() { usleep(1000) }
            }
            writer.endSession(atSourceTime: end)
            let finished = DispatchSemaphore(value: 0)
            writer.finishWriting { finished.signal() }
            finished.wait()
            guard writer.status == .completed else { throw writer.error ?? Failure.failed("The file could not be written.") }
            progress(1)
            return count
        }

        // MARK: GIF

        /// Two passes: the first gathers the whole clip's colors for its one palette, the second
        /// writes the frames with it.
        func writeGIF() throws -> Int {
            var colors = PaletteBuilder()
            try frames(in: kCVPixelFormatType_32BGRA, progress: 0...0.3) { image, _ in
                try Self.read(image) { colors.add($0) }
            }
            try checkCancelled()
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw Failure.failed("The file could not be written.") }
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            var pending = Data()
            var failure: Error?
            func write(_ data: Data) {
                pending.append(data)
                guard pending.count >= 1 << 20, failure == nil else { return }
                do { try file.write(contentsOf: pending) } catch { failure = error }
                pending.removeAll(keepingCapacity: true)
            }
            var gif = GIFWriter(width: size.width, height: size.height, palette: colors.palette(), write: write)
            var count = 0
            try frames(in: kCVPixelFormatType_32BGRA, progress: 0.3...0.99) { image, tick in
                count += 1
                try Self.read(image) { gif.add($0, at: tick) }
                if let failure { throw failure }
            }
            gif.finish(at: seconds)
            try file.write(contentsOf: pending)
            if let failure { throw failure }
            progress(1)
            return count
        }

        /// A BGRA buffer's pixels, for the length of `body`.
        private static func read(_ image: CVPixelBuffer, _ body: (BGRAFrame) throws -> Void) throws {
            CVPixelBufferLockBaseAddress(image, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(image) else { throw Failure.failed("The recording could not be read.") }
            try body(BGRAFrame(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image),
                               bytesPerRow: CVPixelBufferGetBytesPerRow(image), base: base))
        }
    }

    /// Scales frames to one size and pixel format in the hardware, averaging when it shrinks
    /// them, so text stays smooth rather than dropping pixels.
    private nonisolated final class Scaler {
        private let session: VTPixelTransferSession
        /// Buffers of the output size, used again once whoever took one lets it go.
        private let pool: CVPixelBufferPool

        init(width: Int, height: Int, format: OSType) throws {
            var session: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == noErr, let session else {
                throw Failure.failed("Frames could not be scaled.")
            }
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DownsamplingMode, value: kVTDownsamplingMode_Average)
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationTransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
            var pool: CVPixelBufferPool?
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
                throw Failure.failed("Frames could not be scaled.")
            }
            self.session = session
            self.pool = pool
        }

        deinit { VTPixelTransferSessionInvalidate(session) }

        /// A buffer from the pool, not one the writer still holds.
        func scale(_ image: CVPixelBuffer) throws -> CVPixelBuffer {
            var out: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out,
                  VTPixelTransferSessionTransferImage(session, from: image, to: out) == noErr
            else { throw Failure.failed("Frames could not be scaled.") }
            return out
        }
    }
}
