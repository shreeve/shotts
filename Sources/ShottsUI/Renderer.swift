import AppKit
import ShottsCore

/// Draws a document over its capture. The canvas and every export go through here, so the
/// pasted image is exactly what the editor showed.
///
/// Every `draw` expects a context whose user space is image pixels with the origin at the
/// top-left and y growing downward (a flipped context), which is how both the flipped canvas
/// view and `image(of:source:)` set theirs up.
public enum Renderer {
    /// Draws the source and the annotations, in image pixels.
    public static func draw(_ document: Document, source: CGImage, in ctx: CGContext) {
        let bounds = document.pixelBounds
        ctx.saveGState()
        // The bitmap is stored top row first; drawing it into a flipped context would turn it
        // over, so flip back around the image for this one call.
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .none
        ctx.draw(source, in: bounds)
        ctx.restoreGState()

        for annotation in document.annotations {
            draw(annotation, document: document, source: source, in: ctx)
        }
    }

    /// One annotation, used by the canvas for the shape being dragged out too.
    public static func draw(_ a: Annotation, document: Document, source: CGImage, in ctx: CGContext) {
        let s = document.scale
        let width = a.style.strokeWidth * s
        let color = cgColor(a.style.color)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch a.shape {
        case let .arrow(from, to):
            let geometry = ArrowGeometry(from: from, to: to, width: width, tapered: a.style.taperedArrows)
            if a.style.shadow { setShadow(ctx, scale: s) }
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            // Fill the outline, then stroke it thinly with round joins to soften the corners.
            ctx.setFillColor(color)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(max(width * 0.35, 1))
            ctx.addLines(between: geometry.outline)
            ctx.closePath()
            ctx.drawPath(using: .fillStroke)
            ctx.endTransparencyLayer()

        case let .rectangle(rect):
            if a.style.shadow { setShadow(ctx, scale: s) }
            ctx.setStrokeColor(color)
            ctx.setLineWidth(width)
            ctx.stroke(rect.standardized.insetBy(dx: width / 2, dy: width / 2))

        case let .ellipse(rect):
            if a.style.shadow { setShadow(ctx, scale: s) }
            ctx.setStrokeColor(color)
            ctx.setLineWidth(width)
            ctx.strokeEllipse(in: rect.standardized.insetBy(dx: width / 2, dy: width / 2))

        case let .pen(points):
            if a.style.shadow { setShadow(ctx, scale: s) }
            ctx.setStrokeColor(color)
            ctx.setLineWidth(width)
            addSmoothPath(points, to: ctx)
            ctx.strokePath()

        case let .highlighter(points):
            // Plain translucency rather than multiply: multiply is a truer highlighter on white
            // but disappears over dark backgrounds, which screenshots are full of.
            var c = a.style.color
            c.alpha = 0.45
            ctx.setStrokeColor(cgColor(c))
            ctx.setLineWidth(max(width * 3, 12 * s))
            ctx.setLineCap(.square)
            addSmoothPath(points, to: ctx)
            ctx.strokePath()

        case let .obscure(rect):
            drawPixelated(source, rect: rect.standardized.intersection(document.pixelBounds), cell: max(8 * s, 8), in: ctx)

        case let .text(origin, string, size):
            drawText(string, at: origin, size: size, style: a.style, scale: s, in: ctx)
        }
    }

    /// The exported image: the visible (cropped) part with every annotation, at pixel size.
    /// With `shadow`, a transparent margin around it holds a soft shadow that follows the
    /// picture's own edge, rounded corners and all.
    public static func image(of document: Document, source: CGImage, shadow: Bool = false) -> CGImage? {
        let visible = document.visibleRect
        let s = document.scale
        let margin = shadow ? (shadowMargin * s).rounded() : 0
        let width = Int(visible.width + margin * 2), height = Int(visible.height + margin * 2)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        if shadow {
            // Set before the flip: the offset is in device space, where down is negative.
            ctx.setShadow(offset: CGSize(width: 0, height: -shadowDrop * s), blur: shadowBlur * s, color: CGColor(gray: 0, alpha: 0.38))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        // Flip so the document's top-left origin lands at the bitmap's top-left, inside the margin.
        ctx.translateBy(x: margin, y: CGFloat(height) - margin)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -visible.minX, y: -visible.minY)
        ctx.clip(to: visible)
        let nsContext = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        draw(document, source: source, in: ctx)
        NSGraphicsContext.restoreGraphicsState()
        if shadow { ctx.endTransparencyLayer() }
        return ctx.makeImage()
    }

    /// The shadow's room around an exported picture, its drop, and its blur, in points. The
    /// drop is large next to the blur on purpose: the shadow gathers below the picture and
    /// barely shows above it, the way a window's does on macOS.
    public static let shadowMargin: CGFloat = 44
    static let shadowDrop: CGFloat = 14
    static let shadowBlur: CGFloat = 22

    public static func pngData(of document: Document, source: CGImage, shadow: Bool = false) -> Data? {
        guard let image = image(of: document, source: source, shadow: shadow) else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    /// The font every text annotation uses, at the style's size scaled to pixels.
    public static func font(for style: Style, scale: Double) -> NSFont {
        NSFont.systemFont(ofSize: style.fontSize * scale, weight: .bold)
    }

    /// The pixel size the laid-out text will take, for `Annotation.Shape.text`'s `size`. With
    /// `width`, lines wrap to fit it and the size's width is that box, so the export wraps the
    /// same way the editor did.
    public static func textSize(_ string: String, style: Style, scale: Double, width: Double? = nil) -> CGSize {
        let attributed = attributedText(string, style: style, scale: scale)
        let pad = outlineWidth(style, scale: scale)
        var size: CGSize
        if let width {
            let box = attributed.boundingRect(with: CGSize(width: width - pad * 2, height: .greatestFiniteMagnitude),
                                              options: [.usesLineFragmentOrigin]).size
            size = CGSize(width: width, height: box.height)
        } else {
            size = attributed.size()
            size.width += pad * 2
        }
        // Room for the outline, which strokes outside the glyph.
        size.width = ceil(size.width)
        size.height = ceil(size.height + pad)
        return size
    }

    /// One line of text in this style, in pixels.
    public static func lineHeight(style: Style, scale: Double) -> Double {
        ceil(attributedText("Ag", style: style, scale: scale).size().height + outlineWidth(style, scale: scale))
    }

    // MARK: - Pieces

    static func cgColor(_ c: RGBA) -> CGColor {
        CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }

    /// A soft, even shadow all around, the way macOS shadows its own controls. It has no
    /// offset on purpose: Core Graphics applies a shadow offset in device space, so in the
    /// editor's flipped space a "downward" offset came out pointing up.
    static func setShadow(_ ctx: CGContext, scale: Double) {
        ctx.setShadow(offset: .zero, blur: 5 * scale, color: CGColor(gray: 0, alpha: 0.55))
    }

    static func outlineWidth(_ style: Style, scale: Double) -> Double {
        style.outline ? style.fontSize * scale * 0.09 : 0
    }

    static func attributedText(_ string: String, style: Style, scale: Double) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font(for: style, scale: scale)])
    }

    static func drawText(_ string: String, at origin: CGPoint, size: CGSize, style: Style, scale: Double, in ctx: CGContext) {
        let font = font(for: style, scale: scale)
        let pad = outlineWidth(style, scale: scale)
        // The box the text was measured in; lines wrap inside it exactly as they were measured.
        let box = CGRect(x: origin.x + pad, y: origin.y, width: max(size.width - pad * 2, 1), height: size.height + pad)
        let fill = NSColor(cgColor: cgColor(style.color)) ?? .red
        let outline: NSColor = style.color.isLight ? .black : .white
        // AppKit's string drawing wants a current NSGraphicsContext; the canvas has one, and
        // `image(of:)` installs one around the draw.
        if style.shadow { setShadow(ctx, scale: scale) }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        if pad > 0 {
            // Stroke first, then fill on top, so the outline sits outside the letters.
            NSAttributedString(string: string, attributes: [
                .font: font, .strokeColor: outline, .strokeWidth: pad / font.pointSize * 100 * 2,
            ]).draw(with: box, options: [.usesLineFragmentOrigin])
        }
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: fill])
            .draw(with: box, options: [.usesLineFragmentOrigin])
        ctx.endTransparencyLayer()
    }

    static func drawPixelated(_ source: CGImage, rect: CGRect, cell: Double, in ctx: CGContext) {
        guard !rect.isEmpty, let piece = source.cropping(to: rect) else { return }
        let small = CGSize(width: max(1, (rect.width / cell).rounded(.up)), height: max(1, (rect.height / cell).rounded(.up)))
        guard let tiny = CGContext(data: nil, width: Int(small.width), height: Int(small.height), bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        tiny.interpolationQuality = .medium
        tiny.draw(piece, in: CGRect(origin: .zero, size: small))
        guard let blocks = tiny.makeImage() else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.maxY + rect.minY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .none
        ctx.draw(blocks, in: rect)
        ctx.restoreGState()
    }

    /// A Catmull-Rom spline through the points, so pen strokes are smooth rather than polygonal.
    static func addSmoothPath(_ points: [CGPoint], to ctx: CGContext) {
        guard let first = points.first else { return }
        ctx.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { ctx.addLine(to: $0) }
            return
        }
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            ctx.addCurve(to: p2, control1: c1, control2: c2)
        }
    }
}
