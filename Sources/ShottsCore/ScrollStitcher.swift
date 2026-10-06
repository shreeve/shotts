import Foundation

/// A scrolling capture: one tall picture from the frames of an area while the user scrolls what
/// is in it. Each frame is matched to the last one taken to find how far its content moved, and
/// rows new below what is already held are added, so scrolling back up adds nothing.
///
/// Rows just scrolled in are not final: a browser draws what comes into view a moment late when
/// scrolling fast, leaving it blank in the frame that first shows it. So the last `fresh` rows
/// are taken again from every frame that shows them, moved or not, until they have scrolled up
/// past them; above that they stay as taken. What the pointer rests on, at the area's middle,
/// is above them, so a highlight following it down the page is not taken again.
///
/// Matching compares row fingerprints, each row's brightness averaged over a few dozen blocks
/// across it: cheap to compare, and steady under the small differences a redraw brings (a
/// blinking cursor, a spinner, antialiasing). It tries every fourth shift, then every shift
/// around the best; where several shifts fit about as well, as in a list of rows alike, it takes
/// the one nearest the last move, since scrolling is smooth from frame to frame.
///
/// Bands that stay put at the top and bottom while the rest moves, sticky headers and footers,
/// are found at the first move and kept once: the top from the first frame, the bottom from the
/// last to reach the picture's end. A band taken for one that is not (blank margin) costs
/// nothing: what passes under it is still taken while it is in the middle, and that frame's
/// bottom band continues the middle.
///
/// Frames are BGRA, rows of `width` pixels; the picture is built as they come, never holding
/// more than the last frame besides it, and stops growing at `maxBytes`.
public struct ScrollStitcher: Sendable {
    /// What a frame did.
    public enum Step: Equatable, Sendable {
        /// The first frame.
        case started
        /// Nothing moved.
        case unmoved
        /// The content moved by this many rows, up being positive (scrolling down).
        case moved(Int)
        /// No shift fits: it moved too far since the last frame, or changed too much.
        case lost
        /// The picture is as tall as it may be; nothing more is added.
        case full
    }

    public let width: Int
    public let height: Int
    /// The most the picture may take, in bytes.
    public static let maxBytes = 256 << 20

    /// Fingerprint blocks across a row.
    let blocks: Int
    /// The last frame taken: its pixels and fingerprints.
    private var last: [UInt8] = []
    private var lastPrints: [Float] = []
    /// The first frame's top band, once the bands are known.
    private var top: [UInt8] = []
    /// The bottom band of the last frame to reach the picture's end.
    private var bottom: [UInt8] = []
    private(set) var header = 0
    private(set) var footer = 0
    private var bandsKnown = false
    /// Where the last frame's middle starts in the picture's middle, in rows.
    private var position = 0
    private var lastMove = 0
    /// The middle rows so far.
    private var middle: [UInt8] = []
    /// How many of them are final; those below are taken again from each frame showing them.
    private var settled = 0
    public private(set) var isFull = false

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        blocks = max(1, min(64, width / 4))
    }

    private var rowBytes: Int { width * 4 }
    private var middleRows: Int { middle.count / max(rowBytes, 1) }

    /// How tall the picture is so far.
    public var pictureHeight: Int { bandsKnown ? header + middleRows + footer : (last.isEmpty ? 0 : height) }

    /// Takes a frame: `bytes` holds `height` rows of `bytesPerRow` bytes, BGRA, `width` pixels each.
    public mutating func add(_ bytes: UnsafeRawBufferPointer, bytesPerRow: Int) -> Step {
        guard width > 0, height > 0, bytesPerRow >= rowBytes, bytes.count >= bytesPerRow * (height - 1) + rowBytes else { return .lost }
        var frame = [UInt8](repeating: 0, count: rowBytes * height)
        frame.withUnsafeMutableBytes { out in
            for y in 0..<height {
                out.baseAddress!.advanced(by: y * rowBytes).copyMemory(from: bytes.baseAddress!.advanced(by: y * bytesPerRow), byteCount: rowBytes)
            }
        }
        let prints = fingerprints(frame)
        guard !last.isEmpty else {
            last = frame
            lastPrints = prints
            return .started
        }
        if !bandsKnown {
            guard let (t, b) = bands(prints) else {
                // Still: the latest frame, which may show what the first had not drawn yet.
                last = frame
                lastPrints = prints
                return .unmoved
            }
            header = t
            footer = b
            bandsKnown = true
            top = Array(last[0..<t * rowBytes])
            middle = Array(last[t * rowBytes..<(height - b) * rowBytes])
            bottom = Array(last[(height - b) * rowBytes..<height * rowBytes])
            settled = max(0, middleRows - fresh)
        }
        if isFull { return .full }
        guard let d = shift(from: lastPrints, to: prints) else { return .lost }
        let start = position + d, end = start + height - header - footer
        if (max(end, middleRows) + header + footer) * rowBytes > Self.maxBytes {
            isFull = true
            return .full
        }
        take(frame, at: start)
        position = start
        last = frame
        lastPrints = prints
        guard d != 0 else { return .unmoved }
        lastMove = d
        return .moved(d)
    }

    /// The rows at the end of the middle taken again while they may still be being drawn: a
    /// third of it, below the middle of the area, where the pointer rests.
    private var fresh: Int { (height - header - footer) / 3 }

    /// Takes `frame`'s middle, its first row at `start` in the picture's middle: over the rows
    /// not yet final, and below them those the picture does not have yet. A frame reaching the
    /// picture's end gives it its bottom band, and the rows it shows `fresh` above its own
    /// bottom are final.
    private mutating func take(_ frame: [UInt8], at start: Int) {
        let end = start + height - header - footer
        let from = max(start, settled)
        guard from < end else { return }
        let header = header, rowBytes = rowBytes
        func source(_ rows: Range<Int>) -> ArraySlice<UInt8> {
            frame[(header + rows.lowerBound - start) * rowBytes..<(header + rows.upperBound - start) * rowBytes]
        }
        let held = min(end, middleRows)
        if from < held { middle.replaceSubrange(from * rowBytes..<held * rowBytes, with: source(from..<held)) }
        if end > middleRows { middle.append(contentsOf: source(max(from, middleRows)..<end)) }
        guard end >= middleRows else { return }
        bottom = Array(frame[(height - footer) * rowBytes..<height * rowBytes])
        settled = max(settled, min(middleRows, end - fresh))
    }

    /// The picture so far: the top band from the first frame, the middle as built, and the
    /// bottom band from the last frame to reach its end. BGRA rows of `width` pixels,
    /// `pictureHeight` of them.
    public func picture() -> [UInt8] {
        guard bandsKnown else { return last }
        return top + middle + bottom
    }

    // MARK: - Matching

    /// Each row's brightness averaged over `blocks` across it: `height` × `blocks` values, 0–255.
    func fingerprints(_ frame: [UInt8]) -> [Float] {
        var prints = [Float](repeating: 0, count: height * blocks)
        let blockWidth = width / blocks
        frame.withUnsafeBufferPointer { px in
            for y in 0..<height {
                let row = y * rowBytes
                for b in 0..<blocks {
                    let from = b * blockWidth, to = b == blocks - 1 ? width : from + blockWidth
                    // Every pixel: fewer would leave the prints noisy enough that a still band,
                    // a sticky header, no longer reads as still.
                    var sum = 0
                    for x in from..<to {
                        let p = row + x * 4
                        // BGRA: luma from red, green, and blue.
                        sum += Int(px[p + 2]) * 299 + Int(px[p + 1]) * 587 + Int(px[p]) * 114
                    }
                    prints[y * blocks + b] = Float(sum) / Float((to - from) * 1000)
                }
            }
        }
        return prints
    }

    /// How unlike two rows are: the mean difference of their blocks.
    private func unlike(_ a: [Float], _ ay: Int, _ b: [Float], _ by: Int) -> Float {
        var sum: Float = 0
        let ai = ay * blocks, bi = by * blocks
        for i in 0..<blocks { sum += abs(a[ai + i] - b[bi + i]) }
        return sum / Float(blocks)
    }

    /// The bands that stayed put between the last frame and this one: the rows alike at the top
    /// and at the bottom, each a third of the frame at most, or none when the middle between
    /// them would be too short to match. Nil when nothing moved.
    ///
    /// The bottom band is at least `bottomMargin` of the frame: a window's rounded corners sit
    /// in its last rows, over content that moves, and rows taken from there would carry them
    /// into the middle of the picture at every step. Taken only from the last frame, they come
    /// once, at the bottom, where they were; what scrolls through that margin is taken higher up.
    private func bands(_ prints: [Float]) -> (Int, Int)? {
        let same = (0..<height).map { unlike(prints, $0, lastPrints, $0) < Self.alike }
        guard same.contains(false) else { return nil }
        let margin = max(1, Int(Double(height) * Self.bottomMargin))
        let t = min(same.prefix { $0 }.count, height / 3)
        let b = max(min(same.reversed().prefix { $0 }.count, height / 3), margin)
        return height - t - b >= max(32, height / 4) ? (t, b) : (0, margin)
    }

    /// The least of the frame kept as its bottom band: past the rounded corners of a window.
    static let bottomMargin = 1.0 / 12

    /// Rows this alike count as the same.
    static let alike: Float = 1
    /// A shift whose rows differ by more than this on average is not believed.
    static let fits: Float = 3

    /// How far the middle's content moved from `before` to `after`, up being positive; 0 when
    /// it did not; nil when no shift fits.
    private func shift(from before: [Float], to after: [Float]) -> Int? {
        let low = header, high = height - footer, rows = high - low
        let overlap = max(16, rows / 4)
        let reach = rows - overlap
        guard reach > 0 else { return nil }
        // The mean unlikeness of `after`'s rows to `before`'s `d` rows further down, every
        // `step`th row.
        func cost(_ d: Int, step: Int) -> Float {
            let from = max(low, low - d), to = min(high, high - d)
            var sum: Float = 0, n = 0
            var y = from
            while y < to {
                sum += unlike(after, y, before, y + d)
                n += 1
                y += step
            }
            return n > 0 ? sum / Float(n) : .infinity
        }
        if cost(0, step: 1) < Self.alike { return 0 }
        // Every fourth shift, every other row; then every shift near the one chosen. Shifts near
        // the last move first, since scrolling is smooth; all of them when none of those fits.
        func coarse(_ range: ClosedRange<Int>) -> [(Int, Float)] {
            stride(from: range.lowerBound / 4 * 4, through: range.upperBound, by: 4).map { ($0, cost($0, step: 2)) }
        }
        let likely = coarse(max(-reach, lastMove - rows / 4)...min(reach, lastMove + rows / 4))
        let coarse = (likely.min(by: { $0.1 < $1.1 })?.1 ?? .infinity) <= Self.fits ? likely : coarse(-reach...reach)
        guard let best = coarse.min(by: { $0.1 < $1.1 }) else { return nil }
        // Of those about as good as the best, the one nearest the last move: rows alike in a
        // list fit at several shifts, and scrolling is smooth.
        let near = coarse.filter { $0.1 <= best.1 + 0.5 }.min { abs($0.0 - lastMove) < abs($1.0 - lastMove) } ?? best
        let fine = (max(-reach, near.0 - 4)...min(reach, near.0 + 4)).map { ($0, cost($0, step: 1)) }
        guard let found = fine.min(by: { $0.1 < $1.1 }), found.1 <= Self.fits else { return nil }
        return found.0
    }
}
