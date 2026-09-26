import AppKit
import ShottsCore
import Testing
@testable import ShottsUI

/// One of every kind of annotation on a 600 by 400 picture at scale 2.
func everyKind() -> [Annotation] {
    var thick = Style.standard
    thick.strokeWidth = 10
    let words = "Callout words"
    let size = Renderer.textSize(words, style: .standard, scale: 2, width: 200)
    return [
        Annotation(shape: .arrow(from: CGPoint(x: 60, y: 300), to: CGPoint(x: 240, y: 120)), style: thick),
        Annotation(shape: .rectangle(CGRect(x: 300, y: 40, width: 120, height: 80)), style: .standard),
        Annotation(shape: .ellipse(CGRect(x: 440, y: 40, width: 120, height: 80), filled: true), style: .standard),
        Annotation(shape: .pen([CGPoint(x: 300, y: 200), CGPoint(x: 360, y: 240), CGPoint(x: 420, y: 210)]), style: .standard),
        Annotation(shape: .highlighter([CGPoint(x: 300, y: 300), CGPoint(x: 520, y: 300)]), style: .standard),
        Annotation(shape: .obscure(CGRect(x: 440, y: 150, width: 100, height: 60)), style: .standard),
        Annotation(shape: .text(origin: CGPoint(x: 40, y: 20), string: "Text", size: Renderer.textSize("Text", style: .standard, scale: 2)), style: .standard),
        Annotation(shape: .callout(from: CGPoint(x: 200, y: 360), to: CGPoint(x: 280, y: 320),
                                   text: Annotation.TextBox(origin: CGPoint(x: 200 - size.width, y: 340), string: words, size: size, alignment: .right)),
                   style: thick),
    ]
}

/// A transparent bitmap the size of the picture, flipped to image pixels as the renderer expects.
func transparentContext(_ width: Int, _ height: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

@MainActor @Suite struct RenderTests {
    /// The renderer clips each annotation to its extent, and the canvas redraws only the extent
    /// of what changed, so the extent must hold all the ink with room to spare: nothing may
    /// reach its last few pixels, where the clip would be cutting something off.
    @Test func theExtentHoldsAllTheInk() {
        let source = blankImage(1200, 800)
        let document = Document(width: 1200, height: 800, scale: 2)
        for a in everyKind().map({ $0.translated(by: CGPoint(x: 300, y: 200)) }) {
            let ctx = transparentContext(1200, 800)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            Renderer.draw(a, document: document, source: source, in: ctx)
            NSGraphicsContext.restoreGraphicsState()
            let inner = Renderer.extent(of: a, scale: 2).insetBy(dx: 4, dy: 4)
            let pixels = ctx.data!.bindMemory(to: UInt8.self, capacity: 1200 * 800 * 4)
            var inside = 0, edge = 0
            for y in 0..<800 {
                for x in 0..<1200 where pixels[(y * 1200 + x) * 4 + 3] > 0 {
                    // Memory rows run top-first, as image pixels do.
                    if inner.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) { inside += 1 } else { edge += 1 }
                }
            }
            #expect(inside > 0, "\(a.shape) drew nothing")
            #expect(edge == 0, "\(a.shape) reaches the edge of its extent at \(edge) pixels")
        }
    }

    /// What the canvas shows at the picture's on-screen size is what is exported, shadows included.
    @Test func theCanvasShowsWhatIsExported() throws {
        let canvas = canvasInWindow(width: 600, height: 400, scale: 2, zoom: 0.5)
        let backing = try #require(canvas.window?.backingScaleFactor)
        try #require(backing == 2, "needs a Retina main display")
        var d = canvas.document
        for a in everyKind() where a.style.shadow { d.add(a) }
        canvas.commit(d)
        let exported = try #require(Renderer.image(of: canvas.document, source: canvas.source))
        let picture = canvas.pictureRect
        let rep = try #require(canvas.bitmapImageRepForCachingDisplay(in: picture))
        canvas.cacheDisplay(in: picture, to: rep)
        let shown = try #require(rep.cgImage)
        #expect(shown.width == exported.width && shown.height == exported.height)
        let a = rgba(shown), b = rgba(exported)
        // Antialiasing differs by a few levels; a shadow drawn at the wrong size differs by 35.
        let worst = zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(worst <= 12, "a channel differs by \(worst)")
    }
}

/// An image's pixels as sRGB RGBA bytes, rows top-first.
func rgba(_ image: CGImage) -> [UInt8] {
    let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(UnsafeBufferPointer(start: ctx.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4),
                                     count: image.width * image.height * 4))
}
