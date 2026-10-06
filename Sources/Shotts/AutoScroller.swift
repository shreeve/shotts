import AppKit
import ApplicationServices
import ShottsCore

/// Scrolls what is under the pointer for a scrolling capture once Auto-Scroll is pressed, in
/// steps Core's `AutoScroll` paces, until the picture stops growing (the bottom, `onFinish`) or
/// frames keep not matching (`onGiveUp`). Sending scrolling to another app needs Accessibility:
/// macOS asks for it when Auto-Scroll is first pressed, and without it the user scrolls. It sends
/// nothing but scroll-wheel steps, and only while Auto-Scroll runs.
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
    private var height = 0, lost = false, full = false
    /// Called once, at the bottom.
    var onFinish: (() -> Void)?
    /// Called once, when frames keep not matching and it stops trying.
    var onGiveUp: (() -> Void)?

    init(areaHeight: Double) {
        rule = AutoScroll(areaHeight: areaHeight, now: ProcessInfo.processInfo.systemUptime)
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
    }

    func stop() {
        timer?.invalidate()
        timer = nil
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
            event.post(tap: .cghidEventTap)
        }
    }
}
