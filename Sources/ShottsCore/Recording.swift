import CoreGraphics
import Foundation

/// How a recording is written out: which file, how big, how smooth, and with which sound. The
/// recording itself is kept at its full size and up to 60 frames a second; every setting here
/// is applied when a file is made from it, so one recording can be saved several ways.
public struct RecordingSettings: Equatable, Sendable {
    public enum Format: String, CaseIterable, Sendable {
        /// H.264 video in an MP4, the one that plays nearly everywhere.
        case mp4
        /// An animated GIF: loops, silent, 255 colors.
        case gif

        public var fileExtension: String { rawValue }
    }

    public enum Sound: String, CaseIterable, Codable, Sendable {
        case none, system, microphone, both

        public var includesSystem: Bool { self == .system || self == .both }
        public var includesMicrophone: Bool { self == .microphone || self == .both }
    }

    public var format: Format
    /// The file's size as a percentage of the recording's, one of `RecordingRule.sizes`.
    public var percent: Int
    public var frameRate: Int
    /// MP4 only: GIFs are silent.
    public var sound: Sound
    /// The part of the recording kept; nil keeps all of it.
    public var trim: Trim?
    /// A width in pixels in place of `percent`, as `shotts --width` asks: never wider than the
    /// recording.
    public var width: Int?

    public init(format: Format, percent: Int, frameRate: Int, sound: Sound, trim: Trim? = nil, width: Int? = nil) {
        self.format = format
        self.percent = percent
        self.frameRate = frameRate
        self.sound = sound
        self.trim = trim
        self.width = width
    }

    /// The file's size in pixels from a recording of `recorded` pixels.
    public func size(recorded: (width: Int, height: Int)) -> (width: Int, height: Int) {
        guard let width else { return RecordingRule.size(percent: percent, format: format, recorded: recorded) }
        return RecordingRule.size(width: min(width, recorded.width), format: format, recorded: recorded)
    }
}

/// The part of a recording a file keeps, in seconds from its start: at least a tenth of a
/// second, and never past either end.
public struct Trim: Equatable, Sendable {
    public private(set) var start: Double
    public private(set) var end: Double
    public static let shortest = 0.1

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public static func whole(_ duration: Double) -> Trim { Trim(start: 0, end: duration) }

    public var length: Double { end - start }

    /// The start dragged to `time`, stopping short of the end.
    public func movingStart(to time: Double) -> Trim {
        Trim(start: min(max(time, 0), max(end - Self.shortest, 0)), end: end)
    }

    /// The end dragged to `time`, stopping short of the start and at the recording's end. A
    /// recording shorter than `shortest` keeps all of itself.
    public func movingEnd(to time: Double, duration: Double) -> Trim {
        Trim(start: start, end: min(max(time, start + Self.shortest), duration))
    }

    /// Whether it keeps all of a recording `duration` long, near enough that no one could see.
    public func isWhole(_ duration: Double) -> Bool { start < 0.001 && end > duration - 0.001 }
}

/// A timeline's drawing: times across a track `width` points wide, and which of a trim's
/// handles a point is on.
public struct TimelineLayout: Equatable, Sendable {
    public var width: Double
    public var duration: Double
    /// How near a handle a press takes it, in points.
    public static let reach = 8.0

    public init(width: Double, duration: Double) {
        self.width = width
        self.duration = duration
    }

    public func x(for time: Double) -> Double {
        duration > 0 ? min(max(time / duration, 0), 1) * width : 0
    }

    public func time(at x: Double) -> Double {
        width > 0 ? min(max(x / width, 0), 1) * duration : 0
    }

    public enum Part: Equatable, Sendable { case start, end, track }

    /// The handle a press at `x` takes, the nearer when both are in reach; else the track,
    /// which moves the playhead.
    public func part(at x: Double, of trim: Trim) -> Part {
        let toStart = abs(x - self.x(for: trim.start)), toEnd = abs(x - self.x(for: trim.end))
        guard min(toStart, toEnd) <= Self.reach else { return .track }
        // Handles at the same place: the one that can move toward the press.
        if toStart == toEnd { return x < self.x(for: trim.start) ? .start : .end }
        return toStart < toEnd ? .start : .end
    }
}

/// A recording's time with its pauses taken out: what was recorded while paused is dropped,
/// and what comes after a pause follows straight on from what came before it. Times are
/// seconds on any clock that only goes forward.
public struct PauseClock: Sendable {
    /// When the current pause began, while paused.
    public private(set) var pausedAt: Double?
    /// Pauses so far, as clock times, for samples that arrive late.
    private var pauses: [(start: Double, end: Double)] = []

    public init() {}

    public var isPaused: Bool { pausedAt != nil }

    public mutating func pause(at time: Double) {
        guard pausedAt == nil else { return }
        pausedAt = time
    }

    public mutating func resume(at time: Double) {
        guard let start = pausedAt else { return }
        pausedAt = nil
        pauses.append((start, max(time, start)))
    }

    /// Where a sample at clock `time` goes in the recording, counted from the clock's zero; nil
    /// for one from within a pause, which is dropped.
    public func recorded(_ time: Double) -> Double? {
        if let pausedAt, time >= pausedAt { return nil }
        var before = 0.0
        for pause in pauses {
            if time >= pause.end { before += pause.end - pause.start } else if time >= pause.start { return nil }
        }
        return time - before
    }

    /// How much has been recorded by clock `now`: held still while paused.
    public func elapsed(at now: Double) -> Double {
        (pausedAt ?? now) - pauses.reduce(0) { $0 + $1.end - $1.start }
    }
}

/// Where each sample a recording receives goes in it: seconds from its first frame, with the
/// pauses taken out (`PauseClock`). The screen sends a frame only when it changes, so a frame
/// that cannot go in must not simply be lost, or the picture before it would stand in until
/// the next change: a frame from a pause is held for the resume, and one the writer was not
/// ready for is offered again (`wrote` is said only once a frame is in). A frame is never
/// placed at or before the last one written.
public struct RecordingTimeline: Sendable {
    public private(set) var pauses = PauseClock()
    /// Where the last frame written went.
    private var lastFrame = -Double.infinity

    public init() {}

    /// What becomes of a frame received `time` seconds after the first.
    public enum Frame: Equatable, Sendable {
        /// Write it at this place in the recording.
        case write(at: Double)
        /// Keep it for when recording resumes: it came during a pause.
        case hold
        /// Leave it out: it comes no later than the frame written last.
        case drop
    }

    public func frame(at time: Double) -> Frame {
        guard let place = pauses.recorded(time) else {
            // From the pause going on now, held for its resume; from one already over, too late.
            return pauses.isPaused && time >= (pauses.pausedAt ?? .infinity) ? .hold : .drop
        }
        return place > lastFrame ? .write(at: place) : .drop
    }

    /// Where a sound sample received `time` seconds after the first frame goes; nil while paused.
    public func sound(at time: Double) -> Double? {
        pauses.recorded(time)
    }

    /// A frame is in the recording at `place`.
    public mutating func wrote(frameAt place: Double) {
        lastFrame = max(lastFrame, place)
    }

    public mutating func pause(at time: Double) { pauses.pause(at: time) }

    /// Resumes at `time`, and says where the frame held from the pause goes, if one was.
    public mutating func resume(at time: Double) -> Double? {
        guard pauses.isPaused else { return nil }
        pauses.resume(at: time)
        let place = pauses.elapsed(at: time)
        return place > lastFrame ? place : nil
    }

    public var isPaused: Bool { pauses.isPaused }

    public func elapsed(at time: Double) -> Double { pauses.elapsed(at: time) }
}

/// The rules a recording's files follow: their sizes, frame rates, and timing.
public enum RecordingRule {
    /// The rate a recording is made at, at most: a frame comes only when the screen changes.
    public static let recordedFrameRate = 60

    /// The frame rates a file can have: smooth video, UI demos, steps, and a slideshow. Every one
    /// divides 60, so a lower rate keeps whole frames and never blends two. A GIF stops at 30:
    /// its frame times are whole hundredths of a second, and browsers slow anything under two
    /// hundredths to a tenth.
    public static func frameRates(for format: RecordingSettings.Format) -> [Int] {
        format == .gif ? [30, 20, 10, 5, 1] : [60, 30, 20, 10, 5, 1]
    }

    /// The largest frame H.264 players are sure to take (level 5.2): 4096 by 2304.
    static let h264Limit = (width: 4096, height: 2304)

    /// A recording's size in pixels for an area of `points` at `scale`, whole and even each way,
    /// since video is stored in two-by-two blocks of color.
    public static func recordedSize(points: CGSize, scale: Double) -> (width: Int, height: Int) {
        func even(_ v: Double) -> Int { max(2, Int(v * scale) / 2 * 2) }
        return (even(points.width), even(points.height))
    }

    /// The widest a file of `format` can be from a recording of `recorded` pixels: the recording's
    /// own width, and for MP4 no more than fits the H.264 limit at the recording's proportions.
    public static func maxWidth(for format: RecordingSettings.Format, recorded: (width: Int, height: Int)) -> Int {
        guard format == .mp4 else { return recorded.width }
        let fit = min(Double(h264Limit.width) / Double(recorded.width), Double(h264Limit.height) / Double(recorded.height), 1)
        return max(2, Int(Double(recorded.width) * fit) / 2 * 2)
    }

    /// The sizes a file can be, as percentages of the recording: what matters is how big it is
    /// beside what was recorded, not its count of pixels.
    public static let sizes = [100, 75, 50, 25]

    /// A file's size in pixels at `percent` of the recording, by `size(width:format:recorded:)`.
    public static func size(percent: Int, format: RecordingSettings.Format, recorded: (width: Int, height: Int)) -> (width: Int, height: Int) {
        size(width: recorded.width * percent / 100, format: format, recorded: recorded)
    }

    /// A recording's time as the timer and the timeline show it: `m:ss`, or `h:mm:ss` from an hour.
    public static func clock(_ seconds: Double) -> String {
        let s = Int(max(seconds, 0))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The narrowest a file can be.
    public static let minWidth = 16

    /// A file's size in pixels for a requested `width`: within the format's limits and even,
    /// with the height in the recording's proportions, also even.
    public static func size(width: Int, format: RecordingSettings.Format, recorded: (width: Int, height: Int)) -> (width: Int, height: Int) {
        let w = min(max(width, minWidth), maxWidth(for: format, recorded: recorded)) / 2 * 2
        let h = Int((Double(w) * Double(recorded.height) / Double(recorded.width)).rounded())
        return (w, max(2, (h + 1) / 2 * 2))
    }

    /// Where a recording's window starts: MP4 at the recording's full size and 30 frames a second,
    /// with the microphone if it was recorded; GIF at the size the area had on screen (half, from
    /// a Retina display) and 10 frames a second. The Mac's own sound is kept only when asked for.
    public static func defaults(for format: RecordingSettings.Format, scale: Double, hasMicrophone: Bool) -> RecordingSettings {
        switch format {
        case .mp4:
            RecordingSettings(format: .mp4, percent: 100, frameRate: 30,
                              sound: hasMicrophone ? .microphone : .none)
        case .gif:
            RecordingSettings(format: .gif, percent: scale >= 2 ? 50 : 100, frameRate: 10, sound: .none)
        }
    }

    /// The H.264 bit rate for a size and rate: enough for sharp text in screen video, which is
    /// mostly still. It grows with the square root of the rate, since between frames that
    /// come faster less changes.
    public static func h264BitRate(width: Int, height: Int, frameRate: Int) -> Int {
        Int(Double(width * height) * Double(frameRate).squareRoot() * 0.6)
    }
}

/// Which of a recording's frames a file keeps, and when each shows. The recording has a frame
/// whenever the screen changed, at most 60 a second; a file at a lower rate shows, at each tick
/// of its rate, the latest frame by then. A frame replaced before any tick is left out, and
/// one still showing at a tick appears at that tick, so the last change before a pause is never
/// lost.
public enum FrameSampler {
    /// When a frame shown from `time` until `next` (seconds from the start) appears in a file at
    /// `rate` frames a second: at the first tick at or after `time`, if that comes before
    /// `next`; nil if the frame is left out.
    public static func tick(for time: Double, until next: Double, rate: Int) -> Double? {
        let r = Double(rate)
        // A time a hair past a tick, from rounding, still counts as that tick.
        let t = ((time * r) - 1e-6).rounded(.up) / r
        return t < next - 1e-9 ? t : nil
    }
}

/// How much louder a recording's system sound is made, to undo what macOS takes off it.
/// ScreenCaptureKit hands over the Mac's sound quieter than it played, by an amount fixed for
/// each output device (none on a MacBook's speakers, 6 to 14 dB on some USB interfaces) and
/// whatever the volume. Shotts plays a tone too quiet to hear, captures it, and compares what
/// came back with what it played; the files made then put back what was taken.
public enum SoundCalibration {
    /// The tone's level: far below hearing at any ordinary volume, far above the capture's floor.
    public static let toneDecibels = -60.0
    /// More taken off than this is not believed: something else went wrong.
    public static let largestLoss = 30.0

    /// The tone's peak amplitude, from `toneDecibels`.
    public static var toneAmplitude: Double { pow(10, toneDecibels / 20) }

    /// The tone's frequency: whole cycles in each measuring window, low enough to hear least.
    public static let toneFrequency = 200.0

    /// The tone's level in `samples` (at `sampleRate`), as a root mean square: its strength at
    /// `toneFrequency` alone (Goertzel's algorithm), in tenth-of-a-second windows. The tone holds
    /// steady for longer than four of them, so the four loudest must agree within a decibel, and
    /// their median is the level; when they do not, something else sounded at its pitch (the
    /// start of another sound splashes across every pitch) and nil says not to believe it.
    public static func level(of samples: [Float], sampleRate: Double = 48_000) -> Double? {
        let window = Int(sampleRate / 10)
        guard window > 0 else { return nil }
        let coefficient = 2 * cos(2 * .pi * toneFrequency / sampleRate)
        var levels: [Double] = []
        var start = 0
        while start + window <= samples.count {
            var s1 = 0.0, s2 = 0.0
            for x in samples[start..<start + window] {
                let s0 = Double(x) + coefficient * s1 - s2
                s2 = s1
                s1 = s0
            }
            let power = max(s1 * s1 + s2 * s2 - coefficient * s1 * s2, 0)
            // A sine of amplitude A gives power (A·N/2)²; its root mean square is A/√2.
            levels.append(2 * power.squareRoot() / Double(window) / 2.squareRoot())
            start += window
        }
        let loudest = levels.sorted(by: >).prefix(4)
        guard loudest.count == 4, let top = loudest.first, let fourth = loudest.last, fourth > 0,
              20 * log10(top / fourth) <= 1 else { return nil }
        let middle = Array(loudest)
        return (middle[1] + middle[2]) / 2
    }

    /// The factor that makes what was `heard` as loud as what was `played` (levels as root mean
    /// squares): at least 1, so nothing is made quieter; nil when nothing came back or the loss
    /// is past believing.
    public static func gain(played: Double, heard: Double) -> Double? {
        guard played > 0, heard > 0 else { return nil }
        let loss = 20 * log10(played / heard)
        guard loss <= largestLoss else { return nil }
        // Within half a decibel is no loss at all: the measurement's own wobble.
        return loss < 0.5 ? 1 : played / heard
    }
}
