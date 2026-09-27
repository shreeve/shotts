import AppKit
import Carbon

/// F10 and Option-F10, system-wide, registered through Carbon so they need no Accessibility
/// permission. Only these keys reach Shotts; nothing else is observed. They live as long as the
/// app: there is no unregistering, by design.
enum HotKey {
    private static var actions: [UInt32: () -> Void] = [:]

    /// Runs `action` whenever F10 is pressed with exactly `modifiers` (Carbon's, such as
    /// `optionKey`). Returns false when the key could not be registered, which is what happens
    /// when another app already holds it.
    static func registerF10(modifiers: Int = 0, _ action: @escaping () -> Void) -> Bool {
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
        return RegisterEventHotKey(UInt32(kVK_F10), UInt32(modifiers), key, GetApplicationEventTarget(), 0, &ref) == noErr
    }
}
