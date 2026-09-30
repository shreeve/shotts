import AVFoundation
import ShottsCore
import Testing
@testable import ShottsUI

/// A recording as the recorder leaves one, made without a screen: HEVC frames of changing
/// grays at `times`, the last lasting until `end`, a tone as the Mac's sound, and another in a
/// microphone file of its own.
/// The recording the window tests open.
func testRecording(width: Int = 320, height: Int = 200) async throws -> Recording { try await makeRecording(width: width, height: height) }

private func makeRecording(width: Int = 320, height: Int = 200, times: [Double] = [0, 0.1, 0.25], end: Double = 1,
                           systemSound: Bool = true, microphone: Bool = true) async throws -> Recording {
    let folder = try Recording.makeFolder()
    let movie = folder.appendingPathComponent("Recording.mov")
    let writer = try AVAssetWriter(outputURL: movie, fileType: .mov)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
    // As the recorder's are: written as they come, without waiting to interleave, since the
    // helper writes all its frames before its sound.
    video.expectsMediaDataInRealTime = true
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
    writer.add(video)
    var sound: AVAssetWriterInput?
    if systemSound {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        sound = input
    }
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for (i, time) in times.enumerated() {
        while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        #expect(adaptor.append(try grayFrame(width, height, level: UInt8((40 + i * 60) % 256)), withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)))
    }
    video.markAsFinished()
    if let sound {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        var start = 0
        while Double(start) < end * 48_000 {
            while !sound.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            #expect(sound.append(try tone(format, frames: 4800, from: start)))
            start += 4800
        }
        sound.markAsFinished()
    }
    writer.endSession(atSourceTime: CMTime(seconds: end, preferredTimescale: 600))
    await writer.finishWriting()
    #expect(writer.status == .completed)

    var microphoneURL: URL?
    if microphone {
        let url = folder.appendingPathComponent("Microphone.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1])
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(end * 48_000))!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = 0.2 * sin(Float(i) * 0.05) }
        try file.write(from: buffer)
        microphoneURL = url
    }
    return Recording(folder: folder, movie: movie, microphone: microphoneURL, width: width, height: height, scale: 2, started: .now)
}

private func grayFrame(_ width: Int, _ height: Int, level: UInt8) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
    let image = try #require(buffer)
    CVPixelBufferLockBaseAddress(image, [])
    memset(CVPixelBufferGetBaseAddress(image), Int32(level), CVPixelBufferGetBytesPerRow(image) * height)
    CVPixelBufferUnlockBaseAddress(image, [])
    return image
}

private func tone(_ format: AVAudioFormat, frames: Int, from start: Int) throws -> CMSampleBuffer {
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    pcm.frameLength = pcm.frameCapacity
    for c in 0..<Int(format.channelCount) {
        for i in 0..<frames { pcm.floatChannelData![c][i] = 0.2 * sin(Float(start + i) * 0.03) }
    }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                    presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: 48_000), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                         formatDescription: format.formatDescription, sampleCount: frames, sampleTimingEntryCount: 1,
                         sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
    let buffer = try #require(sample)
    #expect(CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                           flags: 0, bufferList: pcm.audioBufferList) == noErr)
    return buffer
}

/// The top-level boxes of an MP4, in order.
private func boxes(_ data: Data) -> [String] {
    var names: [String] = [], i = 0
    while i + 8 <= data.count {
        let size = data[i..<(i + 4)].reduce(0) { $0 << 8 | Int($1) }
        names.append(String(decoding: data[(i + 4)..<(i + 8)], as: UTF8.self))
        guard size >= 8 else { break }
        i += size
    }
    return names
}

private func videoFrames(_ asset: AVAsset) async throws -> Int {
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    reader.startReading()
    var count = 0
    while let sample = output.copyNextSampleBuffer() { count += sample.numSamples }
    return count
}

/// A GIF's size, whether it loops, and its frames' delays.
private func gifSummary(_ data: Data) -> (width: Int, height: Int, loops: Bool, delays: [Int]) {
    let b = [UInt8](data)
    var i = 13 + (b[10] & 0x80 != 0 ? 3 << ((Int(b[10]) & 7) + 1) : 0)
    var loops = false, delays: [Int] = [], delay = 0
    func skipBlocks() -> [UInt8] {
        var body: [UInt8] = []
        while i < b.count, b[i] != 0 { body += b[(i + 1)..<(i + 1 + Int(b[i]))]; i += Int(b[i]) + 1 }
        i += 1
        return body
    }
    while i < b.count {
        switch b[i] {
        case 0x21:
            let label = b[i + 1]
            i += 2
            let body = skipBlocks()
            if label == 0xFF, String(decoding: body.prefix(11), as: UTF8.self) == "NETSCAPE2.0" { loops = true }
            if label == 0xF9 { delay = Int(body[1]) | Int(body[2]) << 8 }
        case 0x2C:
            i += 11 // descriptor and minimum code size
            _ = skipBlocks()
            delays.append(delay)
        default:
            i = b.count
        }
    }
    return (Int(b[6]) | Int(b[7]) << 8, Int(b[8]) | Int(b[9]) << 8, loops, delays)
}

@MainActor @Suite struct RecordingExportTests {
    @Test func aRecordingSaysWhatItHolds() async throws {
        let recording = try await makeRecording()
        defer { try? FileManager.default.removeItem(at: recording.folder) }
        let contents = try await RecordingExport.contents(of: recording)
        #expect(abs(contents.duration - 1) < 0.05)
        #expect(contents.hasSystemSound && contents.hasMicrophone)
        let silent = try await makeRecording(systemSound: false, microphone: false)
        defer { try? FileManager.default.removeItem(at: silent.folder) }
        let quiet = try await RecordingExport.contents(of: silent)
        #expect(!quiet.hasSystemSound && !quiet.hasMicrophone)
    }

    /// An MP4 plays nearly everywhere: H.264 at the size asked for, one sound track mixing
    /// what was chosen, the index before the media so previews start at once, and the frames
    /// the rate keeps.
    @Test func mp4IsH264AtTheSizeAndRateAskedFor() async throws {
        let recording = try await makeRecording()
        defer { try? FileManager.default.removeItem(at: recording.folder) }
        let url = recording.folder.appendingPathComponent("out.mp4")
        try await RecordingExport.write(recording, settings: RecordingSettings(format: .mp4, width: 160, frameRate: 30, sound: .both), to: url)

        let asset = AVURLAsset(url: url)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let format = try #require(try await video.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
        #expect(try await video.load(.naturalSize) == CGSize(width: 160, height: 100))
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(abs(try await asset.load(.duration).seconds - 1) < 0.05)
        #expect(try await videoFrames(asset) == 3)
        let order = boxes(try Data(contentsOf: url))
        #expect(try #require(order.firstIndex(of: "moov")) < (try #require(order.firstIndex(of: "mdat"))))
    }

    @Test func mp4WithoutSoundHasNoSoundTrack() async throws {
        let recording = try await makeRecording()
        defer { try? FileManager.default.removeItem(at: recording.folder) }
        let url = recording.folder.appendingPathComponent("out.mp4")
        try await RecordingExport.write(recording, settings: RecordingSettings(format: .mp4, width: 320, frameRate: 60, sound: .none), to: url)
        #expect(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).isEmpty)
    }

    /// A GIF loops, at the size asked for, with a frame for each change the rate keeps and
    /// delays that add up to the recording's length.
    @Test func gifLoopsWithTheRecordingsTiming() async throws {
        let recording = try await makeRecording()
        defer { try? FileManager.default.removeItem(at: recording.folder) }
        let url = recording.folder.appendingPathComponent("out.gif")
        try await RecordingExport.write(recording, settings: RecordingSettings(format: .gif, width: 160, frameRate: 10, sound: .both), to: url)
        let gif = gifSummary(try Data(contentsOf: url))
        #expect(gif.width == 160 && gif.height == 100 && gif.loops)
        #expect(gif.delays == [10, 20, 70])
    }

    @Test func aCancelledFileIsLeftOut() async throws {
        let recording = try await makeRecording(width: 1280, height: 720, times: (0..<60).map { Double($0) / 30 }, end: 2)
        defer { try? FileManager.default.removeItem(at: recording.folder) }
        let url = recording.folder.appendingPathComponent("out.gif")
        let task = Task { try await RecordingExport.write(recording, settings: RecordingSettings(format: .gif, width: 1280, frameRate: 30, sound: .none), to: url) }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

