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

/// A list of rows alike, as a file list is: every row the same height, with the same icon and
/// separator, and a name and a date of a few words, mostly background. A shift by whole rows
/// fits nearly as well as the true one.
struct ScrollTestList {
    let width = 320, window = 240, rowHeight = 28

    func gray(row: Int, x: Int) -> UInt8 {
        let r = row % rowHeight, index = row / rowHeight
        if r == 0 { return 225 }                                     // separator
        if (8...19).contains(r), (6..<20).contains(x) { return 120 }  // icon
        guard (11...16).contains(r) else { return 255 }
        // The name, of a length its own, and the date, all of a length.
        var h = UInt64(index &* 2_654_435_761 &+ (x / 6) &* 40_503) &* 0x9E37_79B9_7F4A_7C15
        h ^= h >> 29
        let nameEnd = 60 + Int(UInt64(index &* 7919) % 120)
        let inName = x >= 32 && x < nameEnd, inDate = x >= 230 && x < 290
        guard inName || inDate, h % 3 != 0 else { return 255 }
        return h % 3 == 1 ? 50 : 150
    }

    /// The window scrolled to `offset` rows into the list, its last `undrawn` rows still blank,
    /// as a browser leaves what has just come into view when scrolling fast.
    func frame(at offset: Int, undrawn: Int = 0) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: width * window * 4)
        for y in 0..<window - undrawn {
            for x in 0..<width {
                let g = gray(row: offset + y, x: x), p = (y * width + x) * 4
                out[p] = g; out[p + 1] = g; out[p + 2] = g
            }
        }
        return out
    }

    func expected(through offset: Int) -> [UInt8] {
        let total = offset + window
        var out = [UInt8](repeating: 255, count: width * total * 4)
        for y in 0..<total {
            for x in 0..<width {
                let g = gray(row: y, x: x), p = (y * width + x) * 4
                out[p] = g; out[p + 1] = g; out[p + 2] = g
            }
        }
        return out
    }
}

@Suite struct ScrollStitcherListTests {
    let list = ScrollTestList()

    /// Rows still blank where they came into view are taken again once drawn, in a frame that
    /// moved on or in one that did not: none is left blank.
    @Test func rowsDrawnLateComeIn() {
        var stitcher = ScrollStitcher(width: list.width, height: list.window)
        let frames = [(0, 0), (40, 50), (90, 50), (140, 50), (140, 0)]
        var steps: [ScrollStitcher.Step] = []
        for (o, undrawn) in frames { steps.append(stitcher.add(list.frame(at: o, undrawn: undrawn), width: list.width)) }
        #expect(steps == [.started, .moved(40), .moved(50), .moved(50), .unmoved])
        #expect(stitcher.picture() == list.expected(through: 140))
    }

    /// Scrolled back up a little at the end: the bottom continues the picture, from the frame
    /// that went furthest, not the last.
    @Test func theBottomIsTheFurthest() {
        var stitcher = ScrollStitcher(width: list.width, height: list.window)
        for o in [0, 50, 100, 150, 130] { _ = stitcher.add(list.frame(at: o), width: list.width) }
        #expect(stitcher.picture() == list.expected(through: 150))
    }

    /// Scrolled as auto-scroll does: speeding up and slowing down, now and then backing up.
    /// Every row in its place, whole rows alike or not.
    @Test func everyRowComes() {
        var failures: [String] = []
        var rng: UInt64 = 7
        func random(_ n: Int) -> Int {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(rng >> 33) % n
        }
        for run in 0..<8 {
            var stitcher = ScrollStitcher(width: list.width, height: list.window)
            var offsets = [0], speed = 10 + random(60)
            while offsets.count < 12 {
                speed = max(1, speed + random(41) - 20)
                offsets.append(max(0, offsets.last! + (random(6) == 0 ? -speed / 2 : speed)))
            }
            for o in offsets { _ = stitcher.add(list.frame(at: o), width: list.width) }
            if stitcher.picture() != list.expected(through: offsets.max()!) { failures.append("\(run): \(offsets)") }
        }
        #expect(failures.isEmpty, "\(failures)")
    }
}
