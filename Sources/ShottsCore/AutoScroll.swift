import Foundation

/// How Shotts scrolls an area for a scrolling capture: steady steps, as fast as the stitching
/// can follow, until the picture stops growing, which is the bottom. A frame that could not be
/// matched means it went too fast: it backs up a step and goes on at half the speed. Should
/// nothing new come at all, the scrolling may be going the other way than expected (the system's
/// scrolling direction): it tries the other way once before taking the frame as all there is.
public struct AutoScroll: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Scroll by this many points, down being positive.
        case scroll(Double)
        /// The bottom: no new rows for `settle` while scrolling.
        case finish
    }

    /// How often it steps, in seconds.
    public static let tick = 0.05
    /// How long the picture must stop growing, while scrolling, to be at the bottom.
    public static let settle = 0.8
    /// The slowest step, in points.
    public static let slowest = 4.0

    public private(set) var step: Double
    /// 1 or -1: which way a step goes.
    public private(set) var direction = 1.0
    private var height = 0
    /// The first frame's height, and whether anything has been added to it since.
    private var first: Int?
    private var added = false
    private var turned = false
    private var grew: Double

    /// For an area `areaHeight` points tall, starting at `now` (seconds, on any clock that only
    /// goes forward). A step is a sixth of the area, between 12 and 120 points: at 20 steps a
    /// second, that keeps each frame's move a small part of what the stitching can match.
    public init(areaHeight: Double, now: Double) {
        step = min(max(areaHeight / 6, 12), 120)
        grew = now
    }

    /// What to do next, given the picture's height so far and whether the last frame was matched.
    public mutating func next(height: Int, lost: Bool, full: Bool, now: Double) -> Action {
        if full { return .finish }
        if height > self.height {
            if first == nil { first = height } else { added = true }
            self.height = height
            grew = now
        }
        if lost {
            // Back to where the last frame matched, then on at half the speed.
            let back = step
            step = max(Self.slowest, step / 2)
            grew = now
            return .scroll(-back * direction)
        }
        // Waiting for the first frame counts nothing against the bottom.
        if first == nil { grew = now }
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
