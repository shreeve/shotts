import Foundation

/// macOS's own keyboard shortcuts, as System Settings › Keyboard › Keyboard Shortcuts keeps them
/// (`AppleSymbolicHotKeys` in `com.apple.symbolichotkeys`), and whether one of them is a given
/// key. Shotts answers ⇧⌘2 only while macOS does not, which out of the box it never does: two
/// apps holding a key both answer it, and two crosshairs at once would be worse than none.
public enum SystemShortcuts {
    /// Modifiers as macOS writes them there (and as `NSEvent` has them).
    public static let shift = 0x2_0000, option = 0x8_0000, command = 0x10_0000
    /// The key code of "2".
    public static let two = 19

    /// Whether macOS answers `keyCode` with exactly `modifiers` itself: one of its shortcuts on
    /// and set to it. `shortcuts` is `AppleSymbolicHotKeys` as read, nil when unreadable. A
    /// shortcut the user has set is written out with its key; one with no key written is at its
    /// default, and none of macOS's defaults is on "2".
    public static func macOSAnswers(keyCode: Int, modifiers: Int, in shortcuts: [String: Any]?) -> Bool {
        (shortcuts ?? [:]).values.contains { value in
            guard let entry = value as? [String: Any], (entry["enabled"] as? NSNumber)?.boolValue ?? false,
                  let parameters = ((entry["value"] as? [String: Any])?["parameters"] as? [NSNumber])?.map(\.intValue),
                  parameters.count == 3
            else { return false }
            return parameters[1] == keyCode && parameters[2] & 0xFF_0000 == modifiers
        }
    }
}
