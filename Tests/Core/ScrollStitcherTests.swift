import Foundation
import Testing
@testable import ShottsCore

/// A page longer than its window: a sticky header and footer, and between them lines of
/// "text", dark and light blocks unlike from line to line, on a light background.
struct ScrollTestPage {
    let width = 160, window = 240, headerRows = 20
    let rows: Int
    var footerRows = 16
    /// A window's rounded bottom corners: the last rows' outer pixels show what is behind it.
    var corners = false
    var middleRows: Int { window - headerRows - footerRows }

    /// Gray for a page row and column, the header's and footer's fixed.
    func gray(row: Int, x: Int) -> UInt8 {
        let line = row / 12, inLine = row % 12
        guard (3...9).contains(inLine) else { return 245 }
        var h = UInt64(line &* 2_654_435_761 &+ (x / 8) &* 40_503) &* 0x9E37_79B9_7F4A_7C15
        h ^= h >> 29
        return h % 3 == 0 ? 245 : (h % 3 == 1 ? 40 : 120)
    }

    func header(_ y: Int, _ x: Int) -> UInt8 { x % 20 < 10 ? 90 : 200 }
    func footer(_ y: Int, _ x: Int) -> UInt8 { y % 4 < 2 ? 60 : 180 }

    /// The window scrolled to `offset` rows into the page; with `noise`, each pixel off by up to
    /// two levels; with `cursor`, a dark bar drawn at a fixed place in the window.
    func frame(at offset: Int, noise: Bool = false, cursor: Bool = false, seed: UInt64 = 1) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: width * window * 4)
        var rng = seed
        for y in 0..<window {
            for x in 0..<width {
                var g: Int
                if y < headerRows { g = Int(header(y, x)) }
                else if y >= window - footerRows { g = Int(footer(y - (window - footerRows), x)) }
                else { g = Int(gray(row: offset + y - headerRows, x: x)) }
                if cursor, (100..<114).contains(y), (60..<62).contains(x) { g = 0 }
                if corners, y >= window - 8, x < 6 || x >= width - 6 { g = 30 }
                if noise {
                    rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    g = min(255, max(0, g + Int(rng >> 62) - 1))
                }
                let p = (y * width + x) * 4
                out[p] = UInt8(g); out[p + 1] = UInt8(g); out[p + 2] = UInt8(g); out[p + 3] = 255
            }
        }
        return out
    }

    /// The whole page as stitched up to `offset`: header, every middle row through the window
    /// at `offset`, footer.
    func expected(through offset: Int) -> [UInt8] {
        let total = headerRows + offset + middleRows + footerRows
        var out = [UInt8](repeating: 255, count: width * total * 4)
        for y in 0..<total {
            for x in 0..<width {
                var g: UInt8 = y < headerRows ? header(y, x)
                    : (y >= total - footerRows ? footer(y - (total - footerRows), x) : gray(row: y - headerRows, x: x))
                if corners, y >= total - 8, x < 6 || x >= width - 6 { g = 30 }
                let p = (y * width + x) * 4
                out[p] = g; out[p + 1] = g; out[p + 2] = g
            }
        }
        return out
    }
}

private extension ScrollStitcher {
    mutating func add(_ frame: [UInt8], width: Int) -> Step {
        frame.withUnsafeBytes { add($0, bytesPerRow: width * 4) }
    }
}

@Suite struct ScrollStitcherTests {
    let page = ScrollTestPage(rows: 2000)

    /// Scrolled by uneven amounts, still for a frame, and back up a little: the picture is the
    /// page, header and footer once each, every row in its place.
    @Test func scrollingBuildsThePage() {
        var stitcher = ScrollStitcher(width: page.width, height: page.window)
        let offsets = [0, 30, 75, 75, 141, 120, 263, 400, 512]
        var steps: [ScrollStitcher.Step] = []
        for o in offsets { steps.append(stitcher.add(page.frame(at: o), width: page.width)) }
        #expect(steps == [.started, .moved(30), .moved(45), .unmoved, .moved(66), .moved(-21), .moved(143), .moved(137), .moved(112)])
        #expect(stitcher.pictureHeight == page.headerRows + 512 + page.middleRows + page.footerRows)
        #expect(stitcher.picture() == page.expected(through: 512))
        #expect(stitcher.header == page.headerRows && stitcher.footer == max(page.footerRows, page.window / 12))
    }

    /// A window's rounded corners, over content that moves at the bottom of the frame, come
    /// once at the bottom of the picture, not at every step down it.
    @Test func cornersComeOnce() {
        let page = ScrollTestPage(rows: 2000, footerRows: 0, corners: true)
        var stitcher = ScrollStitcher(width: page.width, height: page.window)
        for o in [0, 30, 75, 141, 263, 400] { _ = stitcher.add(page.frame(at: o), width: page.width) }
        #expect(stitcher.picture() == page.expected(through: 400))
    }

    /// A blinking cursor and a little noise in every frame still match, and the rows kept are
    /// the frames' own.
    @Test func smallChangesStillMatch() {
        var stitcher = ScrollStitcher(width: page.width, height: page.window)
        var moves: [ScrollStitcher.Step] = []
        for (i, o) in [0, 24, 61, 100, 158].enumerated() {
            moves.append(stitcher.add(page.frame(at: o, noise: true, cursor: i % 2 == 1, seed: UInt64(i + 1)), width: page.width))
        }
        #expect(moves == [.started, .moved(24), .moved(37), .moved(39), .moved(58)])
        #expect(stitcher.pictureHeight == page.headerRows + 158 + page.middleRows + page.footerRows)
    }

    /// Too far in one frame to overlap enough: not believed, and the next frame that does
    /// overlap the last one taken goes on from there.
    @Test func aJumpIsLostAndRecovered() {
        var stitcher = ScrollStitcher(width: page.width, height: page.window)
        #expect(stitcher.add(page.frame(at: 0), width: page.width) == .started)
        #expect(stitcher.add(page.frame(at: 20), width: page.width) == .moved(20))
        #expect(stitcher.add(page.frame(at: 20 + page.middleRows), width: page.width) == .lost)
        #expect(stitcher.add(page.frame(at: 90), width: page.width) == .moved(70))
        #expect(stitcher.picture() == page.expected(through: 90))
    }

    /// Never scrolled: the picture is the one frame.
    @Test func noScrollIsTheFrame() {
        var stitcher = ScrollStitcher(width: page.width, height: page.window)
        let frame = page.frame(at: 0)
        #expect(stitcher.add(frame, width: page.width) == .started)
        #expect(stitcher.add(frame, width: page.width) == .unmoved)
        #expect(stitcher.picture() == frame && stitcher.pictureHeight == page.window)
    }

    /// A frame's rows may be padded past its width, as a pixel buffer's are.
    @Test func paddedRows() {
        var stitcher = ScrollStitcher(width: page.width, height: page.window)
        func padded(_ frame: [UInt8]) -> [UInt8] {
            (0..<page.window).flatMap { y in Array(frame[y * page.width * 4..<(y + 1) * page.width * 4]) + [UInt8](repeating: 7, count: 64) }
        }
        for o in [0, 50] {
            _ = padded(page.frame(at: o)).withUnsafeBytes { stitcher.add($0, bytesPerRow: page.width * 4 + 64) }
        }
        #expect(stitcher.picture() == page.expected(through: 50))
    }
}
