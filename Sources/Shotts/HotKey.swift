import AppKit
import Carbon

/// F10 and ⇧⌘4, and each with Option, system-wide, registered through Carbon so they need no
/// Accessibility permission. Only these keys reach Shotts; nothing else is observed. They live
/// as long as the app: there is no unregistering, by design. Another app holding the same key
/// does not stop it registering: both answer it.
enum HotKey {
    private static var actions: [UInt32: () -> Void] = [:]

    /// Runs `action` whenever the key `keyCode` (F10 unless said) is pressed with exactly
    /// `modifiers` (Carbon's, such as `optionKey`). Returns false when the key could not be
    /// registered, as when another app holds it exclusively.
    static func register(_ keyCode: Int = kVK_F10, modifiers: Int = 0, _ action: @escaping () -> Void) -> Bool {
        if actions.isEmpty {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var pressed = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                MainActor.assumeIsolated { HotKey.actions[pressed.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let id = UInt32(actions.count + 1)
        actions[id] = action
        var ref: EventHotKeyRef?
        let key = EventHotKeyID(signature: 0x5348_5454, id: id) // 'SHTT'
        return RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), key, GetApplicationEventTarget(), 0, &ref) == noErr
    }
}
