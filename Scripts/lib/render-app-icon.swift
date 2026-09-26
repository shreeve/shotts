// Renders the app icon into an .iconset directory, drawing it here rather than from artwork:
// the icon is the menu bar's camera.viewfinder symbol on a gradient tile, so the two match.
// usage: swift render-app-icon.swift ICONSET_DIR [PREVIEW.png]
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: render-app-icon.swift ICONSET_DIR [PREVIEW.png]\n".utf8))
    exit(64)
}
let iconset = URL(fileURLWithPath: arguments[1])

/// Draws the icon on a 1024-point canvas scaled to `pixels`. Apple's grid: the tile is 824
/// wide with 100 of margin on every side, where the Dock shadow lives.
func draw(pixels: Int, shadow: Bool) -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { exit(1) }
    let s = CGFloat(pixels) / 1024
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let ctx = context.cgContext
    ctx.scaleBy(x: s, y: s)

    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let radius: CGFloat = 824 * 0.2237
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

    // The Dock shadow, outside the tile.
    if shadow {
        NSGraphicsContext.saveGraphicsState()
        let dock = NSShadow()
        dock.shadowColor = NSColor(calibratedRed: 0, green: 0.05, blue: 0.2, alpha: 0.35)
        dock.shadowBlurRadius = 24 * s
        dock.shadowOffset = NSSize(width: 0, height: -12 * s)
        dock.set()
        NSColor.black.setFill()
        tilePath.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // The tile: indigo at the top left through blue to cyan at the bottom right.
    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    let body = NSGradient(colorsAndLocations:
        (NSColor(calibratedRed: 0.24, green: 0.20, blue: 0.72, alpha: 1), 0.0),
        (NSColor(calibratedRed: 0.14, green: 0.44, blue: 0.92, alpha: 1), 0.55),
        (NSColor(calibratedRed: 0.28, green: 0.78, blue: 0.96, alpha: 1), 1.0))!
    body.draw(in: tile, angle: -60)
    // A soft highlight across the top, the way glass catches light.
    let gloss = NSGradient(colorsAndLocations:
        (NSColor(calibratedWhite: 1, alpha: 0.0), 0.0),
        (NSColor(calibratedWhite: 1, alpha: 0.18), 1.0))!
    gloss.draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: 90)
    // A fine lighter rim inside the edge.
    NSColor(calibratedWhite: 1, alpha: 0.22).setStroke()
    let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: radius - 2, yRadius: radius - 2)
    rim.lineWidth = 4
    rim.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // The symbol, white with a soft shadow so it sits on the glass rather than in it.
    let config = NSImage.SymbolConfiguration(pointSize: 520, weight: .medium)
    guard let symbol = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)?.withSymbolConfiguration(config) else { exit(1) }
    let tinted = NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect)
        NSColor.white.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    let size = symbol.size
    let at = NSRect(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2, width: size.width, height: size.height)

    NSGraphicsContext.saveGraphicsState()
    let lift = NSShadow()
    lift.shadowColor = NSColor(calibratedRed: 0, green: 0.05, blue: 0.25, alpha: 0.45)
    lift.shadowBlurRadius = 18 * s
    lift.shadowOffset = NSSize(width: 0, height: -8 * s)
    lift.set()
    tinted.draw(in: at)
    NSGraphicsContext.restoreGraphicsState()

    // The lens: colored glass over the symbol's solid lens disc, leaving a thin white rim as
    // a bezel. The disc is measured from the symbol itself.
    if let ring = lensDisc(in: tinted, drawnIn: at) {
        NSGraphicsContext.saveGraphicsState()
        let glass: NSGradient
        if ProcessInfo.processInfo.environment["LENS"] == "cool" {
            glass = NSGradient(colorsAndLocations:
                (NSColor(calibratedRed: 0.75, green: 0.98, blue: 1.0, alpha: 1), 0.0),
                (NSColor(calibratedRed: 0.10, green: 0.60, blue: 0.90, alpha: 1), 0.45),
                (NSColor(calibratedRed: 0.05, green: 0.12, blue: 0.45, alpha: 1), 1.0))!
        } else {
            glass = NSGradient(colorsAndLocations:
                (NSColor(calibratedRed: 1.0, green: 0.90, blue: 0.55, alpha: 1), 0.0),
                (NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.20, alpha: 1), 0.5),
                (NSColor(calibratedRed: 0.85, green: 0.25, blue: 0.15, alpha: 1), 1.0))!
        }
        let inset = ring.width * 0.09
        let lens = ring.insetBy(dx: inset, dy: inset)
        let disc = NSBezierPath(ovalIn: lens)
        disc.addClip()
        // Lit from the upper left: the gradient's center sits there.
        glass.draw(in: disc, relativeCenterPosition: NSPoint(x: -0.35, y: 0.35))
        // A glint.
        let glint = NSBezierPath(ovalIn: NSRect(x: lens.minX + lens.width * 0.26, y: lens.minY + lens.height * 0.60,
                                                width: lens.width * 0.22, height: lens.height * 0.14))
        NSColor(calibratedWhite: 1, alpha: 0.75).setFill()
        glint.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

/// The square around the camera's lens, in the coordinates the symbol was drawn in. In this
/// symbol the lens is a solid disc inside a clear ring: the opaque shape the symbol's center
/// falls in, measured out to its edges along the row and column through it.
func lensDisc(in symbol: NSImage, drawnIn at: NSRect) -> NSRect? {
    let w = Int(symbol.size.width), h = Int(symbol.size.height)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    symbol.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    func opaque(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, y >= 0, x < w, y < h, let c = rep.colorAt(x: x, y: y) else { return false }
        return c.alphaComponent > 0.5
    }
    // Rows run top-down. From the center, out along the column to the disc's top and bottom,
    // then along the row through its middle to its left and right.
    let cx = w / 2, cy = h / 2
    guard opaque(cx, cy) else { return nil }
    var t = cy, b = cy
    while opaque(cx, t - 1) { t -= 1 }
    while opaque(cx, b + 1) { b += 1 }
    let my = (t + b) / 2
    var l = cx, r = cx
    while opaque(l - 1, my) { l -= 1 }
    while opaque(r + 1, my) { r += 1 }
    let d = CGFloat(max(r - l, b - t) + 1)
    let center = NSPoint(x: at.minX + CGFloat(l + r) / 2 + 0.5, y: at.minY + CGFloat(h) - (CGFloat(t + b) / 2 + 0.5))
    if ProcessInfo.processInfo.environment["DEBUG_LENS"] != nil {
        print("lens rows \(t)-\(b) cols \(l)-\(r) d=\(d) center=\(center)")
    }
    return NSRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
}

func write(_ bitmap: NSBitmapImageRep, to url: URL) {
    guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    do { try png.write(to: url) } catch {
        FileHandle.standardError.write(Data("cannot write \(url.path): \(error)\n".utf8))
        exit(1)
    }
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (pixels, name) in sizes {
    write(draw(pixels: pixels, shadow: pixels >= 64), to: iconset.appendingPathComponent("\(name).png"))
}
if arguments.count >= 3 {
    write(draw(pixels: 1024, shadow: true), to: URL(fileURLWithPath: arguments[2]))
}
