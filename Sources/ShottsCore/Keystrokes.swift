import Foundation

/// The keys a recording shows as they are pressed, as Shotts writes them: typing collects into
/// one line ("hello⌫"), and a shortcut, a key with Control, Option, or Command, shows on its
/// own ("⌘⇧4"). The line goes once no key has come for a moment.
public struct KeystrokeLine: Equatable, Sendable {
    /// One key, as it shows.
    public struct Key: Equatable, Sendable {
        public var text: String
        /// Typing, which joins the line; a shortcut stands alone.
        public var isTyping: Bool

        public init(text: String, isTyping: Bool) {
            self.text = text
            self.isTyping = isTyping
        }
    }

    /// How long the line shows after its last key, in seconds.
    public static let linger = 1.5
    /// The most characters shown; a longer line shows its end.
    public static let longest = 32

    public private(set) var text = ""
    private var lastKey = -Double.infinity
    private var typing = false

    public init() {}

    /// A key pressed at `time` (seconds, on any clock that only goes forward).
    public mutating func add(_ key: Key, at time: Double) {
        let continues = key.isTyping && typing && time - lastKey < Self.linger
        text = continues ? text + key.text : key.text
        if text.count > Self.longest { text = "…" + text.suffix(Self.longest - 1) }
        typing = key.isTyping
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

    /// A key as it shows: `base` is what the key gives with no modifiers ("4"), `typed` what it
    /// typed ("$" with Shift). With Control, Option, or Command it is a shortcut, its modifiers
    /// first; otherwise what was typed, or the key's symbol, a space written as one after other
    /// typing.
    public static func key(code: UInt16, base: String, typed: String, modifiers: Modifiers) -> Key {
        let symbol = named[code]
        if !modifiers.isDisjoint(with: [.control, .option, .command]) {
            var prefix = ""
            if modifiers.contains(.control) { prefix += "⌃" }
            if modifiers.contains(.option) { prefix += "⌥" }
            if modifiers.contains(.shift) { prefix += "⇧" }
            if modifiers.contains(.command) { prefix += "⌘" }
            return Key(text: prefix + (symbol ?? base.uppercased()), isTyping: false)
        }
        if code == 49 { return Key(text: " ", isTyping: true) }
        if let symbol { return Key(text: (modifiers.contains(.shift) ? "⇧" : "") + symbol, isTyping: true) }
        return Key(text: typed, isTyping: true)
    }
}
