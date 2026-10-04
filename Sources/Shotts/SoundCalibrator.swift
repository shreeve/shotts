import AVFoundation
import CoreAudio
import ScreenCaptureKit
import ShottsCore

/// Measures how much quieter ScreenCaptureKit hands over the Mac's sound than it played, on the
/// output device in use (Core's `SoundCalibration` explains why it does). It plays a tone too
/// quiet to hear and captures the sound of no app but Shotts while it plays, measuring at the
/// tone's pitch alone, and believes only a steady reading, so what else plays cannot fool it. It runs only beside a recording the user started, which already captures: a
/// measurement of its own would show macOS's capture indicator when nothing was asked for.
/// Each device's last measurement is kept, for a recording too short to measure in.
nonisolated final class SoundCalibrator: NSObject, SCStreamOutput, @unchecked Sendable {
    private let queue = DispatchQueue(label: "Shotts sound calibration")
    /// The first channel of what came back, on `queue`.
    private var heard: [Float] = []

    private static let savedKey = "recording.soundCalibration"
    private static let sampleRate = 48_000.0

    /// The gain for the output device in use now: measured, or the last measurement on it, or
    /// nil when there is neither.
    static func gain() async -> Double? {
        let device = outputDeviceID()
        if let measured = await SoundCalibrator().measure() {
            if let device { save(measured, for: device) }
            return measured
        }
        return device.flatMap(saved)
    }

    private func measure() async -> Double? {
        // ScreenCaptureKit lists every app but the one asking, so Shotts' own sound is what is
        // left with all of them taken out (with any background process's, which measuring at
        // the tone's pitch alone ignores).
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
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
        let tone = Self.tone(seconds: 0.8)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: tone.format)
        defer { engine.stop() }
        do {
            try engine.start()
        } catch {
            try? await stream.stopCapture()
            return nil
        }
        // Let the capture settle, play the tone through, then let its tail arrive.
        try? await Task.sleep(for: .milliseconds(150))
        player.play()
        // Returns once the tone has been played; its tail then reaches the capture.
        await player.scheduleBuffer(tone)
        try? await Task.sleep(for: .milliseconds(300))
        try? await stream.stopCapture()
        let samples = queue.sync { heard }
        let played = SoundCalibration.toneAmplitude / 2.squareRoot()
        guard let heard = SoundCalibration.level(of: samples) else { return nil }
        return SoundCalibration.gain(played: played, heard: heard)
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

    private static func saved(_ device: String) -> Double? {
        (UserDefaults.standard.dictionary(forKey: savedKey)?[device] as? Double)
    }

    private static func save(_ gain: Double, for device: String) {
        var all = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        all[device] = gain
        UserDefaults.standard.set(all, forKey: savedKey)
    }
}
