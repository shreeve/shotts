import Foundation

/// A table as `shotts` prints it. On a terminal, `boxed`: a rounded box with a tab on top for
/// its title, bold headings, color on what is worth copying, and notes under it, dim. Anywhere
/// else, `plain`: columns two spaces apart, no color, for scripts to read. Widths are measured
/// in terminal columns, so wide characters in a window's title still line up, and the one
/// flexible column is cut with an ellipsis to fit the terminal.
public struct TextTable: Sendable {
    public enum Align: Sendable { case left, right }
    public enum Tint: Sendable { case none, bold, dim, accent, path }

    public struct Column: Sendable {
        public var head: String
        public var align: Align
        public var tint: Tint
        /// Cut to fit the terminal; at most one column should be.
        public var flexible: Bool

        public init(_ head: String, align: Align = .left, tint: Tint = .none, flexible: Bool = false) {
            self.head = head
            self.align = align
            self.tint = tint
            self.flexible = flexible
        }
    }

    public var title: String?
    public var columns: [Column]
    public var rows: [[String]]
    /// Lines under the table, for a person: dim and indented when boxed, left out when plain.
    public var notes: [String]

    public init(title: String? = nil, columns: [Column], rows: [[String]], notes: [String] = []) {
        self.title = title
        self.columns = columns
        self.rows = rows
        self.notes = notes
    }

    /// Columns two spaces apart, headings first, the flexible column cut to `width` if given.
    public func plain(width: Int? = nil) -> String {
        let widths = fitted(to: width, overhead: 2 * (columns.count - 1))
        return ([columns.map(\.head)] + rows).enumerated().map { n, row in
            // Headings start at the left, over numbers too.
            let cells = row.indices.map { i in Self.pad(Self.cut(row[i], to: widths[i]), widths[i], n == 0 ? .left : columns[i].align) }
            return cells.joined(separator: "  ").replacing(/\s+$/, with: "") + "\n"
        }.joined()
    }

    /// The rounded box, with ANSI color if `color`.
    public func boxed(width: Int? = nil, color: Bool) -> String {
        func paint(_ text: String, _ tint: Tint) -> String {
            guard color, !text.isEmpty else { return text }
            let code = switch tint {
            case .none: ""
            case .bold: "1"
            case .dim: "2"
            case .accent: "36"
            case .path: "32"
            }
            return code.isEmpty ? text : "\u{1B}[\(code)m\(text)\u{1B}[0m"
        }
        // Each column is "│ cell " wide, and one "│" closes the row.
        var widths = fitted(to: width, overhead: 3 * columns.count + 1)
        let tab = title.map { " \($0) " }
        if let tab {
            // The table is at least as wide as its tab.
            let short = Self.columns(tab) + 2 - (widths.reduce(0, +) + 3 * columns.count + 1)
            if short > 0 { widths[widths.count - 1] += short }
        }
        var stops = [0]
        for w in widths { stops.append(stops[stops.count - 1] + w + 3) }
        let right = stops[stops.count - 1]

        func rule(_ left: Character, _ mid: Character, _ end: Character, tabEdge: Int? = nil) -> String {
            var line = [Character](repeating: "─", count: right + 1)
            line[0] = left
            for stop in stops.dropFirst().dropLast() { line[stop] = mid }
            line[right] = end
            if let edge = tabEdge {
                line[edge] = edge == right ? "┤" : (stops.contains(edge) ? "┼" : "┴")
            }
            return String(line) + "\n"
        }
        func row(_ cells: [String], heading: Bool) -> String {
            var line = "│"
            for (i, column) in columns.enumerated() {
                let text = Self.cut(cells[i], to: widths[i])
                let padded = Self.pad(text, widths[i], heading ? .left : column.align)
                let lead = String(padded.prefix { $0 == " " })
                let body = padded.dropFirst(lead.count)
                let trimmed = String(body.replacing(/\s+$/, with: ""))
                let trail = String(repeating: " ", count: body.count - trimmed.count)
                line += " " + lead + paint(trimmed, heading ? .bold : column.tint) + trail + " │"
            }
            return line + "\n"
        }

        var out = ""
        if let tab {
            let edge = Self.columns(tab) + 1
            out += "╭" + String(repeating: "─", count: edge - 1) + "╮\n"
            out += "│" + paint(tab, .bold) + "│\n"
            out += rule("├", "┬", "╮", tabEdge: edge)
        } else {
            out += rule("╭", "┬", "╮")
        }
        out += row(columns.map(\.head), heading: true)
        for r in rows { out += row(r, heading: false) }
        out += rule("╰", "┴", "╯")
        if !notes.isEmpty {
            out += "\n" + notes.map { "  " + paint($0, .dim) + "\n" }.joined()
        }
        return out
    }

    // MARK: - Measuring

    /// Each column's width, the flexible one narrowed so the table fits `width` with
    /// `overhead` columns of borders and gaps, but never below eight.
    private func fitted(to width: Int?, overhead: Int) -> [Int] {
        var widths = columns.indices.map { i in ([columns[i].head] + rows.map { $0[i] }).map(Self.columns).max() ?? 0 }
        if let width, let flexible = columns.firstIndex(where: \.flexible) {
            let over = widths.reduce(0, +) + overhead - width
            if over > 0 { widths[flexible] = max(widths[flexible] - over, min(widths[flexible], 8)) }
        }
        return widths
    }

    /// How many terminal columns `text` takes: two for wide characters (CJK, emoji), else one.
    public static func columns(_ text: String) -> Int {
        text.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
    }

    private static func isWide(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first else { return false }
        if s.properties.isEmojiPresentation || c.unicodeScalars.contains("\u{FE0F}") { return true }
        switch s.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    /// `text` cut to `width` columns, ending in an ellipsis when cut.
    static func cut(_ text: String, to width: Int) -> String {
        guard columns(text) > width else { return text }
        var out = ""
        var used = 0
        for c in text {
            let w = isWide(c) ? 2 : 1
            if used + w > width - 1 { break }
            out.append(c)
            used += w
        }
        return out + "…"
    }

    static func pad(_ text: String, _ width: Int, _ align: Align) -> String {
        let room = String(repeating: " ", count: max(width - columns(text), 0))
        return align == .left ? text + room : room + text
    }
}
