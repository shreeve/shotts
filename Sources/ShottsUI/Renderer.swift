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

        case let .text(origin, string, _):
            drawText(string, at: origin, style: a.style, scale: s, in: ctx)
        }
    }

    /// The exported image: the visible (cropped) part with every annotation, at pixel size.
    public static func image(of document: Document, source: CGImage) -> CGImage? {
        let visible = document.visibleRect
        let width = Int(visible.width), height = Int(visible.height)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // Flip so the document's top-left origin lands at the bitmap's top-left.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -visible.minX, y: -visible.minY)
        let nsContext = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        draw(document, source: source, in: ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    public static func pngData(of document: Document, source: CGImage) -> Data? {
        guard let image = image(of: document, source: source) else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    /// The font every text annotation uses, at the style's size scaled to pixels.
    public static func font(for style: Style, scale: Double) -> NSFont {
        NSFont.systemFont(ofSize: style.fontSize * scale, weight: .bold)
    }

    /// The pixel size the laid-out text will take, for `Annotation.Shape.text`'s `size`.
    public static func textSize(_ string: String, style: Style, scale: Double) -> CGSize {
        let attributed = attributedText(string, style: style, scale: scale)
        var size = attributed.size()
        // Room for the outline, which strokes outside the glyph.
        let pad = outlineWidth(style, scale: scale)
        size.width = ceil(size.width + pad * 2)
        size.height = ceil(size.height + pad)
        return size
    }

    // MARK: - Pieces

    static func cgColor(_ c: RGBA) -> CGColor {
        CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }

    /// A soft shadow below and to the right. Offsets are given in the flipped user space, so a
    /// positive y is downward on the picture.
    static func setShadow(_ ctx: CGContext, scale: Double) {
        ctx.setShadow(offset: CGSize(width: 0, height: 1.5 * scale), blur: 3 * scale,
                      color: CGColor(gray: 0, alpha: 0.45))
    }

    static func outlineWidth(_ style: Style, scale: Double) -> Double {
        style.outline ? style.fontSize * scale * 0.09 : 0
    }

    static func attributedText(_ string: String, style: Style, scale: Double) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font(for: style, scale: scale)])
    }

    static func drawText(_ string: String, at origin: CGPoint, style: Style, scale: Double, in ctx: CGContext) {
        let font = font(for: style, scale: scale)
        let pad = outlineWidth(style, scale: scale)
        let point = CGPoint(x: origin.x + pad, y: origin.y)
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
            ]).draw(at: point)
        }
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: fill]).draw(at: point)
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
