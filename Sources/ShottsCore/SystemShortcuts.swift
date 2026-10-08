import Foundation

/// macOS's own keyboard shortcuts, as System Settings › Keyboard › Keyboard Shortcuts keeps them
/// (`AppleSymbolicHotKeys` in `com.apple.symbolichotkeys`), and whether one of them is a given
/// key. Shotts answers ⇧⌘4 only once macOS no longer does: two apps holding a key both answer it,
/// and two crosshairs at once would be worse than none.
public enum SystemShortcuts {
    /// Modifiers as macOS writes them there (and as `NSEvent` has them).
    public static let shift = 0x2_0000, control = 0x4_0000, option = 0x8_0000, command = 0x10_0000
    /// The key code of "4".
    public static let four = 21

    /// The shortcuts on ⇧⌘4 and ⌃⇧⌘4 until the user changes them, which an entry missing from
    /// the list means: area to a file, and area to the clipboard.
    static let defaults: [String: (keyCode: Int, modifiers: Int)] = [
        "30": (four, shift | command),
        "31": (four, control | shift | command),
    ]

    /// Whether macOS answers `keyCode` with exactly `modifiers` itself: one of its shortcuts on
    /// and set to it. `shortcuts` is `AppleSymbolicHotKeys` as read, nil when unreadable.
    public static func macOSAnswers(keyCode: Int, modifiers: Int, in shortcuts: [String: Any]?) -> Bool {
        let shortcuts = shortcuts ?? [:]
        for (id, key) in defaults where shortcuts[id] == nil && key == (keyCode, modifiers) { return true }
        return shortcuts.contains { id, value in
            guard let entry = value as? [String: Any], (entry["enabled"] as? NSNumber)?.boolValue ?? false else { return false }
            let parameters = ((entry["value"] as? [String: Any])?["parameters"] as? [NSNumber])?.map(\.intValue)
            guard let parameters, parameters.count == 3 else {
                // On, with no key of its own written: at its default.
                return defaults[id].map { $0 == (keyCode, modifiers) } ?? false
            }
            return parameters[1] == keyCode && parameters[2] & 0xFF_0000 == modifiers
        }
    }
}
