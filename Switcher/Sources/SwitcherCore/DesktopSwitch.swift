// The switcher's decisions: which macOS has it, how far a switch may go, and the
// synthetic Dock swipe that makes it instant, with the payload macOS 27 checks it against.
//
// From noswoosh 1.7.8 (https://github.com/mmathys/noswoosh), Copyright (c) 2026 Max Mathys,
// MIT License. The swipe technique is from jurplel/InstantSpaceSwitcher (MIT); the macOS 27
// payload layout from joshuarli/iss (ISC).

/// A desktop switch is a Dock swipe posted with almost no progress and a hard fling: the Dock's
/// own pipeline switches (so Mission Control, focus, and the wallpaper stay consistent) but the
/// slide has no distance to travel. The numbers are measured, not chosen, and each of them was
/// once wrong in a way that showed; `swipe` says how.
public enum DesktopSwitch {
    /// macOS 26.6 and later. 26.0-26.5 drop the destination's surfaces on a switch with no
    /// travel, landing on a blank desktop, and nothing outside the Dock works around it.
    public static func isAvailable(major: Int, minor: Int) -> Bool {
        major > 26 || (major == 26 && minor >= 6)
    }

    /// macOS 27 checks a synthetic swipe against a serialized IOHID payload (`payload`) and
    /// wants each one paired with a companion gesture event.
    public static func needsPayload(major: Int) -> Bool { major >= 27 }

    /// The desktop a switch from `current` lands on among `count`, or nil past the first or
    /// last: the Dock would only rubber-band.
    public static func target(from current: Int, of count: Int, right: Bool) -> Int? {
        let next = current + (right ? 1 : -1)
        return (0..<count).contains(next) ? next : nil
    }

    public enum Phase: Int64, Sendable { case began = 1, changed = 2, ended = 4, cancelled = 8 }

    /// One posted event's numbers.
    public struct Swipe: Equatable, Sendable {
        public var progress: Double
        public var velocity: Double
    }

    /// The numbers for `phase`.
    ///
    /// macOS 26: 1e-4 progress and a 2000 fling on every phase, rightward positive. Not the
    /// smallest float: a subnormal flushes to zero in the event pipeline and loses its sign.
    ///
    /// macOS 27: 1e-4 on began and changed, so the Dock has no partial slide to draw first (0.1
    /// there was a one-frame jiggle), and 0.1 on ended, so the commit has some travel (1e-4
    /// there sometimes landed on a black desktop on 27.0.1); a 9999 fling on ended only.
    /// Rightward is negative when posted, though a real rightward swipe reads positive
    /// (`isRight`): that asymmetry is measured, so it stays. With Natural scrolling off the
    /// Dock reads a posted swipe the other way round, so the sign flips again.
    public static func swipe(_ phase: Phase, right: Bool, payload: Bool, naturalScrolling: Bool) -> Swipe {
        guard payload else {
            let sign: Double = right ? 1 : -1
            return Swipe(progress: 1e-4 * sign, velocity: 2000 * sign)
        }
        let sign: Double = (right ? -1 : 1) * (naturalScrolling ? 1 : -1)
        let ended = phase == .ended
        return Swipe(progress: (ended ? 0.1 : 1e-4) * sign, velocity: ended ? 9999 * sign : 0)
    }

    /// The direction of a real horizontal swipe, from its progress or velocity: rightward is
    /// positive on every macOS and either scrolling direction.
    public static func isRight(_ direction: Double) -> Bool { direction > 0 }

    /// The serialized IOHID queue element macOS 27 validates a posted swipe against: a header,
    /// a fluid-touch gesture record, and on a fling a velocity record, little-endian. The
    /// position is fixed at 0.1 across, as the swipe is posted.
    public static func payload(timestamp: UInt64, phase: Phase, swipe: Swipe) -> [UInt8] {
        var bytes: [UInt8] = []
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        let fling = swipe.velocity != 0 || phase == .ended
        // Header: timestamp, sender, options, attribute length, event count.
        put(timestamp); put(UInt64(0)); put(UInt32(0)); put(UInt32(0)); put(UInt32(fling ? 2 : 1))
        // Fluid-touch gesture: size, type, phase in the options' top byte, depth and padding;
        // position, swipe mask, horizontal motion, Dock flavor, progress.
        put(UInt32(40)); put(UInt32(23)); put(UInt32(UInt32(phase.rawValue & 0xFF) << 24)); put(UInt32(0))
        put(fixed1616(0.1)); put(Int32(0)); put(Int32(0)); put(UInt32(0)); put(UInt16(1)); put(UInt16(3))
        put(fixed1616(swipe.progress))
        if fling {
            // Velocity: size, type, options, depth 1; x, y, z.
            put(UInt32(28)); put(UInt32(9)); put(UInt32(0)); put(UInt32(1))
            put(fixed1616(swipe.velocity)); put(Int32(0)); put(Int32(0))
        }
        return bytes
    }

    /// A serialized event (`CGEvent.data`) with `payload` appended under field 4205, which no
    /// event setter writes; nil unless it is serialized format 2.
    public static func appending(_ payload: [UInt8], to event: [UInt8]) -> [UInt8]? {
        guard event.starts(with: [0, 0, 0, 2]), payload.count <= 0xFFFF else { return nil }
        let field = 4205
        return event + [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF), UInt8(field >> 8), UInt8(field & 0xFF)] + payload
    }

    /// 16.16 fixed point, never rounding a nonzero value to zero, which would drop its sign.
    public static func fixed1616(_ value: Double) -> Int32 {
        let fixed = Int32(truncatingIfNeeded: Int64(value * 65536))
        return fixed == 0 && value != 0 ? (value > 0 ? 1 : -1) : fixed
    }
}

/// A real horizontal three-finger swipe, held back from the Dock and replaced by an instant
/// switch: the first phase that says which way (progress while it moves, or velocity at the end
/// for a swipe with no middle) switches, once. The swipe's companion gesture events are held
/// back with it. Vertical swipes (Mission Control, App Exposé) are none of this and pass.
public struct SwipeTracker: Sendable {
    /// What to do with one Dock-swipe event.
    public struct Verdict: Equatable, Sendable {
        /// Whether it goes on to the Dock.
        public var passes: Bool
        /// Switch one desktop this way: true is right.
        public var switchRight: Bool?
        /// Empty its progress and velocity before it goes on.
        public var emptied = false
    }

    private var tracking = false
    private var fired = false

    public init() {}

    /// A companion gesture event goes on unless its swipe is held back.
    public var passesCompanion: Bool { !tracking }

    /// One horizontal Dock-swipe event. On macOS 27 (`passEnd`) the end of a held-back swipe goes
    /// on, emptied, so the Dock closes its own gesture after the switch.
    public mutating func swipe(phase: Int64, progress: Double, velocity: Double, passEnd: Bool) -> Verdict {
        switch DesktopSwitch.Phase(rawValue: phase) {
        case .began:
            (tracking, fired) = (true, false)
            return Verdict(passes: false)
        case .changed:
            guard tracking else { return Verdict(passes: true) }
            guard !fired, progress != 0 else { return Verdict(passes: false) }
            fired = true
            return Verdict(passes: false, switchRight: DesktopSwitch.isRight(progress))
        case .ended:
            let tracked = tracking, direction = tracked && !fired && velocity != 0 ? DesktopSwitch.isRight(velocity) : nil
            (tracking, fired) = (false, false)
            return tracked && passEnd ? Verdict(passes: true, switchRight: direction, emptied: true) : Verdict(passes: !tracked, switchRight: direction)
        case .cancelled:
            (tracking, fired) = (false, false)
            return Verdict(passes: false)
        case nil:
            return Verdict(passes: !tracking)
        }
    }

    /// Forgets a swipe in progress, as when macOS turns the tap off mid-swipe.
    public mutating func reset() { (tracking, fired) = (false, false) }
}
