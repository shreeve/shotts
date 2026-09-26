// Renders Support/AppIcon.svg into an .iconset directory.
// usage: swift render-app-icon.swift SVG ICONSET_DIR [PREVIEW.png]
//
// AppKit's SVG renderer keeps transparency and draws gradients but ignores filters, so the
// Dock shadow is drawn here rather than in the artwork.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: render-app-icon.swift SVG ICONSET_DIR [PREVIEW.png]\n".utf8))
    exit(64)
}
guard let master = NSImage(contentsOfFile: arguments[1]) else {
    FileHandle.standardError.write(Data("cannot load \(arguments[1])\n".utf8))
    exit(1)
}
let iconset = URL(fileURLWithPath: arguments[2])

/// The icon at `pixels` square: the master drawn over its Dock shadow.
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
    if shadow {
        // Under the tile only: the tile is the master's 824-point rounded square.
        NSGraphicsContext.saveGraphicsState()
        let dock = NSShadow()
        dock.shadowColor = NSColor(calibratedRed: 0, green: 0.05, blue: 0.2, alpha: 0.35)
        dock.shadowBlurRadius = 24 * s
        dock.shadowOffset = NSSize(width: 0, height: -12 * s)
        dock.set()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s), xRadius: 184 * s, yRadius: 184 * s).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    master.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
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
if arguments.count >= 4 {
    write(draw(pixels: 1024, shadow: true), to: URL(fileURLWithPath: arguments[3]))
}
