import Foundation

/// A scrolling capture: one tall picture from the frames of an area while it scrolls. Each frame
/// is matched to the last one taken to find how far its content moved, and rows new below what
/// is already held are added, so scrolling back up adds nothing.
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
/// are found at the first move, the first frame whose middle fits a shift other than none, and
/// kept once: the top from the frame before it, the bottom from the last frame to reach the
/// picture's end. Something changing in a bar before then (a caret, a spinner, a line of status)
/// is not a move, so it decides nothing. A band taken for one that is not (blank margin) costs
/// nothing: what passes under it is still taken while it is in the middle, and that frame's
/// bottom band continues the middle.
///
/// The picture is built in place, in one buffer reserved at `maxBytes` (memory is taken only as
/// rows are written): the top band, the middle, and the bottom band right after it. Until the
/// bands are known it holds the latest frame, which is the picture so far; after that, a frame
/// is read where it is and only the rows it adds are copied. `takePicture()` hands the buffer
/// over, so the picture is never copied whole. Frames are BGRA, rows of `width` pixels.
///
/// Not thread-safe: one queue adds the frames and takes the picture.
public final class ScrollStitcher {
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
    public let maxBytes: Int

    /// Fingerprint blocks across a row.
    let blocks: Int
    /// The picture: `capacity` bytes, of which `pictureHeight` rows are written. Nil once handed
    /// over.
    private var buffer: UnsafeMutableRawPointer?
    /// The last frame taken's fingerprints, and the newest frame's.
    private var lastPrints: [Float]
    private var prints: [Float]
    private(set) var header = 0
    private(set) var footer = 0
    private var started = false
    private var bandsKnown = false
    /// Where the last frame's middle starts in the picture's middle, in rows.
    private var position = 0
    private var lastMove = 0
    /// The picture's middle rows so far.
    private var middleRows = 0
    /// How many of them are final; those below are taken again from each frame showing them.
    private var settled = 0
    public private(set) var isFull = false

    /// `maxBytes` defaults to 256 MB, some 20,000 rows of a wide window.
    public init(width: Int, height: Int, maxBytes: Int = 256 << 20) {
        self.width = width
        self.height = height
        self.maxBytes = maxBytes
        blocks = max(1, min(64, width / 4))
        lastPrints = [Float](repeating: 0, count: max(0, height) * blocks)
        prints = lastPrints
        // The first frame is held whole, even past the cap; virtual until written.
        if width > 0, height > 0 { buffer = .allocate(byteCount: max(maxBytes, width * 4 * height), alignment: 16) }
    }

    deinit { buffer?.deallocate() }

    private var rowBytes: Int { width * 4 }
    /// A frame's middle rows, between its bands.
    private var span: Int { height - header - footer }

    /// How tall the picture is so far.
    public var pictureHeight: Int { bandsKnown ? header + middleRows + footer : (started ? height : 0) }

    /// Takes a frame: `bytes` holds `height` rows of `bytesPerRow` bytes, BGRA, `width` pixels each.
    public func add(_ bytes: UnsafeRawBufferPointer, bytesPerRow: Int) -> Step {
        if isFull { return .full }
        guard let buffer, bytesPerRow >= rowBytes, bytes.count >= bytesPerRow * (height - 1) + rowBytes,
              let frame = bytes.baseAddress else { return .lost }
        fingerprint(frame, bytesPerRow: bytesPerRow)
        guard started else {
            started = true
            keep(frame, bytesPerRow: bytesPerRow, in: buffer)
            return .started
        }
        let d: Int
        if bandsKnown {
            guard let found = shift() else { return .lost }
            d = found
        } else {
            guard let (found, t, b) = firstMove() else {
                // Still: the latest frame, which may show what the first had not drawn yet.
                keep(frame, bytesPerRow: bytesPerRow, in: buffer)
                return .unmoved
            }
            guard let found else { return .lost }
            // The frame before is the picture so far, laid out as the bands make it.
            (header, footer, d) = (t, b, found)
            bandsKnown = true
            middleRows = span
            settled = max(0, middleRows - fresh)
        }
        let start = position + d, end = start + span
        if (max(end, middleRows) + header + footer) * rowBytes > maxBytes {
            isFull = true
            return .full
        }
        take(frame, bytesPerRow: bytesPerRow, at: start, in: buffer)
        position = start
        swap(&prints, &lastPrints)
        guard d != 0 else { return .unmoved }
        lastMove = d
        return .moved(d)
    }

    /// The picture so far, `pictureHeight` BGRA rows of `width` pixels, read in place.
    public func withPicture<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: buffer, count: buffer == nil ? 0 : pictureHeight * rowBytes))
    }

    /// Hands the picture over, `pictureHeight` BGRA rows of `width` pixels, for the caller to
    /// free with `deallocate()`; nothing more is added. Nil before the first frame.
    public func takePicture() -> UnsafeMutableRawBufferPointer? {
        guard started, let buffer else { return nil }
        self.buffer = nil
        isFull = true
        return UnsafeMutableRawBufferPointer(start: buffer, count: pictureHeight * rowBytes)
    }

    /// The newest frame as the picture so far, until the bands are known.
    private func keep(_ frame: UnsafeRawPointer, bytesPerRow: Int, in buffer: UnsafeMutableRawPointer) {
        for y in 0..<height { (buffer + y * rowBytes).copyMemory(from: frame + y * bytesPerRow, byteCount: rowBytes) }
        swap(&prints, &lastPrints)
    }

    /// The rows at the end of the middle taken again while they may still be being drawn: a
    /// third of it, below the middle of the area, where the pointer rests.
    private var fresh: Int { span / 3 }

    /// Takes `frame`'s middle, its first row at `start` in the picture's middle: over the rows
    /// not yet final, and below them those the picture does not have yet. A frame reaching the
    /// picture's end gives it its bottom band, right after the middle, and the rows it shows
    /// `fresh` above its own bottom are final.
    private func take(_ frame: UnsafeRawPointer, bytesPerRow: Int, at start: Int, in buffer: UnsafeMutableRawPointer) {
        let end = start + span
        let from = max(start, settled)
        guard from < end else { return }
        for row in from..<end {
            (buffer + (header + row) * rowBytes).copyMemory(from: frame + (header + row - start) * bytesPerRow, byteCount: rowBytes)
        }
        guard end >= middleRows else { return }
        middleRows = end
        for y in 0..<footer {
            (buffer + (header + middleRows + y) * rowBytes).copyMemory(from: frame + (height - footer + y) * bytesPerRow, byteCount: rowBytes)
        }
        settled = max(settled, min(middleRows, end - fresh))
    }

    // MARK: - Matching

    /// Each row's brightness averaged over `blocks` across it, into `prints`: `height` × `blocks`
    /// values, 0–255.
    private func fingerprint(_ frame: UnsafeRawPointer, bytesPerRow: Int) {
        let blocks = blocks, blockWidth = width / blocks, width = width
        prints.withUnsafeMutableBufferPointer { prints in
            for y in 0..<height {
                let row = (frame + y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for b in 0..<blocks {
                    let from = b * blockWidth, to = b == blocks - 1 ? width : from + blockWidth
                    // Every pixel: fewer would leave the prints noisy enough that a still band,
                    // a sticky header, no longer reads as still. BGRA, each channel summed apart
                    // and weighted once, which is the same as weighting each pixel.
                    var blue = 0, green = 0, red = 0
                    var p = row + from * 4
                    let end = row + to * 4
                    while p < end {
                        blue &+= Int(p[0])
                        green &+= Int(p[1])
                        red &+= Int(p[2])
                        p += 4
                    }
                    prints[y * blocks + b] = Float(red * 299 + green * 587 + blue * 114) / Float((to - from) * 1000)
                }
            }
        }
    }

    /// How unlike two rows' fingerprints are: the mean difference of their blocks.
    ///
    /// The innermost loops are `while` loops over pointers: a range's iterator is a generic call
    /// per step in a debug build, where the tests run.
    private static func unlike(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, _ blocks: Int) -> Float {
        var sum: Float = 0
        var i = 0
        while i < blocks {
            sum += (a[i] - b[i]).magnitude
            i += 1
        }
        return sum / Float(blocks)
    }

    /// Calls `body` with the newest frame's fingerprints and the last frame's, each row
    /// `blocks` apart.
    private func withPrints<R>(_ body: (UnsafePointer<Float>, UnsafePointer<Float>) -> R) -> R {
        prints.withUnsafeBufferPointer { after in lastPrints.withUnsafeBufferPointer { before in body(after.baseAddress!, before.baseAddress!) } }
    }

    /// The first move: the bands that stayed put since the last frame and how far the middle
    /// between them moved, or a nil shift when no shift fits it. Nil when nothing moved, or
    /// when what changed did not move (a caret, a spinner).
    ///
    /// The rows that stayed put are those alike; should those leave no shift fitting, as when
    /// something changing in a bar cut it short and left its still rows in the middle, those
    /// mostly alike. A band taken too big costs nothing; one taken too small would leave every
    /// later frame unmatched.
    private func firstMove() -> (Int?, Int, Int)? {
        guard let (t, b) = bands(lenient: false) else { return nil }
        (header, footer) = (t, b)
        defer { (header, footer) = (0, 0) }
        if let d = shift() { return d == 0 ? nil : (d, t, b) }
        if let (lt, lb) = bands(lenient: true), (lt, lb) != (t, b) {
            (header, footer) = (lt, lb)
            if let d = shift() { return d == 0 ? nil : (d, lt, lb) }
        }
        return (nil, t, b)
    }

    /// The bands that stayed put between the last frame and this one: the rows alike at the top
    /// and at the bottom, each a third of the frame at most, or none when the middle between
    /// them would be too short to match. Nil when nothing changed.
    ///
    /// The bottom band is at least `bottomMargin` of the frame: a window's rounded corners sit
    /// in its last rows, over content that moves, and rows taken from there would carry them
    /// into the middle of the picture at every step. Taken only from the last frame, they come
    /// once, at the bottom, where they were; what scrolls through that margin is taken higher up.
    ///
    /// `lenient`, a row is still unless more than a quarter of its blocks changed by more than
    /// `changed`: a spinner or a line of status changes a few blocks of a bar's rows, a move
    /// changes most of a row.
    private func bands(lenient: Bool) -> (Int, Int)? {
        let blocks = blocks
        let same = withPrints { after, before in
            (0..<height).map { y -> Bool in
                let a = after + y * blocks, b = before + y * blocks
                if Self.unlike(a, b, blocks) < Self.alike { return true }
                guard lenient else { return false }
                return (0..<blocks).count { abs(a[$0] - b[$0]) > Self.changed } * 4 <= blocks
            }
        }
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
    /// A block that changed by more than this, in levels, changed.
    static let changed: Float = 8
    /// A shift whose rows differ by more than this on average is not believed.
    static let fits: Float = 3

    /// How far the middle's content moved from the last frame to the newest, up being positive;
    /// 0 when it did not; nil when no shift fits.
    private func shift() -> Int? {
        let low = header, high = height - footer, rows = high - low
        let overlap = max(16, rows / 4)
        let reach = rows - overlap
        guard reach > 0 else { return nil }
        let blocks = blocks, lastMove = lastMove
        return withPrints { after, before in
            // The mean unlikeness of the newest frame's rows to the last one's `d` rows further
            // down, every `step`th row.
            func cost(_ d: Int, step: Int) -> Float {
                let from = max(low, low - d), to = min(high, high - d)
                var sum: Float = 0, n = 0
                var y = from
                while y < to {
                    sum += Self.unlike(after + y * blocks, before + (y + d) * blocks, blocks)
                    n += 1
                    y += step
                }
                return n > 0 ? sum / Float(n) : .infinity
            }
            // Still only when every row is: a mean over the rows misses a few lines of text
            // moving over a blank page. Otherwise not moving is one more shift to try.
            if (low..<high).allSatisfy({ Self.unlike(after + $0 * blocks, before + $0 * blocks, blocks) < Self.alike }) { return 0 }
            // Every fourth shift, every other row; then every shift near the one chosen. Shifts
            // near the last move first, since scrolling is smooth; all of them when none of
            // those fits.
            func coarse(_ range: ClosedRange<Int>) -> [(Int, Float)] {
                ([0] + stride(from: range.lowerBound / 4 * 4, through: range.upperBound, by: 4)).map { ($0, cost($0, step: 2)) }
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
}
