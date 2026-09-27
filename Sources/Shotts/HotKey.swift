import AppKit
import Carbon

/// F10, system-wide, registered through Carbon so it needs no Accessibility permission. Only
/// this key reaches Shotts; nothing else is observed. It lives as long as the app: there is no
/// unregistering, by design.
enum HotKey {
    private static var action: (() -> Void)?

    /// Runs `action` whenever F10 is pressed. Returns false when F10 could not be registered,
    /// which is what happens when another app already holds it.
    static func registerF10(_ action: @escaping () -> Void) -> Bool {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x5348_5454, id: 1) // 'SHTT'
        return RegisterEventHotKey(UInt32(kVK_F10), 0, id, GetApplicationEventTarget(), 0, &ref) == noErr
    }
}
