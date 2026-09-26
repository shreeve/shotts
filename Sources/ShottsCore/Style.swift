import Foundation

/// A color as four components in 0...1. Core keeps no AppKit, so colors are plain values here
/// and become `NSColor`/`CGColor` only in the renderer.
public struct RGBA: Hashable, Sendable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            alpha: alpha)
    }

    public static let red = RGBA(hex: 0xFF3B30)
    public static let orange = RGBA(hex: 0xFF9500)
    public static let yellow = RGBA(hex: 0xFFCC00)
    public static let green = RGBA(hex: 0x34C759)
    public static let blue = RGBA(hex: 0x007AFF)
    public static let purple = RGBA(hex: 0xAF52DE)
    public static let pink = RGBA(hex: 0xFF2D55)
    public static let gray = RGBA(hex: 0x8E8E93)
    public static let white = RGBA(hex: 0xFFFFFF)
    public static let black = RGBA(hex: 0x000000)

    /// The palette the editor offers, in order: two rows of five.
    public static let palette: [RGBA] = [.red, .orange, .yellow, .green, .blue, .purple, .pink, .gray, .white, .black]

    /// `#RRGGBB`, the way design tools and CSS write it.
    public var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    /// Whether text of this color reads better with a dark outline than a light one.
    public var isLight: Bool { 0.299 * red + 0.587 * green + 0.114 * blue > 0.6 }
}

/// The typeface text annotations use, from the fonts every Mac has. Bold in each case.
public enum FontChoice: String, CaseIterable, Sendable, Codable {
    /// The system font's rounded design: friendly, a little soft, like Droid Sans Bold.
    case rounded
    /// The plain system font.
    case system
    /// Trebuchet MS: humanist, the closest of the built-in fonts to Droid Sans.
    case trebuchet

    public var title: String {
        switch self {
        case .rounded: "Rounded"
        case .system: "System"
        case .trebuchet: "Trebuchet"
        }
    }
}

/// How an annotation is drawn. Lengths are in points, independent of the capture's backing
/// scale; the renderer multiplies by `Document.scale` so a 4-point stroke is 8 pixels on a
/// Retina capture and looks the same size as it would on screen.
public struct Style: Hashable, Sendable, Codable {
    public var color: RGBA
    public var strokeWidth: Double
    public var fontSize: Double
    public var font: FontChoice
    public var shadow: Bool
    public var outline: Bool
    /// Arrows as a thin tail widening into the head (true), or an even shaft with a head.
    public var taperedArrows: Bool

    public init(color: RGBA, strokeWidth: Double, fontSize: Double, font: FontChoice = .rounded, shadow: Bool = true, outline: Bool = true, taperedArrows: Bool = true) {
        self.color = color
        self.strokeWidth = strokeWidth
        self.fontSize = fontSize
        self.font = font
        self.shadow = shadow
        self.outline = outline
        self.taperedArrows = taperedArrows
    }

    enum CodingKeys: String, CodingKey { case color, strokeWidth, fontSize, font, shadow, outline, taperedArrows }

    /// Settings saved by an older build decode with today's defaults for what they lack.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? .red
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 4
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 28
        font = try c.decodeIfPresent(FontChoice.self, forKey: .font) ?? .rounded
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? true
        outline = try c.decodeIfPresent(Bool.self, forKey: .outline) ?? true
        taperedArrows = try c.decodeIfPresent(Bool.self, forKey: .taperedArrows) ?? true
    }

    public static let standard = Style(color: .red, strokeWidth: 4, fontSize: 28)

    public static let strokeWidths: [Double] = [2, 4, 6, 10]
    public static let fontSizes: [Double] = [18, 24, 28, 36, 48]
}
