import AppKit
import CoreGraphics
import ShottsCore

/// While a recording that shows them runs: each click anywhere, and each shortcut pressed. Clicks
/// come from a global mouse monitor, which needs no permission. Keys come from a listen-only
/// event tap, which needs Input Monitoring: macOS asks for it the first time a recording shows
/// keys, and while a password is typed it sends a tap no keys at all. Nothing is kept: each
/// click or key goes straight to the recording's drawing layer, and all of it stops with the
/// recording.
final class InputWatcher {
    private var clickMonitor: Any?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private let onKey: (String) -> Void

    /// Whether Shotts may see keys pressed in other apps.
    static var keysAllowed: Bool { CGPreflightListenEventAccess() }

    /// Asks macOS for Input Monitoring: its own dialog, once; afterwards it only says no.
    static func askForKeys() { _ = CGRequestListenEventAccess() }

    init(clicks: Bool, keys: Bool, onClick: @escaping (CGPoint) -> Void, onKey: @escaping (String) -> Void) {
        self.onKey = onKey
        if clicks {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
                MainActor.assumeIsolated { onClick(NSEvent.mouseLocation) }
            }
        }
        if keys { startTap() }
    }

    /// Stops watching. Also done when the watcher goes.
    func stop() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
    }

    deinit {
        MainActor.assumeIsolated { stop() }
    }

    private func startTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask,
                                          callback: { _, type, event, info in
                                              // On the main run loop, where the tap's source is.
                                              guard let info else { return Unmanaged.passUnretained(event) }
                                              let watcher = Unmanaged<InputWatcher>.fromOpaque(info).takeUnretainedValue()
                                              switch type {
                                              case .keyDown:
                                                  MainActor.assumeIsolated { watcher.pressed(event) }
                                              case .tapDisabledByTimeout:
                                                  // macOS turns off a tap it finds slow; keys would stop showing. One
                                                  // it turns off for the user's sake stays off.
                                                  MainActor.assumeIsolated { watcher.resume() }
                                              default:
                                                  break
                                              }
                                              return Unmanaged.passUnretained(event)
                                          }, userInfo: me) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
    }

    private func resume() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func pressed(_ event: CGEvent) {
        guard let key = NSEvent(cgEvent: event) else { return }
        var modifiers: KeystrokeLine.Modifiers = []
        let flags = key.modifierFlags
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        // The key's own character, as without modifiers ("4" for Shift-Command-4). Typing is not shown.
        let base = key.characters(byApplyingModifiers: []) ?? key.charactersIgnoringModifiers ?? ""
        if let shortcut = KeystrokeLine.key(code: key.keyCode, base: base, modifiers: modifiers) { onKey(shortcut) }
    }
}
