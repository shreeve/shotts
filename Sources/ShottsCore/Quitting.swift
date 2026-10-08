/// What quitting would lose, said before it does: open captures with annotations or a crop,
/// and recordings not yet saved, copied, or dragged out. A plain capture is not counted (it is on
/// the clipboard, or nothing was done to it), nor anything already closed.
public enum Quitting {
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
