import AppKit
import CoreText
import ShottsCore
import Testing
@testable import ShottsUI

@MainActor @Suite struct FontTests {
    /// The app registers Open Sans through `ATSApplicationFontsPath`; a test registers the same
    /// file for its own process.
    static let registered: Bool = {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Support/Fonts/OpenSans-Bold.ttf")
        return CTFontManagerRegisterFontsForURL(file.standardizedFileURL as CFURL, .process, nil)
            || NSFont(name: "OpenSans-Bold", size: 12) != nil
    }()

    @Test func openSansIsTheBundledFontAndDraws() throws {
        try #require(Self.registered)
        var style = Style.standard
        style.font = .openSans
        #expect(Renderer.font(for: style, scale: 2).fontName == "OpenSans-Bold")
        let size = Renderer.textSize("Open Sans", style: style, scale: 2)
        style.font = .rounded
        #expect(size != Renderer.textSize("Open Sans", style: style, scale: 2))

        style.font = .openSans
        style.shadow = false
        let a = Annotation(shape: .text(origin: CGPoint(x: 20, y: 20), string: "Open Sans", size: size), style: style)
        let ctx = transparentContext(600, 200)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        Renderer.draw(a, document: Document(width: 600, height: 200, scale: 2), source: blankImage(600, 200), in: ctx)
        NSGraphicsContext.restoreGraphicsState()
        let pixels = ctx.data!.bindMemory(to: UInt8.self, capacity: 600 * 200 * 4)
        #expect((0..<(600 * 200)).contains { pixels[$0 * 4 + 3] > 0 })
    }

    @Test func theFontMenuOffersOpenSans() {
        #expect(FontChoice.allCases.map(\.title) == ["Rounded", "System", "Open Sans"])
    }
}
