import Foundation

/// How Shotts scrolls an area for a scrolling capture: steady steps, as fast as the stitching
/// can follow, until the picture stops growing, which is the bottom. Nothing is scrolled until
/// the first frame is in, so the picture starts where the area did; should none come within
/// `firstFrameWithin`, it gives up rather than hold the mouse for nothing.
///
/// A frame that could not be matched means it went too fast: it backs up a step and goes on at
/// half the speed, and as frames match again the speed comes back. Frames already on their way
/// when it backs up still show the step too far, so a frame not matched right after a back-up
/// is not counted. After `giveUpAfter` back-ups in a row with nothing added it stops trying,
/// rather than go back and forth for ever, as an area whose parts do not all scroll together
/// would. Should nothing new come at all, the scrolling may be going the other way than
/// expected (the system's scrolling direction): it tries the other way once. However it goes,
/// it stops after `limit`, with what it has: the mouse is held until then.
public struct AutoScroll: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Nothing yet: the first frame is not in.
        case wait
        /// Scroll by this many points, down being positive.
        case scroll(Double)
        /// The bottom (no new rows for `settle` while scrolling), or `limit` reached.
        case finish
        /// It cannot follow this area: frames keep not matching, none came, or it is too short.
        case giveUp
    }

    /// Frames not matched in a row, with nothing added between, before it gives up.
    public static let giveUpAfter = 5

    /// How often it steps, in seconds.
    public static let tick = 0.05
    /// How long the picture must stop growing, while scrolling, to be at the bottom.
    public static let settle = 0.8
    /// The slowest step, in points.
    public static let slowest = 4.0
    /// The longest it scrolls, in seconds, bottom or not.
    public static let limit = 30.0
    /// How long it waits for the first frame, in seconds.
    public static let firstFrameWithin = 2.0
    /// The shortest area it scrolls, in points: below about 24 rows, the stitching cannot match
    /// a frame's middle moved by any step that gets anywhere.
    public static let shortest = 24.0
    /// How much faster each step is than the last, after a step that added rows, up to the first.
    static let speedUp = 1.25

    public private(set) var step: Double
    /// The first step, the fastest.
    private let fastest: Double
    /// 1 or -1: which way a step goes.
    public private(set) var direction = 1.0
    private let tooShort: Bool
    private var height = 0
    /// Whether the first frame is in, and whether anything has been added to it since.
    private var first = false
    private var added = false
    private var turned = false
    private var misses = 0
    /// Whether the last step was a back-up.
    private var backedUp = false
    private var grew: Double
    private let started: Double

    /// For an area `areaHeight` points tall, starting at `now` (seconds, on any clock that only
    /// goes forward). A step is a sixth of the area, up to 120 points: at 20 steps a second, that
    /// keeps each frame's move within what the stitching can match, a sixth of the frame's rows
    /// at any scale.
    public init(areaHeight: Double, now: Double) {
        fastest = min(areaHeight / 6, 120)
        step = fastest
        tooShort = areaHeight < Self.shortest
        grew = now
        started = now
    }

    /// What to do next, given the picture's height so far and whether a frame since the last
    /// step was not matched.
    public mutating func next(height: Int, lost: Bool, full: Bool, now: Double) -> Action {
        if tooShort { return .giveUp }
        if full || now - started >= Self.limit { return .finish }
        let backedUp = backedUp
        self.backedUp = false
        if height > self.height {
            if first {
                added = true
                if !lost, !backedUp { step = min(fastest, step * Self.speedUp) }
            }
            first = true
            self.height = height
            grew = now
            misses = 0
        }
        guard first else { return now - started >= Self.firstFrameWithin ? .giveUp : .wait }
        if lost, !backedUp {
            misses += 1
            if misses >= Self.giveUpAfter { return .giveUp }
            // Back to where the last frame matched, then on at half the speed.
            let back = step
            step = max(min(Self.slowest, fastest), step / 2)
            grew = now
            self.backedUp = true
            return .scroll(-back * direction)
        }
        guard now - grew >= Self.settle else { return .scroll(step * direction) }
        if !added, !turned {
            turned = true
            direction = -direction
            grew = now
            return .scroll(step * direction)
        }
        return .finish
    }
}
