import AppKit
import ApplicationServices
import ShottsCore

/// Scrolls what is under the pointer for a scrolling capture once Auto-Scroll is pressed, in
/// steps Core's `AutoScroll` paces, until the picture stops growing (the bottom, `onFinish`) or
/// frames keep not matching (`onGiveUp`). Sending scrolling to another app needs Accessibility:
/// macOS asks for it when Auto-Scroll is first pressed, and without it the user scrolls. It sends
/// nothing but scroll-wheel steps, and only while Auto-Scroll runs.
///
/// Scrolling goes to what is under the pointer, so while it runs the pointer is held where it
/// was put, and the mouse's own moves, clicks, and scrolling are dropped before any app sees
/// them (an event tap, which Accessibility also allows): a nudge of the mouse would send the
/// steps elsewhere, and a click would land in what is being captured. The keys still work: F10
/// and Return end it, Escape cancels. The mouse is let go the moment scrolling stops, however.
final class AutoScroller {
    /// Whether Shotts may scroll other apps.
    static var allowed: Bool { AXIsProcessTrusted() }

    /// Asks macOS for Accessibility: its own dialog, pointing to the setting.
    static func ask() {
        // kAXTrustedCheckOptionPrompt's value, written out: the global is not concurrency-safe.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private var rule: AutoScroll
    private var timer: Timer?
    /// Where the pointer is held, in global display coordinates (from the top left).
    private let pointer: CGPoint
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    /// Whether the pointer is held, with or without the tap: it is let go either way.
    private var holding = false
    /// Marks Shotts' own scroll steps, which the tap lets through.
    nonisolated private static let mark: Int64 = 0x5348_4F54
    private var height = 0, lost = false, full = false
    /// Called once, at the bottom.
    var onFinish: (() -> Void)?
    /// Called once, when frames keep not matching and it stops trying.
    var onGiveUp: (() -> Void)?

    /// `pointer` is where the pointer was put, in global display coordinates.
    init(areaHeight: Double, pointer: CGPoint) {
        rule = AutoScroll(areaHeight: areaHeight, now: ProcessInfo.processInfo.systemUptime)
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
        guard timer == nil else { return }
        let timer = Timer(timeInterval: AutoScroll.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        holdMouse()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        letGoOfMouse()
    }

    /// The pointer stays put while the mouse moves, and the mouse's events go nowhere.
    private func holdMouse() {
        CGWarpMouseCursorPosition(pointer)
        CGAssociateMouseAndMouseCursorPosition(0)
        holding = true
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
        guard holding else { return }
        holding = false
        CGAssociateMouseAndMouseCursorPosition(1)
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
            return true
        case .scrollWheel where mine:
            return true
        default:
            if location != pointer { CGWarpMouseCursorPosition(pointer) }
            return false
        }
    }

    private func tick() {
        let action = rule.next(height: height, lost: lost, full: full, now: ProcessInfo.processInfo.systemUptime)
        // A frame not matched is answered once: the next not matched comes with its own frame.
        lost = false
        switch action {
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
