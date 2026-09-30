import CoreGraphics
import Foundation

/// How a recording is written out: which file, how big, how smooth, and with which sound. The
/// recording itself is kept at its full size and up to 60 frames a second; every setting here
/// is applied when a file is made from it, so one recording can be saved several ways.
public struct RecordingSettings: Equatable, Sendable {
    public enum Format: String, CaseIterable, Sendable {
        /// H.264 video in an MP4, the one that plays nearly everywhere.
        case mp4
        /// An animated GIF: loops, silent, 256 colors.
        case gif

        public var fileExtension: String { rawValue }
    }

    public enum Sound: String, CaseIterable, Sendable {
        case none, system, microphone, both

        public var includesSystem: Bool { self == .system || self == .both }
        public var includesMicrophone: Bool { self == .microphone || self == .both }
    }

    public var format: Format
    /// In pixels; the height follows the recording's proportions.
    public var width: Int
    public var frameRate: Int
    /// MP4 only: GIFs are silent.
    public var sound: Sound

    public init(format: Format, width: Int, frameRate: Int, sound: Sound) {
        self.format = format
        self.width = width
        self.frameRate = frameRate
        self.sound = sound
    }
}

/// The rules a recording's files follow: their sizes, frame rates, and timing.
public enum RecordingRule {
    /// The rate a recording is made at, at most: a frame comes only when the screen changes.
    public static let recordedFrameRate = 60

    /// The frame rates a file can have. Every one divides 60, so a lower rate keeps whole frames
    /// and never blends two. A GIF stops at 30: its frame times are whole hundredths of a
    /// second, and browsers slow anything under two hundredths to a tenth.
    public static func frameRates(for format: RecordingSettings.Format) -> [Int] {
        format == .gif ? [30, 20, 15, 12, 10] : [60, 30, 20, 15, 12, 10]
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
    /// with the microphone if it was recorded; GIF at the size the area had on screen and 15
    /// frames a second. The Mac's own sound is kept only when asked for.
    public static func defaults(for format: RecordingSettings.Format, recorded: (width: Int, height: Int), scale: Double,
                                hasMicrophone: Bool) -> RecordingSettings {
        switch format {
        case .mp4:
            RecordingSettings(format: .mp4, width: maxWidth(for: .mp4, recorded: recorded), frameRate: 30,
                              sound: hasMicrophone ? .microphone : .none)
        case .gif:
            RecordingSettings(format: .gif, width: size(width: Int(Double(recorded.width) / max(scale, 1)), format: .gif, recorded: recorded).width,
                              frameRate: 15, sound: .none)
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

/// A GIF's frame times, which are whole hundredths of a second.
public enum GIFTiming {
    /// The delay of a frame shown from `start` until `end`, in hundredths. Measured between the
    /// two times each rounded, so rounding never adds up over a long GIF; never under two,
    /// which browsers would slow to ten.
    public static func delay(from start: Double, to end: Double) -> Int {
        max(2, Int((end * 100).rounded()) - Int((start * 100).rounded()))
    }
}
