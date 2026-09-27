import CoreGraphics
import Foundation

/// A color as four components in 0...1. Core keeps no AppKit, so colors are plain values here
/// and become `NSColor`/`CGColor` only in the renderer.
public struct RGBA: Equatable, Sendable, Codable {
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

/// The typeface text annotations use: the fonts every Mac has, and Open Sans, which the app
/// bundles. Bold in each case.
public enum FontChoice: String, CaseIterable, Sendable, Codable {
    /// The system font's rounded design: friendly, a little soft, like Droid Sans Bold.
    case rounded
    /// The plain system font.
    case system
    /// Trebuchet MS: humanist, the closest of the built-in fonts to Droid Sans.
    case trebuchet
    /// Open Sans: Droid Sans redrawn by its own designer. It ships inside the app under the SIL
    /// Open Font License (`Support/Fonts`).
    case openSans

    public var title: String {
        switch self {
        case .rounded: "Rounded"
        case .system: "System"
        case .trebuchet: "Trebuchet"
        case .openSans: "Open Sans"
        }
    }
}

/// How an annotation is drawn. Lengths are in points, independent of the capture's backing
/// scale; the renderer multiplies by `Document.scale` so a 4-point stroke is 8 pixels on a
/// Retina capture and looks the same size as it would on screen.
public struct Style: Equatable, Sendable, Codable {
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

    /// Settings saved by another build decode with today's defaults for whatever is missing or
    /// unknown (a font this build does not have), keeping the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Style.standard
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
        color = value(.color, d.color)
        strokeWidth = value(.strokeWidth, d.strokeWidth)
        fontSize = value(.fontSize, d.fontSize)
        font = value(.font, d.font)
        shadow = value(.shadow, d.shadow)
        outline = value(.outline, d.outline)
        taperedArrows = value(.taperedArrows, d.taperedArrows)
    }

    /// This style with whatever changed between `old` and `new` applied, and nothing else: picking
    /// a color for a selected arrow recolors it without also resizing it to the bar's width.
    public func applying(from old: Style, to new: Style) -> Style {
        var s = self
        if old.color != new.color { s.color = new.color }
        if old.strokeWidth != new.strokeWidth { s.strokeWidth = new.strokeWidth }
        if old.fontSize != new.fontSize { s.fontSize = new.fontSize }
        if old.font != new.font { s.font = new.font }
        if old.shadow != new.shadow { s.shadow = new.shadow }
        if old.outline != new.outline { s.outline = new.outline }
        if old.taperedArrows != new.taperedArrows { s.taperedArrows = new.taperedArrows }
        return s
    }

    public static let standard = Style(color: .red, strokeWidth: 4, fontSize: 28)

    public static let strokeWidths: [Double] = [2, 4, 6, 10]
    public static let fontSizes: [Double] = [18, 24, 28, 36, 48]
}

/// Lengths in pixels at a capture's scale: the one place `Style`'s points become pixels, used by
/// the renderer to draw and by hit testing to find what was drawn.
extension Style {
    public func stroke(scale: Double) -> Double { strokeWidth * scale }

    /// A highlighter is three strokes wide, and never under 12 points.
    public func highlighterWidth(scale: Double) -> Double { max(strokeWidth * 3, 12) * scale }

    public func arrow(from: CGPoint, to: CGPoint, scale: Double) -> ArrowGeometry {
        ArrowGeometry(from: from, to: to, width: stroke(scale: scale), tapered: taperedArrows)
    }
}
