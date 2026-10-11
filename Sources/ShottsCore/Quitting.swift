/// What Quit does, and what it says before it loses anything: open captures annotated (drawn on
/// or cropped), and recordings not yet saved, copied, or dragged out. A plain capture is not
/// counted (it is on the clipboard, or nothing was done to it), nor anything already closed.
public enum Quitting {
    public enum Reply: Equatable, Sendable {
        /// Shotts quits at once.
        case now
        /// The recording or scrolling capture under way stops and opens, and Shotts stays.
        case stop
        /// Shotts asks first, with this warning.
        case ask(String)
    }

    /// A log-out, restart, or shut-down (`poweringOff`) is never held up: Shotts quits at once,
    /// and a recording under way, or anything unsaved, goes with it, as macOS asked. Otherwise a
    /// recording or a scrolling capture `underWay` stops rather than being lost, and quitting again
    /// quits, asking about what is open then; with nothing under way, Shotts asks only when
    /// something would be lost.
    public static func reply(poweringOff: Bool, underWay: Bool, captures: Int, recordings: Int) -> Reply {
        if poweringOff { return .now }
        if underWay { return .stop }
        return warning(captures: captures, recordings: recordings).map(Reply.ask) ?? .now
    }

    /// The warning, or nil when nothing would be lost and Shotts quits without asking.
    public static func warning(captures: Int, recordings: Int) -> String? {
        let parts = [count(captures, "annotated capture"), count(recordings, "unsaved recording")].compactMap { $0 }
        guard let first = parts.first else { return nil }
        let words = parts.count == 1 ? first : parts.joined(separator: " and ")
        return words.prefix(1).uppercased() + words.dropFirst() + " will be lost."
    }

    private static func count(_ n: Int, _ thing: String) -> String? {
        switch n {
        case ..<1: nil
        case 1: "an \(thing)"
        default: "\(n) \(thing)s"
        }
    }
}
