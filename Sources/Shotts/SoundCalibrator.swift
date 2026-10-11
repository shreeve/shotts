import AVFoundation
import CoreAudio
import os
import ScreenCaptureKit
import ShottsCore

/// Measures how much quieter ScreenCaptureKit hands over the Mac's sound than it played, on the
/// output device in use (Core's `SoundCalibration` explains why it does). It plays a quiet tone
/// and captures the sound of no app but Shotts while it plays, measuring at the tone's pitch
/// alone, and believes only a steady reading, so what else plays cannot fool it. Each device is
/// measured once and again a month later (`SoundCalibration.remembered`), so most recordings
/// play no tone and finish without waiting for one. It runs only beside a recording the user
/// started, which already captures: a measurement of its own would show macOS's capture
/// indicator when nothing was asked for.
nonisolated final class SoundCalibrator: NSObject, SCStreamOutput, @unchecked Sendable {
    private let queue = DispatchQueue(label: "Shotts sound calibration")
    /// The first channel of what came back, on `queue`.
    private var heard: [Float] = []

    private static let savedKey = "recording.soundCalibration"
    private static let sampleRate = 48_000.0

    /// The gain for the output device in use now: its measurement while that is believed, else
    /// one taken now, else its last (should another sound spoil the new one); nil when there is
    /// none. Cancelled, as when the recording never started, it plays no tone.
    static func gain() async -> Double? {
        let device = outputDeviceID()
        let last = device.flatMap { saved()[$0] }
        if let last, SoundCalibration.isFresh(last.measured, at: .now) { return last.gain }
        if let measured = await SoundCalibrator().measure() {
            if let device { save(measured, for: device) }
            return measured
        }
        return last?.gain
    }

    private func measure() async -> Double? {
        // ScreenCaptureKit lists every app but the one asking, so Shotts' own sound is what is
        // left with all of them taken out (with any background process's, which measuring at
        // the tone's pitch alone ignores).
        guard !Task.isCancelled, let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let display = content.displays.first else { return nil }
        let filter = SCContentFilter(display: display, excludingApplications: content.applications, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = false
        configuration.sampleRate = Int(Self.sampleRate)
        configuration.channelCount = 2
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            return nil
        }
        // Let the capture settle, play the tone, then let its tail arrive; a recording that has
        // ended meanwhile plays none.
        try? await Task.sleep(for: .milliseconds(150))
        var played = false
        if !Task.isCancelled { played = await Self.play(Self.tone(seconds: 0.8)) }
        if played { try? await Task.sleep(for: .milliseconds(300)) }
        try? await stream.stopCapture()
        let samples = queue.sync { heard }
        guard played, let level = SoundCalibration.level(of: samples) else { return nil }
        return SoundCalibration.gain(played: SoundCalibration.toneAmplitude / 2.squareRoot(), heard: level)
    }

    /// Plays `tone`, returning once it has been played back (not merely handed to the device,
    /// which a slow output such as Bluetooth plays well after), or after `limit` should it never
    /// be, as when the output device changes and the engine stops. False if it could not play.
    private static func play(_ tone: AVAudioPCMBuffer, limit: Duration = .seconds(3)) async -> Bool {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: tone.format)
        defer { engine.stop() }
        guard (try? engine.start()) != nil else { return false }
        let waiting = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
        await withCheckedContinuation { continuation in
            waiting.withLock { $0 = continuation }
            // Whichever comes first, the tone played back or the limit, resumes; the other finds nothing.
            let done: @Sendable () -> Void = { waiting.withLock { $0.take() }?.resume() }
            player.scheduleBuffer(tone, completionCallbackType: .dataPlayedBack) { _ in done() }
            player.play()
            Task { try? await Task.sleep(for: limit); done() }
        }
        return true
    }

    /// A 200 Hz sine at `SoundCalibration.toneDecibels`, faded in and out so it never clicks.
    private static func tone(seconds: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let count = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        let fade = Int(sampleRate / 10)
        for i in 0..<Int(count) {
            let envelope = min(1, Double(min(i, Int(count) - i)) / Double(fade))
            let value = Float(SoundCalibration.toneAmplitude * envelope * sin(2 * .pi * SoundCalibration.toneFrequency * Double(i) / sampleRate))
            buffer.floatChannelData![0][i] = value
            buffer.floatChannelData![1][i] = value
        }
        return buffer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, buffer.isValid,
              let format = buffer.formatDescription?.audioStreamBasicDescription, format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else { return }
        // The first channel: non-interleaved, it is the first buffer; interleaved, every
        // channel-count-th sample.
        try? buffer.withAudioBufferList { list, _ in
            guard let first = list.first, let data = first.mData else { return }
            let floats = data.assumingMemoryBound(to: Float.self)
            let total = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let stride = max(Int(first.mNumberChannels), 1)
            heard.append(contentsOf: Swift.stride(from: 0, to: total, by: stride).map { floats[$0] })
        }
    }

    // MARK: - The output device, and its last measurement

    /// The unique id of the device sound goes to now.
    private static func outputDeviceID() -> String? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    /// Each device's measurement and when it was taken, by the device's unique id.
    private static func saved() -> [String: (gain: Double, measured: Date)] {
        (UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]).compactMapValues { value in
            guard let entry = value as? [String: Any], let gain = entry["gain"] as? Double, let measured = entry["measured"] as? Date else { return nil }
            return (gain, measured)
        }
    }

    /// Keeps `gain` for `device`, dropping the measurements no longer believed, so devices used
    /// once (a borrowed headset, an AirPlay speaker) do not stay forever.
    private static func save(_ gain: Double, for device: String) {
        var all = saved().filter { SoundCalibration.isFresh($0.value.measured, at: .now) }
        all[device] = (gain, .now)
        UserDefaults.standard.set(all.mapValues { ["gain": $0.gain, "measured": $0.measured] }, forKey: savedKey)
    }
}
