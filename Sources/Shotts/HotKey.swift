import AppKit
import Carbon

/// A system-wide key that starts a capture, registered through Carbon so it needs no
/// Accessibility permission. Only the registered key reaches Shotts; nothing else is observed.
/// A hot key lives as long as the app: there is no unregistering, by design.
final class HotKey {
    static let f10 = UInt32(kVK_F10)

    private var ref: EventHotKeyRef?
    private let id: UInt32
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1

    init(keyCode: UInt32, modifiers: UInt32 = 0, handler: @escaping () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        Self.handlers[id] = handler
        Self.installHandlerOnce()
        let hotKeyID = EventHotKeyID(signature: 0x5348_5454, id: id) // 'SHTT'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    private static func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            MainActor.assumeIsolated {
                HotKey.handlers[hotKeyID.id]?()
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
