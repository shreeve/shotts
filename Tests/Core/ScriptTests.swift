import Foundation
import Testing
@testable import ShottsCore

@Suite struct ScriptParserTests {
    private func parse(_ line: String) throws(ScriptUsageError) -> ScriptRequest {
        try ScriptParser.parse(line.split(separator: " ").map(String.init), workingDirectory: "/work")
    }

    @Test func timesTakeUnits() {
        #expect(ScriptParser.seconds("5") == 5)
        #expect(ScriptParser.seconds("500ms") == 0.5)
        #expect(ScriptParser.seconds("1.5s") == 1.5)
        #expect(ScriptParser.seconds("2m") == 120)
        #expect(ScriptParser.seconds("1m30s") == 90)
        #expect(ScriptParser.seconds("1m30") == nil && ScriptParser.seconds("5x") == nil && ScriptParser.seconds("") == nil && ScriptParser.seconds("-1") == nil)
    }

    /// Each file's format comes from its extension, and every one listed is made; paths are
    /// absolute, taken from the working directory.
    @Test func filesAndFlags() throws {
        let r = try parse("record demo.mp4 /tmp/demo.gif --window Safari --delay 2s --duration 1m --fps 20 --width 720 --json")
        #expect(r.command == .record && r.json)
        #expect(r.outputs == ["/work/demo.mp4", "/tmp/demo.gif"])
        #expect(r.target == ScriptTarget(window: "Safari"))
        #expect(r.delay == 2 && r.duration == 60 && r.fps == 20 && r.width == 720)
        let shot = try parse("shot a.png b.JPG c.heic --display 2 --region 10,20,300,200")
        #expect(shot.target == ScriptTarget(display: 2, region: CGRect(x: 10, y: 20, width: 300, height: 200)))
        #expect(shot.outputs.map { OutputFormat.of($0) } == [.png, .jpg, .heic])
    }

    /// A target is required; formats fit the command; an unknown extension is an error, never a
    /// silent PNG; a frame rate must be one a format takes.
    @Test func mistakesAreUsageErrors() {
        for line in ["shot a.png", "record x.mp4", "shot a.gif --window x", "record a.png --window x", "shot a.tiff --window x",
                     "record a.mov --window x", "shot a.png --window x --fps 10", "record a.gif --window x --fps 60",
                     "record a.mp4 --window x --display 1", "stop --json --window x", "list a.png", "frob", "", "record --window",
                     "record a.mp4 --window x --duration 0", "shot a.png --display 0 ", "shot a.png --region 1,2,3"] {
            #expect(throws: ScriptUsageError.self, "\(line)") { try parse(line) }
        }
        #expect(throws: ScriptUsageError.self) { try ScriptParser.parse([], workingDirectory: "/") }
    }

    @Test func stopAndListTakeOnlyJSON() throws {
        #expect(try parse("stop").command == .stop)
        #expect(try parse("list --json").json)
    }
}

@Suite struct WindowMatchTests {
    private let windows = [
        ScriptWindow(id: 40, app: "Safari", bundle: "com.apple.Safari", title: "Shotts — GitHub", frame: [0, 0, 800, 600], display: 1),
        ScriptWindow(id: 41, app: "Safari", bundle: "com.apple.Safari", title: "Docs", frame: [0, 0, 800, 600], display: 1),
        ScriptWindow(id: 50, app: "Terminal", bundle: "com.apple.Terminal", title: "zsh", frame: [0, 0, 800, 600], display: 2),
    ]

    @Test func idsNamesAndTitles() {
        #expect(WindowMatch.find("41", in: windows) == .one(windows[1]))
        #expect(WindowMatch.find("99", in: windows) == .none)
        // Exactly an app's name or bundle id: its frontmost window.
        #expect(WindowMatch.find("safari", in: windows) == .one(windows[0]))
        #expect(WindowMatch.find("com.apple.Terminal", in: windows) == .one(windows[2]))
        // Part of a title or name: one, none, or the candidates, never the first.
        #expect(WindowMatch.find("github", in: windows) == .one(windows[0]))
        #expect(WindowMatch.find("nothing", in: windows) == .none)
        #expect(WindowMatch.find("o", in: windows) == .ambiguous(windows))
    }
}

@Suite struct ScriptResultTests {
    /// Exit codes follow the error, and the answer is one line of JSON.
    @Test func codesAndLines() throws {
        #expect([ScriptErrorCode.usage, .permission, .notAllowed, .notFound, .ambiguousWindow, .busy, .captureFailed, .encodeFailed].map(\.exitCode)
            == [2, 3, 3, 4, 4, 5, 1, 1])
        let failure = ScriptResult.failure(.shot, ScriptError(.ambiguousWindow, "two windows match", candidates: []))
        let line = failure.line()
        #expect(line.last == UInt8(ascii: "\n") && !line.dropLast().contains(UInt8(ascii: "\n")))
        let text = String(decoding: line, as: UTF8.self)
        #expect(text.contains(#""code":"ambiguous_window""#) && text.contains(#""ok":false"#))
        #expect(try JSONDecoder().decode(ScriptResult.self, from: line) == failure)
        var request = ScriptRequest(command: .record)
        request.outputs = ["/a.mp4"]
        #expect(try JSONDecoder().decode(ScriptRequest.self, from: request.line()) == request)
    }
}

@Suite struct ScriptSizeTests {
    /// `--width` makes a file narrower in proportion, never wider than what was captured.
    @Test func widthNeverUpscales() {
        #expect(ScriptRequest.stillSize(width: 2000, height: 1000, requested: 800) == (800, 400))
        #expect(ScriptRequest.stillSize(width: 2000, height: 1001, requested: 999) == (999, 500))
        #expect(ScriptRequest.stillSize(width: 600, height: 400, requested: 1200) == (600, 400))
        #expect(ScriptRequest.stillSize(width: 600, height: 400, requested: nil) == (600, 400))
        var settings = RecordingSettings(format: .gif, percent: 50, frameRate: 20, sound: .none, width: 640)
        #expect(settings.size(recorded: (1280, 720)) == (640, 360))
        settings.width = 4000
        #expect(settings.size(recorded: (1280, 720)) == (1280, 720))
        settings.width = nil
        #expect(settings.size(recorded: (1280, 720)) == (640, 360))
        // An MP4 still keeps within H.264's limit.
        let mp4 = RecordingSettings(format: .mp4, percent: 100, frameRate: 30, sound: .none, width: 6000)
        #expect(mp4.size(recorded: (6016, 3384)).width <= 4096)
    }

    @Test func filesWhenNoneAreNamed() {
        #expect(ScriptRequest(command: .shot).defaultFormat == .png)
        #expect(ScriptRequest(command: .record).defaultFormat == .mp4)
        #expect(ScriptRequest(command: .start).defaultFormat == .mp4)
    }
}

@Suite struct ScriptAimTests {
    // A main display, and a second to its right; a window on each.
    let displays = [ScriptDisplay(number: 1, frame: [0, 0, 1512, 982], scale: 2), ScriptDisplay(number: 2, frame: [1512, 0, 1920, 1080], scale: 1)]
    let windows = [
        ScriptWindow(id: 7, app: "Safari", bundle: "com.apple.Safari", title: "Docs", frame: [100, 50, 800, 600], display: 1),
        ScriptWindow(id: 9, app: "Notes", bundle: "com.apple.Notes", title: "List", frame: [1600, 100, 400, 300], display: 2),
    ]

    func aim(_ target: ScriptTarget) -> Result<ScriptAim, ScriptError> { ScriptAim.of(target, windows: windows, displays: displays) }

    @Test func windowsAndDisplays() throws {
        let window = try aim(ScriptTarget(window: "notes")).get()
        #expect(window.source == .window(9))
        #expect(window.info.kind == "window" && window.info.scale == 1 && window.info.display == 2)
        let whole = try aim(ScriptTarget(display: 2)).get()
        #expect(whole.source == .area(display: 2, rect: CGRect(x: 0, y: 0, width: 1920, height: 1080)))
        #expect(whole.info.frame == [1512, 0, 1920, 1080])
    }

    /// A region is measured from the window or display, and cut to the display.
    @Test func regions() throws {
        let inWindow = try aim(ScriptTarget(window: "7", region: CGRect(x: 10, y: 20, width: 100, height: 50))).get()
        #expect(inWindow.source == .area(display: 1, rect: CGRect(x: 110, y: 70, width: 100, height: 50)))
        #expect(inWindow.info.kind == "region" && inWindow.info.frame == [110, 70, 100, 50])
        let onSecond = try aim(ScriptTarget(display: 2, region: CGRect(x: 1800, y: 1000, width: 400, height: 400))).get()
        #expect(onSecond.source == .area(display: 2, rect: CGRect(x: 1800, y: 1000, width: 120, height: 80)))
        #expect(onSecond.info.frame == [3312, 1000, 120, 80])
        let onMain = try aim(ScriptTarget(region: CGRect(x: 0, y: 0, width: 10, height: 10))).get()
        #expect(onMain.source == .area(display: 1, rect: CGRect(x: 0, y: 0, width: 10, height: 10)))
    }

    @Test func mistakes() {
        func code(_ t: ScriptTarget) -> ScriptErrorCode? { if case let .failure(e) = aim(t) { e.code } else { nil } }
        #expect(code(ScriptTarget(window: "Xcode")) == .notFound)
        #expect(code(ScriptTarget(window: "s")) == .ambiguousWindow)
        #expect(code(ScriptTarget(display: 3)) == .notFound)
        #expect(code(ScriptTarget(display: 1, region: CGRect(x: 2000, y: 0, width: 10, height: 10))) == .usage)
    }
}

@Suite struct ScriptHelpTests {
    /// Help fits a standard terminal, and is what no arguments, `help`, -h, or --help ask for.
    @Test func helpFitsAndIsAskedFor() {
        let help = ScriptParser.help(version: "10.20.30")
        let widest = help.split(separator: "\n").map(\.count).max() ?? 0
        #expect(widest <= 80)
        #expect(help.hasPrefix("shotts 10.20.30\nScreenshots and screen recordings"))
        #expect(ScriptParser.help(version: nil).hasPrefix("shotts\nScreenshots"))
        #expect(ScriptParser.wantsHelp([]) && ScriptParser.wantsHelp(["help"]) && ScriptParser.wantsHelp(["shot", "--help"]))
        #expect(ScriptParser.wantsHelp(["-h"]) && !ScriptParser.wantsHelp(["list"]))
        #expect(["version", "-V", "-v", "--version"].allSatisfy { ScriptParser.wantsVersion([$0]) })
        #expect(!ScriptParser.wantsVersion(["list", "-v"]) && !ScriptParser.wantsVersion([]))
        // A mistake says what is wrong in a line, not the whole help.
        #expect(throws: ScriptUsageError("unknown option '--colour'")) {
            try ScriptParser.parse(["shot", "--colour"], workingDirectory: "/")
        }
    }
}

@Suite struct ScriptListingTests {
    let displays = [ScriptDisplay(number: 1, frame: [0, 0, 1512, 982], scale: 2), ScriptDisplay(number: 2, frame: [1512, 0, 1920, 1080], scale: 1)]
    let windows = [
        ScriptWindow(id: 4211, app: "Safari", bundle: "com.apple.Safari", title: "GitHub - shreeve/shotts: a screenshot tool", frame: [0, 30, 1200, 800], display: 1),
        ScriptWindow(id: 87, app: "Terminal", bundle: "com.apple.Terminal", title: "", frame: [1600, 100, 640, 480.5], display: 2),
    ]

    /// For scripts: columns, no boxes, no notes, the title cut to the width.
    @Test func plainColumns() {
        let tables = ScriptListing.tables(windows: windows, displays: displays, version: "0.6.0")
        #expect(tables.map { $0.plain(width: 60) }.joined(separator: "\n") == """
            DISPLAY  SIZE       SCALE  AT
            1 main    1512×982     2x  0,0
            2        1920×1080     1x  1512,0

            ID    APP       SIZE       DISPLAY  TITLE
            4211  Safari     1200×800        1  GitHub - shreeve/shotts…
              87  Terminal  640×480.5        2

            """)
    }

    /// For a person: a tab with the title, joined to the box, the notes under it.
    @Test func boxes() {
        let table = TextTable(title: "shotts 0.6.0", columns: [.init("ID", align: .right), .init("TITLE", flexible: true)],
                              rows: [["7", "Docs"], ["1234", "A long title that will not fit"]], notes: ["2 windows"])
        #expect(table.boxed(width: 30, color: false) == """
            ╭──────────────╮
            │ shotts 0.6.0 │
            ├──────┬───────┴─────────────╮
            │ ID   │ TITLE               │
            │    7 │ Docs                │
            │ 1234 │ A long title that … │
            ╰──────┴─────────────────────╯

              2 windows

            """)
        // A tab wider than the table widens it; an edge on a column's is a cross.
        let narrow = TextTable(title: "a", columns: [.init("A"), .init("B")], rows: [["1", "2"]])
        #expect(narrow.boxed(color: false).split(separator: "\n")[2] == "├───┼───╮")
        #expect(TextTable(title: "a much longer tab", columns: [.init("A")], rows: [["1"]]).boxed(color: false)
            .split(separator: "\n").map { TextTable.columns(String($0)) }.allSatisfy { $0 == 21 })
        // Color is on the text, never on the padding, so columns still line up.
        let colored = table.boxed(width: 30, color: true)
        #expect(colored.contains("\u{1B}[1mTITLE\u{1B}[0m               │") && colored.contains("\u{1B}[2m2 windows\u{1B}[0m"))
    }

    /// Wide characters take two columns, and are never split.
    @Test func wideCharacters() {
        #expect(TextTable.columns("日本語") == 6 && TextTable.columns("a🎉b") == 4)
        #expect(TextTable.cut("日本語のタイトル", to: 7) == "日本語…")
        let table = TextTable(columns: [.init("T"), .init("X")], rows: [["日本", "1"], ["abcd", "2"]])
        #expect(table.plain() == "T     X\n日本  1\nabcd  2\n")
    }

    @Test func files() {
        var result = ScriptResult(command: .record, state: "done", target: ScriptTargetInfo(kind: "window", id: 4211, app: "Safari", frame: [0, 0, 10, 10], scale: 2, display: 1),
                                  duration: 4.96, files: [
            ScriptFile(path: "/Users/me/Desktop/demo.mp4", format: .mp4, width: 1600, height: 1000, fps: 30, frames: 149, bytes: 1_234_567),
            ScriptFile(path: "/tmp/demo.gif", format: .gif, width: 800, height: 500, fps: 20, frames: 99, bytes: 999),
        ])
        let table = ScriptListing.files(result, home: "/Users/me")
        #expect(table.title == "window 4211 · Safari")
        #expect(table.rows == [["~/Desktop/demo.mp4", "1600×1000", "30", "149", "1.2 MB"], ["/tmp/demo.gif", "800×500", "20", "99", "999 bytes"]])
        #expect(table.notes == ["recorded 5.0s"])
        result.target = ScriptTargetInfo(kind: "region", frame: [10, 20, 300, 200], scale: 1, display: 2)
        #expect(ScriptListing.files(result, home: "/Users/me").title == "region 10,20 300×200 · display 2")
        #expect(ScriptListing.bytes(12_345_678) == "12 MB")
    }
}

@Suite struct ScriptAudioTests {
    func parse(_ args: String) throws(ScriptUsageError) -> ScriptRequest {
        try ScriptParser.parse(args.split(separator: " ").map(String.init), workingDirectory: "/w")
    }

    /// System, mic, or both, in either order; none unless asked.
    @Test func values() throws {
        #expect(ScriptRequest.audio("system") == .system)
        #expect(ScriptRequest.audio("mic") == .microphone)
        #expect(ScriptRequest.audio("both") == .both && ScriptRequest.audio("Both") == .both)
        // What 0.6.2 took still works.
        #expect(ScriptRequest.audio("system,mic") == .both && ScriptRequest.audio("MIC, system") == .both)
        #expect(ScriptRequest.audio("system,speakers") == nil && ScriptRequest.audio("all") == nil && ScriptRequest.audio("") == nil)
        #expect(try parse("record a.mp4 --window 1").audio == nil)
        #expect(try parse("record a.mp4 a.gif --window 1 --audio mic").audio == .microphone)
        // No file named makes an MP4, which can have sound.
        #expect(try parse("start --display 1 --audio system").audio == .system)
    }

    /// Sound goes only in an MP4, and only recordings have it.
    @Test func onlyInAnMP4() {
        #expect(throws: ScriptUsageError("a GIF has no sound: --audio needs an .mp4")) { try parse("record a.gif --window 1 --audio system") }
        #expect(throws: ScriptUsageError("shot takes no --fps, --duration, or --audio")) { try parse("shot a.png --window 1 --audio system") }
        #expect(throws: ScriptUsageError("stop takes only --json")) { try parse("stop --audio mic") }
        #expect(throws: ScriptUsageError("--audio takes system, mic, or both")) { try parse("record a.mp4 --window 1 --audio all") }
    }
}

@Suite struct SoundCalibrationTests {
    /// A sine of amplitude `a`, faded in and out, as the tone is played.
    func tone(_ a: Double, count: Int = 48_000) -> [Float] {
        (0..<count).map { i in
            let fade = min(1, Double(min(i, count - i)) / 4800)
            return Float(a * fade * sin(2 * .pi * 200 * Double(i) / 48_000))
        }
    }

    @Test func levelIsTheSteadyPart() {
        let a = SoundCalibration.toneAmplitude
        // A sine's root mean square is its amplitude over √2; the fades do not pull it down.
        #expect(abs((SoundCalibration.level(of: tone(a)) ?? 0) - a / 2.squareRoot()) < a * 0.01)
        #expect(SoundCalibration.level(of: []) == nil)
    }

    /// Other sound, a thousand times louder at other pitches, hardly moves the tone's level.
    @Test func otherSoundIsLeftOut() {
        let a = SoundCalibration.toneAmplitude
        let noisy = zip(tone(a), (0..<48_000).map { i in Float(a * 1000 * sin(2 * .pi * 1_000 * Double(i) / 48_000)) }).map { $0 + $1 }
        let level = SoundCalibration.level(of: noisy) ?? 0
        #expect(abs(20 * log10(level / (a / 2.squareRoot()))) < 0.5)
    }

    /// Another sound starting abruptly while the tone plays splashes across its pitch: the
    /// windows disagree, and the measurement is not believed.
    @Test func aSoundStartingSpoilsIt() {
        let a = SoundCalibration.toneAmplitude
        var spoiled = tone(a)
        for i in 20_000..<30_000 { spoiled[i] += Float(a * 3000 * sin(2 * .pi * 660 * Double(i) / 48_000 + 0.7)) }
        #expect(SoundCalibration.level(of: spoiled) == nil)
    }

    /// 11 dB lost comes back as 11 dB; none lost, or too much, changes nothing.
    @Test func gainUndoesTheLoss() throws {
        let played = try #require(SoundCalibration.level(of: tone(SoundCalibration.toneAmplitude)))
        let heard = try #require(SoundCalibration.level(of: tone(SoundCalibration.toneAmplitude * pow(10, -11.0 / 20))))
        let gain = try #require(SoundCalibration.gain(played: played, heard: heard))
        #expect(abs(20 * log10(gain) - 11) < 0.05)
        #expect(SoundCalibration.gain(played: played, heard: played) == 1)
        #expect(SoundCalibration.gain(played: played, heard: played * 1.2) == 1)
        #expect(SoundCalibration.gain(played: played, heard: played / 100) == nil)
        #expect(SoundCalibration.gain(played: played, heard: 0) == nil)
    }
}
