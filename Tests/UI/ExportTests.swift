import AppKit
import ImageIO
import ShottsCore
import Testing
@testable import ShottsUI

/// A pasteboard of the tests' own, so a test run never touches what the user has copied.
func privatePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("Shotts tests \(UUID().uuidString)"))
}

/// An encoded image's resolution and pixel size, as another app reading the file sees them.
func properties(_ data: Data) -> (dpi: Double, width: Int, height: Int)? {
    guard let file = CGImageSourceCreateWithData(data as CFData, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [CFString: Any],
          let dpi = p[kCGImagePropertyDPIWidth] as? Double, p[kCGImagePropertyDPIHeight] as? Double == dpi,
          let width = p[kCGImagePropertyPixelWidth] as? Int, let height = p[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (dpi, width, height)
}

/// A picture filled with one color given in the color space, and nothing else.
func solidImage(_ width: Int, _ height: Int, _ components: [CGFloat], in name: CFString) -> CGImage {
    let space = CGColorSpace(name: name)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.setFillColor(CGColor(colorSpace: space, components: components + [1])!)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

/// An image's pixels as RGBA bytes in the named color space, rows top-first.
func pixels(_ image: CGImage, in name: CFString) -> [UInt8] {
    let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                        space: CGColorSpace(name: name)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(UnsafeBufferPointer(start: ctx.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4),
                                     count: image.width * image.height * 4))
}

/// An sRGB picture whose every pixel differs from its neighbors, mostly in values that are not
/// multiples of 17.
func patternImage(_ width: Int, _ height: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let p = ctx.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            (p[i], p[i + 1], p[i + 2], p[i + 3]) = (UInt8((x * 7 + y * 3) % 256), UInt8((x * 5) % 256), UInt8((y * 11) % 256), 255)
        }
    }
    return ctx.makeImage()!
}

@MainActor @Suite struct ExportTests {
    /// A Retina capture is marked 144 dpi, so it pastes at its on-screen size, not twice that;
    /// the pasteboard gets PNG and TIFF from one render of the cropped picture.
    @Test func theCopyIsMarkedWithTheCapturesResolution() throws {
        var document = Document(width: 600, height: 400, scale: 2, crop: CGRect(x: 100, y: 50, width: 300, height: 200))
        document.add(everyKind()[1])
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        #expect(Export.copy(document, source: blankImage(600, 400), to: pasteboard))
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            let data = try #require(pasteboard.data(forType: type), "no \(type.rawValue)")
            let p = try #require(properties(data), "\(type.rawValue) has no resolution")
            #expect(p.dpi == 144 && p.width == 300 && p.height == 200)
        }
    }

    @Test func theSavedFileIsMarkedWithTheCapturesResolution() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Shotts test \(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Export.write(Document(width: 30, height: 20, scale: 3), source: blankImage(30, 20), to: url)
        let p = try #require(properties(try Data(contentsOf: url)))
        #expect(p.dpi == 216 && p.width == 30 && p.height == 20)
    }

    /// A Display P3 capture exports in Display P3: its most saturated red, which sRGB cannot
    /// hold, comes out as it went in, pixelated or not.
    @Test func aWideGamutCaptureKeepsItsColors() throws {
        var document = Document(width: 80, height: 60, scale: 2, crop: CGRect(x: 0, y: 0, width: 80, height: 40))
        document.add(Annotation(shape: .obscure(CGRect(x: 0, y: 0, width: 40, height: 40)), style: .standard))
        let exported = try #require(Renderer.image(of: document, source: solidImage(80, 60, [1, 0, 0], in: CGColorSpace.displayP3)))
        #expect(exported.colorSpace?.name == CGColorSpace.displayP3)
        let p = pixels(exported, in: CGColorSpace.displayP3)
        for x in [0, 79] {
            let i = (20 * 80 + x) * 4
            #expect(Array(p[i..<i + 4]) == [255, 0, 0, 255], "at x \(x)")
        }
    }

    /// An obscured area, dragged out at fractional pixels, covers every pixel it touches with
    /// blocks whose colors are rounded to 16 levels, and leaves the pixels around it alone.
    @Test func obscureCoversWholePixelsWithRoundedColors() throws {
        let source = patternImage(80, 60)
        var document = Document(width: 80, height: 60, scale: 1)
        document.add(Annotation(shape: .obscure(CGRect(x: 10.4, y: 10.6, width: 45.3, height: 33.2)), style: .standard))
        let exported = try #require(Renderer.image(of: document, source: source))
        let before = rgba(source), after = rgba(exported)
        func pixel(_ p: [UInt8], _ x: Int, _ y: Int) -> [UInt8] { Array(p[(y * 80 + x) * 4..<(y * 80 + x) * 4 + 4]) }
        // Grown to whole pixels: x 10..<56, y 10..<44.
        var changed = 0
        for y in 10..<44 {
            for x in 10..<56 {
                let p = pixel(after, x, y)
                #expect(p.allSatisfy { $0 % 17 == 0 }, "\(p) at \(x), \(y)")
                if p != pixel(before, x, y) { changed += 1 }
            }
        }
        #expect(changed > 46 * 34 * 9 / 10)
        for y in 9...44 {
            for x in [9, 56] { #expect(pixel(after, x, y) == pixel(before, x, y), "at \(x), \(y)") }
        }
        for x in 9...56 {
            for y in [9, 44] { #expect(pixel(after, x, y) == pixel(before, x, y), "at \(x), \(y)") }
        }
    }

    /// A rectangle or ellipse narrower than its stroke still shows, and inside its own bounds.
    @Test func aShapeSmallerThanItsStrokeStillShows() throws {
        var style = Style.standard
        style.strokeWidth = 10
        style.shadow = false
        let rect = CGRect(x: 20, y: 10, width: 6, height: 30)
        for shape in [Annotation.Shape.rectangle(rect), .ellipse(rect)] {
            let source = blankImage(60, 50)
            var document = Document(width: 60, height: 50, scale: 2)
            document.add(Annotation(shape: shape, style: style))
            let before = rgba(source), after = rgba(try #require(Renderer.image(of: document, source: source)))
            var inside = 0, outside = 0
            for y in 0..<50 {
                for x in 0..<60 where before[(y * 60 + x) * 4..<(y * 60 + x) * 4 + 4] != after[(y * 60 + x) * 4..<(y * 60 + x) * 4 + 4] {
                    if rect.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) { inside += 1 } else { outside += 1 }
                }
            }
            #expect(inside > 100 && outside == 0, "\(shape): \(inside) pixels inside, \(outside) outside")
        }
    }

    /// Nothing drawn means nothing to render: the export is the capture, not a copy of it.
    @Test func anUntouchedCaptureExportsItself() {
        let source = blankImage(60, 40)
        #expect(Renderer.image(of: Document(width: 60, height: 40, scale: 2), source: source) === source)
    }
}
