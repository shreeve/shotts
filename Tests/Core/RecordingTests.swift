import Foundation
import Testing
@testable import ShottsCore

@Suite struct RecordingRuleTests {
    @Test func recordedSizeIsWholeAndEven() {
        let size = RecordingRule.recordedSize(points: CGSize(width: 500.7, height: 301), scale: 2)
        #expect(size.width == 1000 && size.height == 602)
        let odd = RecordingRule.recordedSize(points: CGSize(width: 333, height: 111), scale: 1)
        #expect(odd.width == 332 && odd.height == 110)
    }

    @Test func aFileKeepsTheRecordingsProportionsEvenly() {
        let recorded = (width: 2000, height: 1000)
        let size = RecordingRule.size(width: 701, format: .gif, recorded: recorded)
        #expect(size.width == 700 && size.height == 350)
        // Never wider than the recording, never narrower than the least.
        #expect(RecordingRule.size(width: 5000, format: .gif, recorded: recorded).width == 2000)
        #expect(RecordingRule.size(width: 3, format: .mp4, recorded: recorded).width == RecordingRule.minWidth)
    }

    @Test func mp4StaysWithinWhatH264PlayersTake() {
        let fiveK = (width: 5120, height: 2880)
        #expect(RecordingRule.maxWidth(for: .mp4, recorded: fiveK) == 4096) // 16:9 fits exactly
        #expect(RecordingRule.maxWidth(for: .mp4, recorded: (width: 5000, height: 3000)) == 3840) // held by the height
        let size = RecordingRule.size(width: 99999, format: .mp4, recorded: fiveK)
        #expect(size.width <= 4096 && size.height <= 2304)
        #expect(RecordingRule.maxWidth(for: .gif, recorded: fiveK) == 5120)
        #expect(RecordingRule.maxWidth(for: .mp4, recorded: (width: 1200, height: 800)) == 1200)
    }

    @Test func everyRateDividesTheRecordingsAndGIFsStopAt30() {
        for format in RecordingSettings.Format.allCases {
            for rate in RecordingRule.frameRates(for: format) { #expect(RecordingRule.recordedFrameRate % rate == 0) }
        }
        #expect(RecordingRule.frameRates(for: .gif).max() == 30)
        #expect(RecordingRule.frameRates(for: .mp4) == [60, 30, 20, 10, 5, 1])
        #expect(RecordingRule.frameRates(for: .gif) == [30, 20, 10, 5, 1])
    }

    @Test func defaultsKeepTheMicrophoneAndLeaveOutTheMacsSound() {
        let recorded = (width: 2000, height: 1000)
        let mp4 = RecordingRule.defaults(for: .mp4, recorded: recorded, scale: 2, hasMicrophone: true)
        #expect(mp4 == RecordingSettings(format: .mp4, percent: 100, frameRate: 30, sound: .microphone))
        #expect(RecordingRule.defaults(for: .mp4, recorded: recorded, scale: 2, hasMicrophone: false).sound == RecordingSettings.Sound.none)
        // A GIF starts at the size the area had on screen.
        #expect(RecordingRule.defaults(for: .gif, recorded: recorded, scale: 2, hasMicrophone: true)
            == RecordingSettings(format: .gif, percent: 50, frameRate: 10, sound: .none))
        #expect(RecordingRule.defaults(for: .gif, recorded: recorded, scale: 1, hasMicrophone: true).percent == 100)
    }

    @Test func sizesAreShareOfTheRecording() {
        #expect(RecordingRule.sizes == [100, 75, 50, 25])
        let recorded = (width: 1898, height: 948)
        let half = RecordingRule.size(percent: 50, format: .mp4, recorded: recorded)
        #expect(half.width == 948 && half.height == 474)
        let quarter = RecordingRule.size(percent: 25, format: .gif, recorded: recorded)
        #expect(quarter.width % 2 == 0 && quarter.height % 2 == 0 && quarter.width == 474)
    }
}

@Suite struct FrameSamplerTests {
    @Test func aFrameShowsAtTheFirstTickFromItsTime() {
        #expect(FrameSampler.tick(for: 0, until: 1, rate: 30) == 0)
        #expect(FrameSampler.tick(for: 0.05, until: 1, rate: 10) == 0.1)
        // A hair past a tick, from rounding, is that tick.
        #expect(FrameSampler.tick(for: 2.0 / 30 + 1e-9, until: 1, rate: 30) == 2.0 / 30)
    }

    @Test func aFrameReplacedBeforeATickIsLeftOut() {
        #expect(FrameSampler.tick(for: 0.01, until: 0.02, rate: 30) == nil)
    }

    /// The last change before a pause shows at the next tick rather than being lost.
    @Test func theLastChangeBeforeAPauseIsKept() {
        let times = [0, 0.005, 3.0]
        let kept = zip(times, times.dropFirst() + [4.0]).compactMap { FrameSampler.tick(for: $0, until: $1, rate: 30) }
        #expect(kept.count == 3)
        #expect(kept[1] == 1.0 / 30)
    }

    @Test func sixtyFramesASecondKeepAQuarterAtFifteen() {
        let times = (0..<120).map { Double($0) / 60 }
        let kept = zip(times, times.dropFirst() + [2.0]).compactMap { FrameSampler.tick(for: $0, until: $1, rate: 15) }
        #expect(kept.count == 30)
    }

    @Test func gifDelaysAddUpExactly() {
        let times = (0...30).map { Double($0) / 30 }
        let delays = zip(times, times.dropFirst()).map { GIFTiming.delay(from: $0, to: $1) }
        #expect(delays.reduce(0, +) == 100)
        #expect(Set(delays) == [3, 4])
        #expect(GIFTiming.delay(from: 0, to: 0.001) == 2)
    }
}

@Suite struct BlueNoiseTests {
    @Test func everyThresholdOnce() {
        #expect(BlueNoise.ranks.count == 4096)
        #expect(Set(BlueNoise.ranks).count == 4096)
        #expect(BlueNoise.ranks.max() == 4095)
    }

    /// Blue noise is even at every scale: any 8 by 8 patch holds thresholds from low to high in
    /// about equal measure.
    @Test func everyPatchIsBalanced() {
        for by in stride(from: 0, to: 64, by: 8) {
            for bx in stride(from: 0, to: 64, by: 8) {
                var sum: Float = 0
                for y in by..<(by + 8) { for x in bx..<(bx + 8) { sum += BlueNoise.threshold(x, y) } }
                #expect(abs(sum / 64 - 0.5) < 0.08)
            }
        }
    }

    /// The first dots, the ones a light dither shows, never touch, even diagonally, even across
    /// the map's wrapped edges.
    @Test func theSparsestDotsKeepApart() {
        let first = BlueNoise.ranks.indices.filter { BlueNoise.ranks[$0] < 256 }
        for a in first {
            for b in first where b != a {
                let dx = abs(a % 64 - b % 64), dy = abs(a / 64 - b / 64)
                #expect(max(min(dx, 64 - dx), min(dy, 64 - dy)) > 1)
            }
        }
    }
}

/// A BGRA picture held for a test, filled by `color(x, y)` as 0xRRGGBB.
private final class Picture {
    let width: Int, height: Int
    var bytes: [UInt8]

    init(_ width: Int, _ height: Int, _ color: (Int, Int) -> UInt32) {
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width { set(x, y, color(x, y)) } }
    }

    func set(_ x: Int, _ y: Int, _ c: UInt32) {
        let o = (y * width + x) * 4
        bytes[o] = UInt8(c & 0xFF); bytes[o + 1] = UInt8(c >> 8 & 0xFF); bytes[o + 2] = UInt8(c >> 16 & 0xFF)
    }

    func frame<T>(_ body: (BGRAFrame) -> T) -> T {
        bytes.withUnsafeBytes { body(BGRAFrame(width: width, height: height, bytesPerRow: width * 4, base: $0.baseAddress!)) }
    }
}

/// A picture as a screen recording has them: a flat window color, dark text-like marks, and a
/// smooth gradient across the bottom.
private func screenLike(_ width: Int = 96, _ height: Int = 48) -> Picture {
    Picture(width, height) { x, y in
        if y >= height * 3 / 4 { return UInt32(x * 255 / (width - 1)) << 16 | 0x40 << 8 | UInt32(255 - x * 255 / (width - 1)) }
        if y % 8 == 3, x % 6 < 4 { return 0x1D1D1F }
        return 0xF5F5F7
    }
}

@Suite struct PaletteTests {
    @Test func fewColorsAreKeptExactly() {
        var builder = PaletteBuilder()
        Picture(20, 20) { x, _ in x < 10 ? 0xFF0000 : 0x00FF00 }.frame { builder.add($0) }
        #expect(Set(builder.palette().colors) == [0xFF0000, 0x00FF00])
    }

    /// With more colors than fit, the flat ones that cover the picture are still exact.
    @Test func prominentColorsSurviveMedianCut() {
        var builder = PaletteBuilder()
        Picture(512, 256) { x, y in
            if y < 128 { return x < 256 ? 0xF5F5F7 : 0x1D1D1F }
            return UInt32(x / 2) << 16 | UInt32(y - 128) << 9 & 0xFF00 | UInt32(x % 256)
        }.frame { builder.add($0) }
        let colors = builder.palette().colors
        #expect(colors.count <= 255)
        #expect(colors.contains(0xF5F5F7) && colors.contains(0x1D1D1F))
    }
}

@Suite struct QuantizerTests {
    @Test func aPaletteColorIsNeverDithered() {
        var q = Quantizer(palette: GIFPalette(colors: [0x000000, 0xFFFFFF, 0x3478F6]))
        for y in 0..<64 { for x in 0..<64 { #expect(q.index(0x3478F6, x: x, y: y) == 2) } }
    }

    /// A color between two palette colors is drawn as a mix of them in proportion.
    @Test func betweenColorsMixInProportion() {
        var q = Quantizer(palette: GIFPalette(colors: [0x000000, 0xFFFFFF]))
        func share(_ gray: UInt32) -> Double {
            var white = 0
            for y in 0..<64 { for x in 0..<64 where q.index(gray << 16 | gray << 8 | gray, x: x, y: y) == 1 { white += 1 } }
            return Double(white) / 4096
        }
        #expect(abs(share(0x80) - 0.5) < 0.02)
        #expect(abs(share(0x40) - 0.25) < 0.02)
        #expect(share(0x00) == 0)
    }

    /// The same color at the same pixel always gets the same index, so still parts of a
    /// recording stay still.
    @Test func ditheringIsFixedPerPixel() {
        var a = Quantizer(palette: GIFPalette(colors: [0x000000, 0xFFFFFF]))
        var b = Quantizer(palette: GIFPalette(colors: [0x000000, 0xFFFFFF]))
        for y in 0..<16 { for x in 0..<16 { #expect(a.index(0x777777, x: x, y: y) == b.index(0x777777, x: x, y: y)) } }
    }
}

// MARK: - Reading GIFs back

/// A GIF as a viewer shows it: its palette, whether it loops, and each frame's delay, the
/// rectangle it drew, and the whole picture after it, as palette indices.
private struct DecodedGIF {
    var width = 0, height = 0
    var palette: [UInt32] = []
    var loops = false
    var frames: [(delay: Int, rect: (x: Int, y: Int, width: Int, height: Int), canvas: [UInt8])] = []
}

private func decode(_ data: [UInt8]) throws -> DecodedGIF {
    struct Bad: Error {}
    var gif = DecodedGIF()
    var i = 0
    func byte() throws -> Int { guard i < data.count else { throw Bad() }; defer { i += 1 }; return Int(data[i]) }
    func word() throws -> Int { try byte() | (try byte() << 8) }
    func blocks() throws -> [UInt8] {
        var out: [UInt8] = []
        while true {
            let n = try byte()
            if n == 0 { return out }
            guard i + n <= data.count else { throw Bad() }
            out += data[i..<(i + n)]
            i += n
        }
    }
    guard String(decoding: data.prefix(6), as: UTF8.self) == "GIF89a" else { throw Bad() }
    i = 6
    gif.width = try word(); gif.height = try word()
    let packed = try byte(); _ = try byte(); _ = try byte()
    if packed & 0x80 != 0 {
        for _ in 0..<(1 << ((packed & 7) + 1)) { gif.palette.append(UInt32(try byte()) << 16 | UInt32(try byte()) << 8 | UInt32(try byte())) }
    }
    var canvas = [UInt8](repeating: 0, count: gif.width * gif.height)
    var control = (delay: 0, transparent: Optional<Int>.none)
    while true {
        switch try byte() {
        case 0x21:
            let label = try byte()
            let body = try blocks()
            if label == 0xFF, String(decoding: body.prefix(11), as: UTF8.self) == "NETSCAPE2.0" { gif.loops = true }
            if label == 0xF9 {
                control = (Int(body[1]) | Int(body[2]) << 8, body[0] & 1 != 0 ? Int(body[3]) : nil)
            }
        case 0x2C:
            let rect = (x: try word(), y: try word(), width: try word(), height: try word())
            _ = try byte()
            let minimumCodeSize = try byte()
            let pixels = try lzwDecode(try blocks(), minimumCodeSize: minimumCodeSize, count: rect.width * rect.height)
            for y in 0..<rect.height {
                for x in 0..<rect.width {
                    let p = pixels[y * rect.width + x]
                    if let t = control.transparent, Int(p) == t { continue }
                    canvas[(rect.y + y) * gif.width + rect.x + x] = p
                }
            }
            gif.frames.append((control.delay, rect, canvas))
        case 0x3B:
            return gif
        default:
            throw Bad()
        }
    }
}

/// GIF's LZW, decoded the way viewers do, to check the encoder against.
private func lzwDecode(_ data: [UInt8], minimumCodeSize: Int, count: Int) throws -> [UInt8] {
    struct Bad: Error {}
    let clear = 1 << minimumCodeSize, end = clear + 1
    var table: [[UInt8]] = []
    var codeSize = 0
    func reset() {
        table = (0..<clear).map { [UInt8($0)] } + [[], []]
        codeSize = minimumCodeSize + 1
    }
    reset()
    var out: [UInt8] = [], previous: [UInt8]?
    var bit = 0
    func read() -> Int? {
        guard bit + codeSize <= data.count * 8 else { return nil }
        var code = 0
        for k in 0..<codeSize where data[(bit + k) / 8] >> ((bit + k) % 8) & 1 == 1 { code |= 1 << k }
        bit += codeSize
        return code
    }
    while let code = read() {
        if code == clear { reset(); previous = nil; continue }
        if code == end { break }
        let entry: [UInt8]
        if code < table.count, code != clear, code != end {
            entry = table[code]
        } else if code == table.count, let p = previous {
            entry = p + [p[0]]
        } else {
            throw Bad()
        }
        out += entry
        if let p = previous, table.count < 4096 { table.append(p + [entry[0]]) }
        if table.count == 1 << codeSize, codeSize < 12 { codeSize += 1 }
        previous = entry
    }
    guard out.count == count else { throw Bad() }
    return out
}

@Suite struct GIFTests {
    @Test func lzwSurvivesClearsAndLongRuns() throws {
        var seed: UInt32 = 7
        let noise = (0..<120_000).map { _ -> UInt8 in seed = seed &* 1_103_515_245 &+ 12345; return UInt8(seed >> 16 & 0xFF) }
        for indices in [noise, [UInt8](repeating: 3, count: 100_000), Array((0..<50_000).map { UInt8($0 % 7) }), [5]] {
            #expect(try lzwDecode(LZW.encode(indices), minimumCodeSize: 8, count: indices.count) == indices)
        }
    }

    /// A clip written and read back: it loops, a frame that changes nothing only lengthens the
    /// one before, a later frame stores only what changed, and every frame shows exactly the
    /// quantized picture.
    @Test func framesRoundTrip() throws {
        let a = screenLike(), b = screenLike(), d = screenLike()
        for x in 10..<20 { b.set(x, 5, 0x3478F6) }
        for y in 0..<48 { d.set(90, y, 0xFF3B30) }
        var builder = PaletteBuilder()
        for p in [a, b, d] { p.frame { builder.add($0) } }
        let palette = builder.palette()

        var bytes: [UInt8] = []
        var writer = GIFWriter(width: 96, height: 48, palette: palette) { bytes += $0 }
        a.frame { writer.add($0, at: 0) }
        b.frame { writer.add($0, at: 0.1) }
        b.frame { writer.add($0, at: 0.2) } // no change
        d.frame { writer.add($0, at: 0.3) }
        writer.finish(at: 0.5)

        let gif = try decode(bytes)
        #expect(gif.width == 96 && gif.height == 48 && gif.loops)
        #expect(gif.frames.map(\.delay) == [10, 20, 20])
        #expect(gif.frames[0].rect.width == 96 && gif.frames[0].rect.height == 48)
        #expect(gif.frames[1].rect == (x: 10, y: 5, width: 10, height: 1))
        for (picture, frame) in zip([a, b, d], gif.frames) {
            var q = Quantizer(palette: palette)
            for y in 0..<48 {
                for x in 0..<96 {
                    let o = (y * 96 + x) * 4
                    let rgb = UInt32(picture.bytes[o + 2]) << 16 | UInt32(picture.bytes[o + 1]) << 8 | UInt32(picture.bytes[o])
                    #expect(frame.canvas[y * 96 + x] == q.index(rgb, x: x, y: y))
                }
            }
        }
        // The window's flat color is in the palette and comes out exactly.
        #expect(gif.palette[Int(gif.frames[0].canvas[0])] == 0xF5F5F7)
    }

    /// A smooth gradient comes out as a mix, not bands: along it, every palette color in reach is
    /// used, and neighboring columns differ.
    @Test func gradientsAreDitheredNotBanded() throws {
        let ramp = Picture(256, 32) { x, _ in UInt32(x) << 16 | UInt32(x) << 8 | UInt32(x) }
        var bytes: [UInt8] = []
        var writer = GIFWriter(width: 256, height: 32, palette: GIFPalette(colors: (0..<8).map { UInt32($0 * 36) * 0x010101 })) { bytes += $0 }
        ramp.frame { writer.add($0, at: 0) }
        writer.finish(at: 1)
        let canvas = try decode(bytes).frames[0].canvas
        // Between two palette grays, a column holds both.
        let column = Set((0..<32).map { canvas[$0 * 256 + 18] })
        #expect(column == [0, 1])
    }
}

@Suite struct TrimTests {
    @Test func handlesStopShortOfEachOtherAndTheEnds() {
        let whole = Trim.whole(10)
        #expect(whole.isWhole(10))
        #expect(whole.movingStart(to: -3).start == 0)
        #expect(whole.movingStart(to: 12).start == 10 - Trim.shortest)
        let cut = whole.movingStart(to: 2).movingEnd(to: 7, duration: 10)
        #expect(cut == Trim(start: 2, end: 7) && cut.length == 5 && !cut.isWhole(10))
        #expect(cut.movingEnd(to: 1, duration: 10).end == 2 + Trim.shortest)
        #expect(cut.movingEnd(to: 99, duration: 10).end == 10)
    }

    @Test func settingsCarryTheTrim() {
        var s = RecordingSettings(format: .mp4, percent: 100, frameRate: 30, sound: .none)
        #expect(s.trim == nil)
        s.trim = Trim(start: 1, end: 2)
        #expect(s != RecordingSettings(format: .mp4, percent: 100, frameRate: 30, sound: .none))
    }
}

@Suite struct TimelineLayoutTests {
    @Test func timesAndPlacesMapBothWays() {
        let t = TimelineLayout(width: 400, duration: 20)
        #expect(t.x(for: 5) == 100 && t.time(at: 100) == 5)
        #expect(t.x(for: -1) == 0 && t.x(for: 99) == 400)
        #expect(t.time(at: -10) == 0 && t.time(at: 1000) == 20)
    }

    @Test func aPressTakesTheNearerHandleInReach() {
        let t = TimelineLayout(width: 400, duration: 20)
        let trim = Trim(start: 5, end: 15) // x 100 and 300
        #expect(t.part(at: 104, of: trim) == .start)
        #expect(t.part(at: 295, of: trim) == .end)
        #expect(t.part(at: 200, of: trim) == .track)
        // Together, the press's side decides which moves.
        let together = Trim(start: 10, end: 10.1)
        #expect(t.part(at: 195, of: together) == .start)
        #expect(t.part(at: 206, of: together) == .end)
    }
}

@Suite struct PauseClockTests {
    /// What is recorded during a pause is dropped, and what follows picks up where it left off.
    @Test func pausesAreTakenOut() {
        var clock = PauseClock()
        #expect(clock.recorded(3) == 3)
        clock.pause(at: 4)
        #expect(clock.isPaused && clock.recorded(5) == nil)
        #expect(clock.elapsed(at: 9) == 4)
        clock.resume(at: 10)
        #expect(!clock.isPaused)
        #expect(clock.recorded(10) == 4 && clock.recorded(12) == 6)
        #expect(clock.elapsed(at: 12) == 6)
        // A sample from before the pause that arrives late keeps its time; one from within it
        // is still dropped.
        #expect(clock.recorded(3.5) == 3.5 && clock.recorded(7) == nil)
        clock.pause(at: 13)
        clock.resume(at: 15)
        #expect(clock.recorded(16) == 8)
    }

    @Test func pausingTwiceOrResumingUnpausedChangesNothing() {
        var clock = PauseClock()
        clock.resume(at: 2)
        #expect(clock.recorded(2) == 2)
        clock.pause(at: 3)
        clock.pause(at: 5)
        clock.resume(at: 6)
        #expect(clock.recorded(6) == 3)
    }
}
