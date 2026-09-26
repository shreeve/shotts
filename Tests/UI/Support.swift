import AppKit
import ShottsCore
@testable import ShottsUI

/// A plain picture of the given pixel size, for editors and renders that need a source.
func blankImage(_ width: Int, _ height: Int, gray: CGFloat = 0.5) -> CGImage {
    _ = NSApplication.shared
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.setFillColor(CGColor(gray: gray, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

/// A canvas in a borderless window that is never shown.
func canvasInWindow(width: Int = 400, height: Int = 300, scale: Double = 2, zoom: CGFloat = 0.5) -> CanvasView {
    let canvas = CanvasView(document: Document(width: width, height: height, scale: scale), source: blankImage(width, height), zoom: zoom)
    let window = NSWindow(contentRect: canvas.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = canvas
    return canvas
}

extension CanvasView {
    /// Stands in for keystrokes in the open text entry.
    func typeText(_ string: String) {
        textField?.string = string
        textField?.didChangeText()
    }
}
