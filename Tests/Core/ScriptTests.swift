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
