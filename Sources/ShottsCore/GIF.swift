import Foundation

/// Pixels a GIF is made from: 8-bit BGRA rows, as screen frames come. Alpha is ignored; a
/// recording is opaque. The memory is the caller's and need only last the call.
public struct BGRAFrame {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let base: UnsafeRawPointer

    public init(width: Int, height: Int, bytesPerRow: Int, base: UnsafeRawPointer) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.base = base
    }

    /// The pixel at `x`, `y` as 0xRRGGBB.
    @inline(__always) func rgb(_ x: Int, _ y: Int) -> UInt32 {
        let p = base.advanced(by: y * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
        return UInt32(p[2]) << 16 | UInt32(p[1]) << 8 | UInt32(p[0])
    }
}

// MARK: - Blue noise

/// A 64 by 64 blue-noise threshold map, made once by void-and-cluster (Ulichney, 1993). Its
/// thresholds are spread as evenly as can be at every density, so dithering with it looks like
/// fine grain rather than a grid. Being fixed, it gives a pixel the same threshold in every
/// frame: what stays still in a recording stays still, and costs nothing, in the GIF.
public enum BlueNoise {
    public static let size = 64
    /// Each cell's rank among the 4096, row by row: its threshold is (rank + 0.5) / 4096.
    public static let ranks: [UInt16] = make()

    @inline(__always) public static func threshold(_ x: Int, _ y: Int) -> Float {
        (Float(ranks[(y & 63) << 6 | (x & 63)]) + 0.5) / 4096
    }

    static func make() -> [UInt16] {
        let n = size, count = n * n
        // How strongly one dot presses on another, by their distance around the wrapped map.
        let sigma = 1.9
        var kernel = [Float](repeating: 0, count: count)
        for dy in 0..<n {
            for dx in 0..<n {
                let x = Double(min(dx, n - dx)), y = Double(min(dy, n - dy))
                kernel[dy * n + dx] = Float(exp(-(x * x + y * y) / (2 * sigma * sigma)))
            }
        }
        func press(_ energy: inout [Float], at i: Int, _ sign: Float) {
            let ix = i % n, iy = i / n
            kernel.withUnsafeBufferPointer { k in
                energy.withUnsafeMutableBufferPointer { e in
                    for y in 0..<n {
                        let ky = ((y - iy + n) % n) * n, row = y * n
                        for x in ix..<n { e[row + x] += sign * k[ky + x - ix] }
                        for x in 0..<ix { e[row + x] += sign * k[ky + x - ix + n] }
                    }
                }
            }
        }
        /// The dot most crowded by others, or the gap furthest from any.
        func extreme(_ energy: [Float], _ on: [Bool], dots: Bool) -> Int {
            var best = -1, value: Float = dots ? -.infinity : .infinity
            for i in 0..<count where on[i] == dots {
                if dots ? energy[i] > value : energy[i] < value { best = i; value = energy[i] }
            }
            return best
        }

        // A tenth of the cells, scattered by a fixed sequence, then relaxed: the most crowded dot
        // moves to the biggest gap until it would move back.
        var on = [Bool](repeating: false, count: count)
        var energy = [Float](repeating: 0, count: count)
        var seed: UInt64 = 0x5348_4F54_5453
        var dots = 0
        while dots < count / 10 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let i = Int(seed >> 33) % count
            if !on[i] { on[i] = true; press(&energy, at: i, 1); dots += 1 }
        }
        for _ in 0..<count {
            let crowded = extreme(energy, on, dots: true)
            on[crowded] = false; press(&energy, at: crowded, -1)
            let gap = extreme(energy, on, dots: false)
            on[gap] = true; press(&energy, at: gap, 1)
            if gap == crowded { break }
        }

        var ranks = [UInt16](repeating: 0, count: count)
        // The first dots rank lowest, taken away most crowded first.
        var fewer = on, fewerEnergy = energy, left = dots
        while left > 0 {
            let crowded = extreme(fewerEnergy, fewer, dots: true)
            fewer[crowded] = false; press(&fewerEnergy, at: crowded, -1)
            left -= 1
            ranks[crowded] = UInt16(left)
        }
        // The rest rank in the order they fill the biggest gap.
        while dots < count {
            let gap = extreme(energy, on, dots: false)
            on[gap] = true; press(&energy, at: gap, 1)
            ranks[gap] = UInt16(dots)
            dots += 1
        }
        return ranks
    }
}

// MARK: - Palette

/// A GIF's colors: at most 255, leaving one index for "unchanged" in frames after the first.
public struct GIFPalette: Equatable, Sendable {
    /// 0xRRGGBB each.
    public let colors: [UInt32]

    public init(colors: [UInt32]) {
        precondition(!colors.isEmpty && colors.count <= 255)
        self.colors = colors
    }
}

/// Gathers a clip's colors, frame by frame, and chooses one palette for all of it, so a color
/// never jumps between frames. The colors that cover much of the picture (window backgrounds,
/// text, a UI's flat fills) go in exactly as they are and are never dithered; the rest are
/// chosen by median cut over what remains.
public struct PaletteBuilder {
    /// Exact colors and how often each was seen, until there are too many to be worth counting.
    private var exact: [UInt32: Int] = [:]
    private var tooMany = false
    private static let exactLimit = 1 << 16
    /// Every sample by 5-bit color: how many, and the sums of their 8-bit channels.
    private var bins = [Int](repeating: 0, count: 1 << 15)
    private var sums = [Int](repeating: 0, count: 3 << 15)
    public private(set) var samples = 0

    public init() {}

    /// Counts a frame's colors, from about 250,000 of its pixels at most.
    public mutating func add(_ frame: BGRAFrame) {
        let step = max(1, Int((Double(frame.width * frame.height) / 250_000).squareRoot().rounded(.up)))
        var y = 0
        while y < frame.height {
            var x = 0
            while x < frame.width {
                count(frame.rgb(x, y), 1)
                x += step
            }
            y += step
        }
    }

    mutating func count(_ rgb: UInt32, _ n: Int) {
        samples += n
        if let seen = exact[rgb] {
            exact[rgb] = seen + n
        } else if !tooMany {
            if exact.count < Self.exactLimit { exact[rgb] = n } else { tooMany = true }
        }
        let bin = Self.bin(rgb)
        bins[bin] += n
        sums[bin * 3] += n * Int(rgb >> 16 & 0xFF)
        sums[bin * 3 + 1] += n * Int(rgb >> 8 & 0xFF)
        sums[bin * 3 + 2] += n * Int(rgb & 0xFF)
    }

    @inline(__always) static func bin(_ rgb: UInt32) -> Int {
        Int(rgb >> 19 & 0x1F) << 10 | Int(rgb >> 11 & 0x1F) << 5 | Int(rgb >> 3 & 0x1F)
    }

    /// The palette: every color when there are few enough, else the prominent colors exactly
    /// and median-cut colors for the rest.
    public func palette(maxColors: Int = 255) -> GIFPalette {
        guard samples > 0 else { return GIFPalette(colors: [0]) }
        if !tooMany, exact.count <= maxColors {
            return GIFPalette(colors: exact.keys.sorted())
        }
        // A color is prominent when it covers at least 1 in 500 of the samples; at most half
        // the palette goes to them.
        let prominent = exact.filter { $0.value * 500 >= samples }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(maxColors / 2)
        var bins = bins, sums = sums
        for (rgb, n) in prominent {
            let bin = Self.bin(rgb)
            bins[bin] -= n
            sums[bin * 3] -= n * Int(rgb >> 16 & 0xFF)
            sums[bin * 3 + 1] -= n * Int(rgb >> 8 & 0xFF)
            sums[bin * 3 + 2] -= n * Int(rgb & 0xFF)
        }
        let cut = Self.medianCut(bins: bins, sums: sums, colors: maxColors - prominent.count)
        var colors = prominent.map(\.key)
        for color in cut where !colors.contains(color) { colors.append(color) }
        return GIFPalette(colors: colors.isEmpty ? [0] : colors)
    }

    /// Splits the colors into `colors` boxes, each time halving the box that holds the most
    /// samples across the widest spread, at its median along its longest side; each box's color
    /// is the average of what is in it.
    static func medianCut(bins: [Int], sums: [Int], colors: Int) -> [UInt32] {
        struct Box {
            var cells: [Int]
            var count: Int
            var axis = 0
            var spread = 0
        }
        func measured(_ cells: [Int]) -> Box {
            var lo = (31, 31, 31), hi = (0, 0, 0), count = 0
            for c in cells {
                let r = c >> 10 & 31, g = c >> 5 & 31, b = c & 31
                lo = (min(lo.0, r), min(lo.1, g), min(lo.2, b))
                hi = (max(hi.0, r), max(hi.1, g), max(hi.2, b))
                count += bins[c]
            }
            let ranges = [hi.0 - lo.0, hi.1 - lo.1, hi.2 - lo.2]
            let axis = ranges.firstIndex(of: ranges.max()!)!
            return Box(cells: cells, count: count, axis: axis, spread: ranges[axis])
        }
        let filled = bins.indices.filter { bins[$0] > 0 }
        guard colors > 0, !filled.isEmpty else { return [] }
        var boxes = [measured(filled)]
        while boxes.count < colors {
            guard let i = boxes.indices.filter({ boxes[$0].cells.count > 1 })
                .max(by: { boxes[$0].count * (boxes[$0].spread + 1) < boxes[$1].count * (boxes[$1].spread + 1) })
            else { break }
            let box = boxes[i], shift = [10, 5, 0][box.axis]
            let sorted = box.cells.sorted { ($0 >> shift & 31, $0) < ($1 >> shift & 31, $1) }
            var running = 0, split = 1
            for (k, c) in sorted.enumerated() {
                running += bins[c]
                if running * 2 >= box.count { split = max(1, min(sorted.count - 1, k + 1)); break }
            }
            boxes[i] = measured(Array(sorted[..<split]))
            boxes.append(measured(Array(sorted[split...])))
        }
        return boxes.map { box in
            var r = 0, g = 0, b = 0
            for c in box.cells { r += sums[c * 3]; g += sums[c * 3 + 1]; b += sums[c * 3 + 2] }
            let n = max(box.count, 1)
            return UInt32((r + n / 2) / n) << 16 | UInt32((g + n / 2) / n) << 8 | UInt32((b + n / 2) / n)
        }
    }
}

// MARK: - Dithering

/// Maps colors to a palette, dithering what falls between its colors with blue noise. A color
/// in the palette maps to itself, undithered, so flat colors and text stay crisp. Any other
/// color is drawn as a mix of the palette color nearest it and the one on its far side, in
/// proportion to where it lies between them, the blue noise at each pixel choosing which: a
/// gradient comes out smooth rather than banded, and the grain is only as coarse as the
/// palette's colors there are apart.
public struct Quantizer {
    public let palette: GIFPalette
    private let r: [Int32], g: [Int32], b: [Int32]
    /// The nearest palette color to each 6-bit cell of color space, worked out on first use.
    private var nearest: [UInt16]
    private static let unknown = UInt16.max

    public init(palette: GIFPalette) {
        self.palette = palette
        r = palette.colors.map { Int32($0 >> 16 & 0xFF) }
        g = palette.colors.map { Int32($0 >> 8 & 0xFF) }
        b = palette.colors.map { Int32($0 & 0xFF) }
        nearest = [UInt16](repeating: Self.unknown, count: 1 << 18)
    }

    /// The palette index for `rgb` at pixel `x`, `y`.
    @inline(__always) public mutating func index(_ rgb: UInt32, x: Int, y: Int) -> UInt8 {
        let pr = Int32(rgb >> 16 & 0xFF), pg = Int32(rgb >> 8 & 0xFF), pb = Int32(rgb & 0xFF)
        let first = closest(pr, pg, pb)
        if palette.colors[first] == rgb { return UInt8(first) }
        // The color as far past this one as the nearest palette color is short of it: the
        // palette color nearest there is the other side of the step this color is on.
        let second = closest(min(max(2 * pr - r[first], 0), 255), min(max(2 * pg - g[first], 0), 255), min(max(2 * pb - b[first], 0), 255))
        guard second != first else { return UInt8(first) }
        let dr = r[second] - r[first], dg = g[second] - g[first], db = b[second] - b[first]
        let along = (pr - r[first]) * dr + (pg - g[first]) * dg + (pb - b[first]) * db
        let length = dr * dr + dg * dg + db * db
        guard along > 0, length > 0 else { return UInt8(first) }
        let t = min(Float(along) / Float(length), 1)
        return BlueNoise.threshold(x, y) < t ? UInt8(second) : UInt8(first)
    }

    /// The palette color nearest the middle of the 6-bit cell holding a color, weighing green
    /// most and blue least, as the eye does.
    @inline(__always) private mutating func closest(_ pr: Int32, _ pg: Int32, _ pb: Int32) -> Int {
        let cell = Int(pr >> 2) << 12 | Int(pg >> 2) << 6 | Int(pb >> 2)
        let known = nearest[cell]
        if known != Self.unknown { return Int(known) }
        let cr = pr & ~3 | 2, cg = pg & ~3 | 2, cb = pb & ~3 | 2
        var best = 0, distance = Int32.max
        for i in r.indices {
            let dr = r[i] - cr, dg = g[i] - cg, db = b[i] - cb
            let d = 2 * dr * dr + 4 * dg * dg + 3 * db * db
            if d < distance { best = i; distance = d }
        }
        nearest[cell] = UInt16(best)
        return best
    }
}

// MARK: - GIF89a

/// Writes an animated GIF89a that loops forever, frame by frame as they come, so a long clip is
/// never held whole. One palette serves every frame. After the first, a frame stores only the
/// rectangle that changed, with what did not change inside it left transparent, so what stays
/// still costs almost nothing; a frame that changes nothing only lengthens the one before.
public struct GIFWriter {
    public let width: Int
    public let height: Int
    private var quantizer: Quantizer
    private let write: (Data) -> Void
    /// The index for "as before": the one past the palette.
    private let transparent: UInt8
    /// The frame before, as colors and as the indices shown.
    private var previousColors: [UInt32]
    private var previousIndices: [UInt8]
    private var hasPrevious = false
    /// The frame waiting for its delay, which is known once the next change comes.
    private var pending: (image: [UInt8], start: Double)?

    /// Writes the header, the palette, and the instruction to loop.
    public init(width: Int, height: Int, palette: GIFPalette, write: @escaping (Data) -> Void) {
        precondition(width > 0 && width < 65536 && height > 0 && height < 65536)
        self.width = width
        self.height = height
        quantizer = Quantizer(palette: palette)
        self.write = write
        transparent = UInt8(palette.colors.count)
        previousColors = [UInt32](repeating: 0, count: width * height)
        previousIndices = [UInt8](repeating: 0, count: width * height)

        var head = Data("GIF89a".utf8)
        head.append(le16(width)); head.append(le16(height))
        // A global table of 256 colors, 8 bits each.
        head.append(contentsOf: [0xF7, 0, 0])
        for i in 0..<256 {
            let c = i < palette.colors.count ? palette.colors[i] : 0
            head.append(contentsOf: [UInt8(c >> 16 & 0xFF), UInt8(c >> 8 & 0xFF), UInt8(c & 0xFF)])
        }
        // NETSCAPE2.0: loop forever.
        head.append(contentsOf: [0x21, 0xFF, 0x0B])
        head.append(Data("NETSCAPE2.0".utf8))
        head.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])
        write(head)
    }

    /// Adds a frame of exactly this writer's size, shown from `time` (seconds from the start).
    public mutating func add(_ frame: BGRAFrame, at time: Double) {
        precondition(frame.width == width && frame.height == height)
        var minX = width, minY = height, maxX = -1, maxY = -1
        var indices = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x, rgb = frame.rgb(x, y)
                // A pixel unchanged since the frame before gets the same index: the dithering
                // is fixed per pixel, so the answer would be the same.
                let index = hasPrevious && rgb == previousColors[i] ? previousIndices[i] : quantizer.index(rgb, x: x, y: y)
                indices[i] = index
                previousColors[i] = rgb
                if !hasPrevious || index != previousIndices[i] {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return } // nothing changed: the frame before just shows longer
        let first = !hasPrevious
        let rect = (x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        var region = [UInt8](repeating: 0, count: rect.width * rect.height)
        for y in 0..<rect.height {
            for x in 0..<rect.width {
                let i = (rect.y + y) * width + rect.x + x
                region[y * rect.width + x] = !first && indices[i] == previousIndices[i] ? transparent : indices[i]
            }
        }
        previousIndices = indices
        hasPrevious = true
        flush(until: time)
        pending = (image(region, rect: rect, transparency: !first), time)
    }

    /// Writes the last frame, shown until `end`, and the trailer.
    public mutating func finish(at end: Double) {
        flush(until: end)
        write(Data([0x3B]))
    }

    private mutating func flush(until time: Double) {
        guard let (image, start) = pending else { return }
        pending = nil
        let delay = GIFTiming.delay(from: start, to: time)
        // Graphic control: leave the frame in place for the next to draw over; the delay; and
        // whether "as before" is transparent.
        var control = Data([0x21, 0xF9, 0x04, image[0] == 1 ? 0x05 : 0x04])
        control.append(le16(min(delay, 65535)))
        control.append(contentsOf: [transparent, 0x00])
        write(control)
        write(Data(image.dropFirst()))
    }

    /// An image descriptor and its compressed pixels, behind one byte that says whether the
    /// frame uses transparency (read back by `flush`, not written).
    private func image(_ region: [UInt8], rect: (x: Int, y: Int, width: Int, height: Int), transparency: Bool) -> [UInt8] {
        var out: [UInt8] = [transparency ? 1 : 0, 0x2C]
        out.append(contentsOf: le16(rect.x)); out.append(contentsOf: le16(rect.y))
        out.append(contentsOf: le16(rect.width)); out.append(contentsOf: le16(rect.height))
        out.append(0x00) // no local palette, not interlaced
        out.append(8) // LZW minimum code size
        let packed = LZW.encode(region)
        var i = 0
        while i < packed.count {
            let n = min(255, packed.count - i)
            out.append(UInt8(n))
            out.append(contentsOf: packed[i..<(i + n)])
            i += n
        }
        out.append(0x00)
        return out
    }
}

private func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]) }

/// GIF's LZW compression of 8-bit indices, the codes packed least significant bit first.
enum LZW {
    static func encode(_ indices: [UInt8]) -> [UInt8] {
        let clear: UInt32 = 256, end: UInt32 = 257
        var out: [UInt8] = []
        out.reserveCapacity(indices.count / 2)
        var bits: UInt32 = 0, used: UInt32 = 0
        var codeSize: UInt32 = 9, next: UInt32 = 258
        // Open addressing over (prefix, index) pairs; a new generation empties it at once.
        let slots = 8192
        var keys = [UInt32](repeating: 0, count: slots)
        var codes = [UInt16](repeating: 0, count: slots)
        var stamps = [UInt32](repeating: 0, count: slots)
        var generation: UInt32 = 1

        func emit(_ code: UInt32) {
            bits |= code << used
            used += codeSize
            while used >= 8 {
                out.append(UInt8(bits & 0xFF))
                bits >>= 8
                used -= 8
            }
        }
        emit(clear)
        guard var prefix = indices.first.map(UInt32.init) else {
            emit(end)
            if used > 0 { out.append(UInt8(bits & 0xFF)) }
            return out
        }
        for k in indices.dropFirst() {
            let key = prefix << 8 | UInt32(k)
            var slot = Int((key &* 2_654_435_761) >> 19) & (slots - 1)
            var found: UInt16?
            while stamps[slot] == generation {
                if keys[slot] == key { found = codes[slot]; break }
                slot = (slot + 1) & (slots - 1)
            }
            if let found {
                prefix = UInt32(found)
                continue
            }
            emit(prefix)
            if next < 4095 {
                keys[slot] = key; codes[slot] = UInt16(next); stamps[slot] = generation
                next += 1
                if next > (1 << codeSize), codeSize < 12 { codeSize += 1 }
            } else {
                emit(clear)
                generation += 1
                codeSize = 9
                next = 258
            }
            prefix = UInt32(k)
        }
        emit(prefix)
        emit(end)
        if used > 0 { out.append(UInt8(bits & 0xFF)) }
        return out
    }
}
