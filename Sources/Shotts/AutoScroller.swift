import AppKit
import ApplicationServices
import ShottsCore

/// Scrolls what is under the pointer for a scrolling capture, in steps Core's `AutoScroll`
/// paces, until the picture stops growing (the bottom, `onFinish`) or it cannot follow the area
/// (`onGiveUp`). Sending scrolling to another app needs Accessibility: macOS asks for it at the
/// first scrolling capture, and without it the user scrolls. It sends nothing but scroll-wheel
/// steps, and only between `start` and `stop`.
///
/// Scrolling goes to what is under the pointer, so while it runs the pointer is held in the
/// area, and the mouse's own moves, clicks, and scrolling are dropped before any app sees them
/// (an event tap, which Accessibility also allows): a nudge of the mouse would send the steps
/// elsewhere, and a click would land in what is being captured. The keys still work: F10 and
/// Return end it, Escape cancels. The mouse is let go the moment scrolling stops, however it
/// stops, and the pointer goes back where it was, since the mouse's own moves went nowhere.
final class AutoScroller {
    /// Whether Shotts may scroll other apps.
    static var allowed: Bool { AXIsProcessTrusted() }

    /// Asks macOS for Accessibility: its own dialog, pointing to the setting.
    static func ask() {
        // kAXTrustedCheckOptionPrompt's value, written out: the global is not concurrency-safe.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private let areaHeight: Double
    /// Made when scrolling starts, so its time counts from there.
    private var rule: AutoScroll?
    private var timer: Timer?
    /// Stopped: it never starts again, so the mouse is never held after it was let go.
    private var stopped = false
    /// Where the pointer is held, in global display coordinates (from the top left).
    private let pointer: CGPoint
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    /// Where the pointer was before it was held, while it is held, with or without the tap: it
    /// is let go either way.
    private var heldFrom: CGPoint?
    /// macOS turned the tap off for the user's own input: the mouse is the user's again.
    private var takenBack = false
    /// Marks Shotts' own scroll steps, which the tap lets through.
    nonisolated private static let mark: Int64 = 0x5348_4F54
    private var height = 0, lost = false, full = false
    /// Called once, at the bottom.
    var onFinish: (() -> Void)?
    /// Called once, when it cannot follow the area and stops trying.
    var onGiveUp: (() -> Void)?

    /// `pointer` is where to hold the pointer, in global display coordinates.
    init(areaHeight: Double, pointer: CGPoint) {
        self.areaHeight = areaHeight
        self.pointer = pointer
    }

    deinit {
        MainActor.assumeIsolated { stop() }
    }

    /// The stitching's progress: the picture's height, whether the last frame was not matched,
    /// and whether it is full.
    func progress(height: Int, lost: Bool, full: Bool) {
        self.height = height
        if lost { self.lost = true }
        self.full = full
    }

    func start() {
        guard timer == nil, !stopped else { return }
        rule = AutoScroll(areaHeight: areaHeight, now: ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: AutoScroll.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // An area too short to scroll gives up at the first tick, the mouse never held.
        if areaHeight >= AutoScroll.shortest { holdMouse() }
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        letGoOfMouse()
    }

    /// The pointer goes to `pointer` and stays put while the mouse moves, and the mouse's events
    /// go nowhere.
    private func holdMouse() {
        heldFrom = CGEvent(source: nil)?.location ?? pointer
        CGWarpMouseCursorPosition(pointer)
        CGAssociateMouseAndMouseCursorPosition(0)
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
                                    .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                          callback: { _, type, event, info in
                                              // On the main run loop, where the tap's source is.
                                              guard let info else { return Unmanaged.passUnretained(event) }
                                              let scroller = Unmanaged<AutoScroller>.fromOpaque(info).takeUnretainedValue()
                                              let location = event.location
                                              let mine = event.getIntegerValueField(.eventSourceUserData) == AutoScroller.mark
                                              let keep = MainActor.assumeIsolated { scroller.keeps(type, mine: mine, at: location) }
                                              return keep ? Unmanaged.passUnretained(event) : nil
                                          }, userInfo: me) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
    }

    private func letGoOfMouse() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        // Even when no tap could be made: the pointer was held all the same.
        guard let heldFrom else { return }
        self.heldFrom = nil
        CGAssociateMouseAndMouseCursorPosition(1)
        CGWarpMouseCursorPosition(heldFrom)
    }

    /// Shotts' own steps go on; the mouse's events are dropped, and the pointer, should it have
    /// moved all the same, goes back.
    private func keeps(_ type: CGEventType, mine: Bool, at location: CGPoint) -> Bool {
        switch type {
        case .tapDisabledByTimeout:
            // macOS turns off a tap it finds slow; the mouse would come back mid-scroll.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        case .tapDisabledByUserInput:
            // macOS turned it off for the user's own input, as for secure text entry: the
            // mouse's events reach the apps again and the steps could go anywhere, so scrolling
            // stops at the next tick and the user scrolls.
            takenBack = true
            return true
        case .scrollWheel where mine:
            return true
        default:
            if location != pointer { CGWarpMouseCursorPosition(pointer) }
            return false
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        guard let action = takenBack ? .giveUp : rule?.next(height: height, lost: lost, full: full, now: now) else { return }
        // A frame not matched is answered once: the next not matched comes with its own frame.
        lost = false
        switch action {
        case .wait:
            break
        case .finish:
            stop()
            onFinish?()
            onFinish = nil
        case .giveUp:
            stop()
            onGiveUp?()
            onGiveUp = nil
        case let .scroll(points):
            // In points, smoothly, to whatever is under the pointer; down is a negative delta.
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                      wheel1: Int32(-points.rounded()), wheel2: 0, wheel3: 0) else { return }
            event.setIntegerValueField(.eventSourceUserData, value: Self.mark)
            event.post(tap: .cghidEventTap)
        }
    }
}
