import Foundation

/// The shortcuts a recording shows as they are pressed: keys with Control, Option, or Command
/// ("⇧⌘4"), and the keys that act on their own (↩, ⎋, ⇥, arrows, F-keys). Typing does not show,
/// letters, numbers, punctuation, and space, with or without Shift, nor the Delete keys that
/// correct it: a viewer needs to see what was done, not what was written, and what is typed
/// stays private. As CleanShot X's and Screen Studio's "shortcuts only". Everything pressed
/// within `joinGap` of the key before joins one line ("⌘I  ⌃K  ↩"), and the line shows until
/// `linger` after its last key, as KeyCastr's line-break delay and linger work.
public struct KeystrokeLine: Equatable, Sendable {
    /// Keys this close together, in seconds, join one line.
    public static let joinGap = 2.0
    /// How long the line shows after its last key, in seconds.
    public static let linger = 5.0
    /// The most characters shown; a longer line shows its end.
    public static let longest = 40
    /// Between keys: wide enough to tell ⌘I from ⌃K at a glance.
    static let gap = "  "

    public private(set) var text = ""
    private var lastKey = -Double.infinity

    public init() {}

    /// A shortcut pressed at `time` (seconds, on any clock that only goes forward), as `key` names it.
    public mutating func add(_ shortcut: String, at time: Double) {
        let continues = !text.isEmpty && time - lastKey < Self.joinGap
        text = (continues ? text + Self.gap : "") + shortcut
        if text.count > Self.longest { text = "…" + text.suffix(Self.longest - 1) }
        lastKey = time
    }

    /// What shows at `time`: nil once the line has lingered its while.
    public func visible(at time: Double) -> String? {
        time - lastKey < Self.linger && !text.isEmpty ? text : nil
    }

    // MARK: - Naming keys

    /// The modifier keys, in the order the Mac writes them.
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    /// The keys with a symbol of their own, by virtual key code.
    static let named: [UInt16: String] = [
        36: "↩", 76: "⌤", 48: "⇥", 49: "␣", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// The keys that are part of typing even though they have a symbol: they correct what is typed.
    static let typingKeys: Set<UInt16> = [51, 117, 49]

    /// A key as it shows, or nil for typing, which does not. `base` is what the key gives with no
    /// modifiers ("4"). With Control, Option, or Command it shows, its modifiers first in the
    /// Mac's order; a key that acts on its own (↩, ⎋, arrows) shows its symbol, with ⇧ if held.
    public static func key(code: UInt16, base: String, modifiers: Modifiers) -> String? {
        let symbol = named[code]
        if !modifiers.isDisjoint(with: [.control, .option, .command]) {
            var prefix = ""
            if modifiers.contains(.control) { prefix += "⌃" }
            if modifiers.contains(.option) { prefix += "⌥" }
            if modifiers.contains(.shift) { prefix += "⇧" }
            if modifiers.contains(.command) { prefix += "⌘" }
            return prefix + (symbol ?? base.uppercased())
        }
        guard let symbol, !typingKeys.contains(code) else { return nil }
        return (modifiers.contains(.shift) ? "⇧" : "") + symbol
    }
}
