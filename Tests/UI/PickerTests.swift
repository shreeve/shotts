import AppKit
import ShottsCore
import Testing
@testable import ShottsUI

/// A display picture whose pixels report when they are freed, and a flag that says so.
private func trackedPicture(_ width: Int, _ height: Int) -> (CGImage, UnsafeMutablePointer<Bool>) {
    let freed = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
    freed.pointee = false
    let bytesPerRow = width * 4
    let data = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * height, alignment: 16)
    data.initializeMemory(as: UInt8.self, repeating: 0x80, count: bytesPerRow * height)
    let provider = CGDataProvider(dataInfo: freed, data: data, size: bytesPerRow * height) { info, data, _ in
        info?.assumingMemoryBound(to: Bool.self).pointee = true
        UnsafeMutableRawPointer(mutating: data).deallocate()
    }!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                        space: CGColorSpace(name: CGColorSpace.displayP3)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    return (image, freed)
}

@MainActor @Suite struct CutTests {
    /// Only the cut-out survives the picker: the display's picture is freed while the cut-out
    /// lives on in the editor.
    @Test func cutOutKeepsNoneOfTheDisplayPicture() throws {
        let screen = try #require(NSScreen.screens.first)
        let (freed, cut): (UnsafeMutablePointer<Bool>, CGImage?) = autoreleasepool {
            let (picture, freed) = trackedPicture(800, 600)
            let display = DisplayImage(screen: screen, image: picture, scale: 2)
            return (freed, display.cut(CGRect(x: 10, y: 10, width: 100, height: 50)))
        }
        defer { freed.deallocate() }
        let image = try #require(cut)
        #expect(freed.pointee)
        #expect(image.width == 200 && image.height == 100)
        #expect(image.colorSpace?.name == CGColorSpace.displayP3)
    }

    /// The cut-out's pixels are the picture's, from the top-left, in its own color space.
    @Test func cutOutHasThePicturesPixels() throws {
        let screen = try #require(NSScreen.screens.first)
        let ctx = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 30, width: 10, height: 10)) // the top-left corner, as y runs upward
        let display = DisplayImage(screen: screen, image: ctx.makeImage()!, scale: 1)
        let cut = try #require(display.cut(CGRect(x: 5, y: 5, width: 10, height: 10)))
        let colors = PixelSampler.colors(in: CGRect(x: 0, y: 0, width: 10, height: 10), of: cut)
        #expect(colors[0][0]?.hex == "#FF0000")
        #expect(colors[9][9]?.hex == "#0000FF")
    }
}
