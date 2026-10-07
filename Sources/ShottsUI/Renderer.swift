import AppKit
import ShottsCore

/// Draws a document over its capture. The canvas and every export go through here, so the
/// pasted image is exactly what the editor showed.
///
/// Every `draw` expects a context whose user space is image pixels with the origin at the
/// top-left and y growing downward (a flipped context), which is how both the flipped canvas
/// view and `image(of:source:)` set theirs up. `baseScale` is the context's base units per image
/// pixel (the canvas's zoom, 1 for a bitmap of the picture): Core Graphics sizes shadows in base
/// units whatever the CTM, and the renderer converts so a shadow looks the same in both.
public enum Renderer {
    /// Draws the source and the annotations, in image pixels. Annotations wholly outside the
    /// clip are skipped.
    public static func draw(_ document: Document, source: CGImage, in ctx: CGContext, baseScale: Double = 1) {
        let bounds = document.pixelBounds
        ctx.saveGState()
        // The bitmap is stored top row first; drawing it into a flipped context would turn it
        // over, so flip back around the image for this one call.
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        // At a device pixel or more per image pixel, as in every export, nearest neighbor keeps
        // the capture's pixels exact; below that, as in a small editor window, it would drop
        // pixels and shimmer, so the picture is smoothed there.
        ctx.interpolationQuality = ctx.userSpaceToDeviceSpaceTransform.a >= 1 ? .none : .medium
        ctx.draw(source, in: bounds)
        ctx.restoreGState()

        let clip = ctx.boundingBoxOfClipPath
        for annotation in document.annotations where extent(of: annotation, scale: document.scale).intersects(clip) {
            draw(annotation, document: document, source: source, in: ctx, baseScale: baseScale)
        }
    }

    /// One annotation, used by the canvas for the shape being dragged out too.
    public static func draw(_ a: Annotation, document: Document, source: CGImage, in ctx: CGContext, baseScale: Double = 1) {
        let s = document.scale
        let width = a.style.stroke(scale: s)
        let color = cgColor(a.style.color)
        let shadow = a.style.shadow ? 5 * s * baseScale : 0
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // Nothing reaches past the extent. Clipping to it also keeps each transparency layer,
        // which Core Graphics sizes to the clip, as small as the annotation instead of the picture.
        ctx.clip(to: extent(of: a, scale: s))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        func arrow(from: CGPoint, to: CGPoint) {
            let geometry = a.style.arrow(from: from, to: to, scale: s)
            ctx.saveGState()
            setShadow(ctx, blur: shadow)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            // Fill the outline, then stroke it thinly with round joins to soften the corners.
            ctx.setFillColor(color)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(max(width * 0.35, 1))
            ctx.addLines(between: geometry.outline)
            ctx.closePath()
            ctx.drawPath(using: .fillStroke)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }

        switch a.shape {
        case let .arrow(from, to):
            arrow(from: from, to: to)

        case let .callout(from, to, text):
            arrow(from: from, to: to)
            if !text.string.isEmpty {
                drawText(text.string, at: text.origin, size: text.size, alignment: text.alignment, style: a.style, scale: s, shadow: shadow, in: ctx)
            }

        // A stroke is drawn inside the shape. One no wider than its stroke would be all stroke,
        // and the inset outline would be empty and draw nothing, so it is filled instead.
        case let .rectangle(rect, filled):
            let r = rect.standardized
            setShadow(ctx, blur: shadow)
            if filled || min(r.width, r.height) <= width {
                ctx.setFillColor(color)
                ctx.fill(r)
            } else {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(width)
                ctx.stroke(r.insetBy(dx: width / 2, dy: width / 2))
            }

        case let .ellipse(rect, filled):
            let r = rect.standardized
            setShadow(ctx, blur: shadow)
            if filled || min(r.width, r.height) <= width {
                ctx.setFillColor(color)
                ctx.fillEllipse(in: r)
            } else {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(width)
                ctx.strokeEllipse(in: r.insetBy(dx: width / 2, dy: width / 2))
            }

        case let .line(from, to):
            setShadow(ctx, blur: shadow)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(width)
            ctx.move(to: from)
            ctx.addLine(to: to)
            ctx.strokePath()

        case let .pen(points):
            setShadow(ctx, blur: shadow)
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
            ctx.setLineWidth(a.style.highlighterWidth(scale: s))
            ctx.setLineCap(.square)
            addSmoothPath(points, to: ctx)
            ctx.strokePath()

        case let .obscure(rect):
            drawPixelated(source, rect: rect, cell: max(10 * s, 10), in: ctx)

        case let .text(origin, string, size, alignment):
            drawText(string, at: origin, size: size, alignment: alignment, style: a.style, scale: s, shadow: shadow, in: ctx)
        }
    }

    /// The exported image: the visible (cropped) part with every annotation, at pixel size. An
    /// untouched capture is the source itself, with nothing to draw and no second bitmap.
    public static func image(of document: Document, source: CGImage) -> CGImage? {
        if document.isBlank { return source }
        let visible = document.visibleRect
        let width = Int(visible.width), height = Int(visible.height)
        guard width > 0, height > 0, let ctx = bitmap(width: width, height: height, like: source) else { return nil }
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

    /// The style's typeface, bold, at its size scaled to pixels.
    /// A font missing from this build (Open Sans, outside the app bundle) falls back to Rounded.
    public static func font(for style: Style, scale: Double) -> NSFont {
        let size = style.fontSize * scale
        let system = NSFont.systemFont(ofSize: size, weight: .bold)
        let rounded = system.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        switch style.font {
        case .system: return system
        case .rounded: return rounded
        case .openSans: return NSFont(name: "OpenSans-Bold", size: size) ?? rounded
        }
    }

    /// The pixel size the laid-out text will take, for `Annotation.Shape.text`'s `size`. With
    /// `width`, lines wrap to fit it and the size's width is that box, so the export wraps the
    /// same way the editor did.
    public static func textSize(_ string: String, style: Style, scale: Double, width: Double? = nil) -> CGSize {
        let attributed = attributedText(string, style: style, scale: scale)
        let pad = outlineWidth(style, scale: scale)
        var size: CGSize
        if let width {
            // Wrapped at `width`, but the box hugs the words: the widest line, not the room.
            let box = attributed.boundingRect(with: CGSize(width: width - pad * 2, height: .greatestFiniteMagnitude),
                                              options: [.usesLineFragmentOrigin]).size
            size = CGSize(width: box.width + pad * 2, height: box.height)
        } else {
            size = attributed.size()
            size.width += pad * 2
        }
        // Room for the outline, which strokes outside the glyphs: above the first line and below
        // the last as well as at each side.
        size.width = ceil(size.width)
        size.height = ceil(size.height + pad * 2)
        return size
    }

    /// Where a new text's box goes for its caret, before any word, to stand with its foot on
    /// `point`: the words' left edge there, and the bottom of their first line. Kept on the
    /// picture's top and left edges.
    public static func textOrigin(caretFoot point: CGPoint, style: Style, scale: Double) -> CGPoint {
        let pad = outlineWidth(style, scale: scale)
        let line = NSLayoutManager().defaultLineHeight(for: font(for: style, scale: scale))
        return CGPoint(x: max(point.x - pad, 0), y: max(point.y - pad - line, 0))
    }

    /// One line of text in this style, in pixels.
    public static func lineHeight(style: Style, scale: Double) -> Double {
        ceil(attributedText("Ag", style: style, scale: scale).size().height + outlineWidth(style, scale: scale) * 2)
    }

    /// Everything an annotation may paint, its shadow and outline included, in image pixels.
    public static func extent(of a: Annotation, scale s: Double) -> CGRect {
        let ink: CGRect
        switch a.shape {
        case let .arrow(from, to):
            ink = Annotation.bounds(of: a.style.arrow(from: from, to: to, scale: s).outline)
        case let .callout(from, to, text):
            ink = Annotation.bounds(of: a.style.arrow(from: from, to: to, scale: s).outline).union(text.frame)
        case .highlighter:
            ink = a.bounds.insetBy(dx: -a.style.highlighterWidth(scale: s) / 2, dy: -a.style.highlighterWidth(scale: s) / 2)
        case .text, .obscure:
            ink = a.bounds
        case .rectangle, .ellipse, .pen, .line:
            ink = a.bounds.insetBy(dx: -a.style.stroke(scale: s), dy: -a.style.stroke(scale: s))
        }
        // The arrow's softening stroke, a text outline's top, and a shadow's blur reach past the
        // ink; 20 points covers all three with room to spare. The shadow's blur grows with
        // `baseScale`, which stays at most 1 because the canvas never zooms past on-screen size
        // (`EditorLayout`); a canvas that zoomed in would need the extent to grow with it.
        let reach = 20 * s + a.style.stroke(scale: s) + outlineWidth(a.style, scale: s)
        return ink.insetBy(dx: -reach, dy: -reach)
    }

    // MARK: - Pieces

    static func cgColor(_ c: RGBA) -> CGColor {
        CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }

    /// A soft, even shadow all around, the way macOS shadows its own controls; none for a blur
    /// of 0. It has no offset on purpose: Core Graphics applies a shadow offset in base space,
    /// untouched by the CTM, so in the editor's flipped space a "downward" offset came out
    /// pointing up.
    static func setShadow(_ ctx: CGContext, blur: Double) {
        guard blur > 0 else { return }
        ctx.setShadow(offset: .zero, blur: blur, color: CGColor(gray: 0, alpha: 0.55))
    }

    static func outlineWidth(_ style: Style, scale: Double) -> Double {
        style.outline ? style.fontSize * scale * 0.09 : 0
    }

    static func attributedText(_ string: String, style: Style, scale: Double) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font(for: style, scale: scale)])
    }

    static func drawText(_ string: String, at origin: CGPoint, size: CGSize, alignment: TextAlignment, style: Style, scale: Double,
                         shadow: Double, in ctx: CGContext) {
        let font = font(for: style, scale: scale)
        let pad = outlineWidth(style, scale: scale)
        let paragraph = NSMutableParagraphStyle()
        switch alignment {
        case .left: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        }
        // The box the text was measured in; lines wrap inside it exactly as they were measured.
        let box = CGRect(x: origin.x + pad, y: origin.y + pad, width: max(size.width - pad * 2, 1), height: size.height)
        let fill = NSColor(cgColor: cgColor(style.color)) ?? .red
        let outline: NSColor = style.color.isLight ? .black : .white
        // AppKit's string drawing wants a current NSGraphicsContext; the canvas has one, and
        // `image(of:)` installs one around the draw.
        setShadow(ctx, blur: shadow)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        if pad > 0 {
            // Stroke first, then fill on top, so the outline sits outside the letters.
            NSAttributedString(string: string, attributes: [
                .font: font, .strokeColor: outline, .strokeWidth: pad / font.pointSize * 100 * 2, .paragraphStyle: paragraph,
            ]).draw(with: box, options: [.usesLineFragmentOrigin])
        }
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: fill, .paragraphStyle: paragraph])
            .draw(with: box, options: [.usesLineFragmentOrigin])
        ctx.endTransparencyLayer()
    }

    /// A bitmap for drawing the source into, in the source's color space when a bitmap can use
    /// it, so a Display P3 capture keeps the colors sRGB would clip; otherwise sRGB.
    static func bitmap(width: Int, height: Int, like source: CGImage) -> CGContext? {
        func make(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        }
        if let space = source.colorSpace, space.model == .rgb, space.supportsOutput, let ctx = make(space) { return ctx }
        return make(CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// Blocks of about `cell` pixels over the source under `rect`, drawn from the source each
    /// time rather than cached. The rect grows to whole pixels, so no pixel on its edge keeps a
    /// share of what was there. Each block is its cell's mean color rounded to 16 levels a
    /// channel: exact means are what Depix-style attacks match against text in a known font.
    static func drawPixelated(_ source: CGImage, rect: CGRect, cell: Double, in ctx: CGContext) {
        let rect = rect.integral.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard !rect.isEmpty, let piece = source.cropping(to: rect) else { return }
        let small = CGSize(width: max(1, (rect.width / cell).rounded(.up)), height: max(1, (rect.height / cell).rounded(.up)))
        guard let tiny = bitmap(width: Int(small.width), height: Int(small.height), like: source), let data = tiny.data else { return }
        tiny.interpolationQuality = .medium
        tiny.draw(piece, in: CGRect(origin: .zero, size: small))
        // Rounding every byte alike keeps premultiplied color no greater than its alpha.
        let bytes = UnsafeMutableRawBufferPointer(start: data, count: tiny.bytesPerRow * tiny.height)
        for i in bytes.indices { bytes[i] = UInt8((Int(bytes[i]) + 8) / 17 * 17) }
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
