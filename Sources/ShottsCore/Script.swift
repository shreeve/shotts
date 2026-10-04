import CoreGraphics
import Foundation

/// The command line's language: what `shotts` asks of the running Shotts, and what it answers.
/// The `shotts` tool parses arguments into a `ScriptRequest` and sends it as one line of JSON;
/// Shotts answers with `ScriptResult` lines. Everything here is a decision, so it is here, with
/// tests: the tool and the app only move the bytes and do the capturing.
public enum ScriptCommand: String, Codable, Sendable, CaseIterable {
    case shot, record, start, stop, list
    /// What a second Control-C sends: stop a recording and keep nothing.
    case abort
}

/// A file's format, from its extension.
public enum OutputFormat: String, Codable, Sendable {
    case png, jpg, heic, mp4, gif

    public var isStill: Bool { self == .png || self == .jpg || self == .heic }

    public static func of(_ path: String) -> OutputFormat? {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": .png
        case "jpg", "jpeg": .jpg
        case "heic": .heic
        case "mp4": .mp4
        case "gif": .gif
        default: nil
        }
    }

    /// The recording format a video file is made in.
    public var recording: RecordingSettings.Format? {
        switch self {
        case .mp4: .mp4
        case .gif: .gif
        default: nil
        }
    }
}

/// What to capture: a window, a display, or an area of either. One is required: for an agent
/// the frontmost window is usually its own terminal, and the whole screen could hold anything.
public struct ScriptTarget: Codable, Equatable, Sendable {
    /// A window id, or an app name, bundle id, or title to match (`WindowMatch`).
    public var window: String?
    /// A display, 1 being the main one.
    public var display: Int?
    /// An area in points from the top left of the window or display; alone, of display 1.
    public var region: CGRect?

    public init(window: String? = nil, display: Int? = nil, region: CGRect? = nil) {
        self.window = window
        self.display = display
        self.region = region
    }

    public var isEmpty: Bool { window == nil && display == nil && region == nil }
}

public struct ScriptRequest: Codable, Equatable, Sendable {
    public var command: ScriptCommand
    /// Absolute paths; empty for the usual name in the screenshot folder.
    public var outputs: [String] = []
    public var target = ScriptTarget()
    /// Seconds before capturing, counted down in the menu bar.
    public var delay: Double = 0
    /// Seconds to record; for `start`, a cap.
    public var duration: Double?
    /// Frames a second for every video file; nil for each format's default.
    public var fps: Int?
    /// Width in pixels for every file; the height follows, and nothing is enlarged.
    public var width: Int?
    /// The sound an MP4 gets: the Mac's, the microphone's, or both mixed; nil for none, and a
    /// GIF never has any.
    public var audio: RecordingSettings.Sound?
    public var json = false

    public init(command: ScriptCommand) { self.command = command }

    /// `system`, `mic`, or both, comma-separated in either order.
    public static func audio(_ text: String) -> RecordingSettings.Sound? {
        let parts = Set(text.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        guard !parts.isEmpty, parts.isSubset(of: ["system", "mic"]) else { return nil }
        switch (parts.contains("system"), parts.contains("mic")) {
        case (true, true): return .both
        case (true, false): return .system
        default: return .microphone
        }
    }

    /// A recording started with `start` stops itself after this long, should `stop` never come.
    public static let startCap: Double = 600

    /// Each video format's frame rate when none is asked for: smooth video, a lighter GIF.
    public static func defaultFrameRate(for format: RecordingSettings.Format) -> Int { format == .gif ? 20 : 30 }

    /// The file made when none is named: a PNG from `shot`, an MP4 from a recording.
    public var defaultFormat: OutputFormat { command == .shot ? .png : .mp4 }

    /// A still's size for `--width`: narrower in proportion, never wider than it was captured.
    public static func stillSize(width: Int, height: Int, requested: Int?) -> (width: Int, height: Int) {
        guard let requested, requested < width else { return (width, height) }
        return (requested, max(1, Int((Double(height) * Double(requested) / Double(width)).rounded())))
    }
}

/// A usage mistake, with what to say.
public struct ScriptUsageError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public enum ScriptParser {
    /// What `shotts --help` prints: under 80 columns, as a terminal shows it.
    public static let help = """
        shotts: screenshots and screen recordings from the command line, by Shotts

        Usage:
          shotts shot   [file…] <target> [--delay t] [--width px] [--json]
          shotts record [file…] <target> [options] [--json]
          shotts start  [file…] <target> [options] [--json]
          shotts stop   [--json]
          shotts list   [--json]

        Commands:
          shot      Take a screenshot.
          record    Record until --duration, Control-C, `shotts stop`, or F10.
          start     Start recording and return; stops after 10m unless --duration.
          stop      Stop the recording and wait for its files.
          list      Show the windows and displays there are to capture.

        Targets (one is required):
          --window <q>       A window: its id, app, or bundle id, or part of its title.
          --display <n>      A display: 1 is the main one.
          --region x,y,w,h   Part of the window or display, in points from its top-left;
                             alone, part of the main display.

        Options:
          --delay <t>        Wait first, counting down in the menu bar.
          --duration <t>     Record this long.
          --fps <n>          Frames a second: 1, 5, 10, 20, 30, or for MP4 60.
                             Unless asked, MP4 makes 30 and GIF 20.
          --audio <a>        Sound in the MP4: system, mic, or system,mic. None
                             unless asked; a GIF never has any.
          --width <px>       Make files narrower, in proportion; never wider. A GIF
                             is the size the area has on screen unless asked.
          --json             Answer with one line of JSON.
          -h, --help         Show this.

        Files are made in the format their names end in: .png .jpg .heic from shot,
        .mp4 .gif from record and start, as many as are named. With none, a .png or
        .mp4 goes where the Screenshot app saves. Times: 5, 500ms, 1.5s, 2m, 1m30s.

        Examples:
          shotts list
          shotts shot safari.png --window Safari
          shotts shot screen.png --display 1 --delay 3
          shotts record demo.mp4 demo.gif --window 4211 --duration 10s --width 800
          shotts record talk.mp4 --display 1 --audio system,mic
          shotts start --region 0,0,800,600 && sleep 5 && shotts stop

        Turn on Allow Command-Line Capture in the Shotts menu first.

        """

    /// Said under a mistake.
    public static let helpHint = "Run 'shotts --help' to see what it takes."

    /// Whether the arguments ask for help: none at all, `help`, or -h or --help anywhere.
    public static func wantsHelp(_ arguments: [String]) -> Bool {
        arguments.isEmpty || arguments.first == "help" || arguments.contains("-h") || arguments.contains("--help")
    }

    /// The arguments after the tool's name, with relative paths taken from `workingDirectory`.
    public static func parse(_ arguments: [String], workingDirectory: String) throws(ScriptUsageError) -> ScriptRequest {
        guard let name = arguments.first else { throw ScriptUsageError("say what to do: shot, record, start, stop, or list") }
        guard let command = ScriptCommand(rawValue: name), command != .abort else {
            throw ScriptUsageError("unknown command '\(name)': use shot, record, start, stop, or list")
        }
        var request = ScriptRequest(command: command)
        var rest = arguments.dropFirst()
        func value(_ flag: String) throws(ScriptUsageError) -> String {
            guard let v = rest.popFirst() else { throw ScriptUsageError("\(flag) needs a value") }
            return v
        }
        while let argument = rest.popFirst() {
            switch argument {
            case "--json": request.json = true
            case "--window": request.target.window = try value(argument)
            case "--display":
                guard let n = Int(try value(argument)), n >= 1 else { throw ScriptUsageError("--display takes a number, 1 being the main display") }
                request.target.display = n
            case "--region":
                guard let r = region(try value(argument)) else { throw ScriptUsageError("--region takes x,y,w,h in points") }
                request.target.region = r
            case "--delay":
                guard let t = seconds(try value(argument)) else { throw ScriptUsageError("--delay takes a time: 5, 500ms, 1.5s, 2m, 1m30s") }
                request.delay = t
            case "--duration":
                guard let t = seconds(try value(argument)), t > 0 else { throw ScriptUsageError("--duration takes a time over zero: 5, 1.5s, 2m") }
                request.duration = t
            case "--fps":
                guard let n = Int(try value(argument)), n > 0 else { throw ScriptUsageError("--fps takes a whole number") }
                request.fps = n
            case "--audio":
                guard let a = ScriptRequest.audio(try value(argument)) else { throw ScriptUsageError("--audio takes system, mic, or system,mic") }
                request.audio = a
            case "--width":
                guard let n = Int(try value(argument)), n >= RecordingRule.minWidth else { throw ScriptUsageError("--width takes pixels, \(RecordingRule.minWidth) or more") }
                request.width = n
            default:
                guard !argument.hasPrefix("-") else { throw ScriptUsageError("unknown option '\(argument)'") }
                let path = (argument as NSString).isAbsolutePath ? argument : (workingDirectory as NSString).appendingPathComponent(argument)
                request.outputs.append((path as NSString).standardizingPath)
            }
        }
        try check(request)
        return request
    }

    /// What each command takes.
    static func check(_ r: ScriptRequest) throws(ScriptUsageError) {
        switch r.command {
        case .stop, .list, .abort:
            guard r.outputs.isEmpty, r.target.isEmpty, r.delay == 0, r.duration == nil, r.fps == nil, r.width == nil, r.audio == nil else {
                throw ScriptUsageError("\(r.command.rawValue) takes only --json")
            }
            return
        case .shot:
            if r.fps != nil || r.duration != nil || r.audio != nil { throw ScriptUsageError("shot takes no --fps, --duration, or --audio") }
        case .record, .start:
            // Sound goes only in an MP4: named, or the one made when none is.
            if r.audio != nil, !r.outputs.isEmpty, !r.outputs.contains(where: { OutputFormat.of($0) == .mp4 }) {
                throw ScriptUsageError("a GIF has no sound: --audio needs an .mp4")
            }
        }
        guard !r.target.isEmpty else {
            throw ScriptUsageError("say what to capture with --window, --display, or --region; `shotts list` shows what there is")
        }
        if r.target.window != nil, r.target.display != nil { throw ScriptUsageError("--window and --display: choose one") }
        for path in r.outputs {
            guard let format = OutputFormat.of(path) else {
                throw ScriptUsageError("'\((path as NSString).lastPathComponent)': unknown format; use \(r.command == .shot ? ".png, .jpg, or .heic" : ".mp4 or .gif")")
            }
            if format.isStill != (r.command == .shot) {
                throw ScriptUsageError("\(r.command.rawValue) makes \(r.command == .shot ? ".png, .jpg, or .heic" : ".mp4 or .gif") files, not .\(format.rawValue)")
            }
            if let fps = r.fps, let video = format.recording, !RecordingRule.frameRates(for: video).contains(fps) {
                throw ScriptUsageError(".\(format.rawValue) takes --fps \(RecordingRule.frameRates(for: video).map(String.init).joined(separator: ", "))")
            }
        }
    }

    /// A time: a bare number of seconds, or with units, as in 500ms, 1.5s, 2m, or 1m30s.
    public static func seconds(_ text: String) -> Double? {
        if let plain = Double(text) { return plain >= 0 && plain.isFinite ? plain : nil }
        var total = 0.0, number = "", rest = Substring(text.lowercased())
        guard !rest.isEmpty else { return nil }
        while let c = rest.first {
            if c.isNumber || c == "." {
                number.append(c)
                rest.removeFirst()
                continue
            }
            let unit: (name: String, seconds: Double)
            if rest.hasPrefix("ms") { unit = ("ms", 0.001) } else if c == "s" { unit = ("s", 1) } else if c == "m" { unit = ("m", 60) } else if c == "h" { unit = ("h", 3600) } else { return nil }
            guard let n = Double(number) else { return nil }
            total += n * unit.seconds
            number = ""
            rest.removeFirst(unit.name.count)
        }
        return number.isEmpty ? total : nil
    }

    /// x,y,w,h in points.
    static func region(_ text: String) -> CGRect? {
        let parts = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, let x = parts[0], let y = parts[1], let w = parts[2], let h = parts[3], w > 0, h > 0 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// A window as `shotts list` shows it and `--window` matches it.
public struct ScriptWindow: Codable, Equatable, Sendable {
    public var id: UInt32
    public var app: String
    public var bundle: String
    public var title: String
    /// x, y, width, height in points, from the top left of the main display.
    public var frame: [Double]
    public var display: Int

    public init(id: UInt32, app: String, bundle: String, title: String, frame: [Double], display: Int) {
        self.id = id
        self.app = app
        self.bundle = bundle
        self.title = title
        self.frame = frame
        self.display = display
    }
}

public struct ScriptDisplay: Codable, Equatable, Sendable {
    public var number: Int
    public var frame: [Double]
    public var scale: Double

    public init(number: Int, frame: [Double], scale: Double) {
        self.number = number
        self.frame = frame
        self.scale = scale
    }
}

public enum WindowMatch: Equatable, Sendable {
    case one(ScriptWindow)
    case none
    case ambiguous([ScriptWindow])

    /// The window `query` names among `windows`, listed front to back. A number is a window id.
    /// A query that is exactly an app's name or bundle id is that app's frontmost window.
    /// Otherwise it is a case-insensitive part of an app name, bundle id, or title, and must
    /// match one window: with several, the caller is told which, never given the first.
    public static func find(_ query: String, in windows: [ScriptWindow]) -> WindowMatch {
        if let id = UInt32(query) { return windows.first { $0.id == id }.map(WindowMatch.one) ?? .none }
        let q = query.lowercased()
        if let app = windows.first(where: { $0.app.lowercased() == q || $0.bundle.lowercased() == q }) { return .one(app) }
        let found = windows.filter { $0.app.lowercased().contains(q) || $0.bundle.lowercased().contains(q) || $0.title.lowercased().contains(q) }
        switch found.count {
        case 0: return .none
        case 1: return .one(found[0])
        default: return .ambiguous(found)
        }
    }
}

/// What went wrong, as a program reads it.
/// What `shotts` shows a person: the displays and windows `list` finds, the windows that match
/// too many, and the files made, as tables (`TextTable` boxes them on a terminal).
public enum ScriptListing {
    /// The displays, under a tab naming the tool, then the windows front to back.
    public static func tables(windows: [ScriptWindow], displays: [ScriptDisplay], version: String? = nil) -> [TextTable] {
        let shown = TextTable(
            title: version.map { "shotts \($0)" } ?? "shotts",
            columns: [.init("DISPLAY", tint: .accent), .init("SIZE", align: .right), .init("SCALE", align: .right), .init("AT", tint: .dim)],
            rows: displays.map { d in
                ["\(d.number)\(d.number == 1 && displays.count > 1 ? " main" : "")", size(d.frame), "\(number(d.scale))x",
                 "\(number(d.frame[0])),\(number(d.frame[1]))"]
            })
        var list = self.windows(windows, showingDisplay: displays.count > 1)
        let count = { (n: Int, one: String) in "\(n) \(one)\(n == 1 ? "" : "s")" }
        list.notes = ["\(count(displays.count, "display")) · \(count(windows.count, "window")) · capture one with --window <ID>"]
        return [shown, list]
    }

    /// Windows, as listed or as the candidates when several match.
    public static func windows(_ windows: [ScriptWindow], showingDisplay: Bool = true) -> TextTable {
        var columns: [TextTable.Column] = [.init("ID", align: .right, tint: .accent), .init("APP", tint: .bold), .init("SIZE", align: .right)]
        if showingDisplay { columns.append(.init("DISPLAY", align: .right)) }
        columns.append(.init("TITLE", flexible: true))
        return TextTable(columns: columns, rows: windows.map { w in
            var row = ["\(w.id)", cut(w.app, to: 24), size(w.frame)]
            if showingDisplay { row.append("\(w.display)") }
            row.append(w.title)
            return row
        })
    }

    /// The files a capture made, paths from `home` written with a tilde, under a tab saying
    /// what was captured.
    public static func files(_ result: ScriptResult, home: String) -> TextTable {
        let files = result.files ?? []
        let moving = files.contains { $0.fps != nil }
        var columns: [TextTable.Column] = [.init("FILE", tint: .path, flexible: true), .init("SIZE", align: .right)]
        if moving { columns += [.init("FPS", align: .right), .init("FRAMES", align: .right)] }
        columns.append(.init("BYTES", align: .right))
        let rows = files.map { f in
            var row = [tilde(f.path, home: home), "\(f.width)×\(f.height)"]
            if moving { row += [f.fps.map(String.init) ?? "", f.frames.map(String.init) ?? ""] }
            row.append(bytes(f.bytes))
            return row
        }
        var notes: [String] = []
        if let duration = result.duration { notes.append("recorded \(String(format: "%.1f", duration))s") }
        return TextTable(title: result.target.map(describe), columns: columns, rows: rows, notes: notes)
    }

    /// `window 3340 · Ghostty`, `display 1`, or `region 0,0 800×600 · display 1`.
    static func describe(_ target: ScriptTargetInfo) -> String {
        switch target.kind {
        case "window": (["window \(target.id.map(String.init) ?? "")"] + [target.app].compactMap { $0 }).joined(separator: " · ")
        case "display": "display \(target.display)"
        default: "region \(number(target.frame[0])),\(number(target.frame[1])) \(size(target.frame)) · display \(target.display)"
        }
    }

    static func tilde(_ path: String, home: String) -> String {
        guard !home.isEmpty, path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// Bytes as Finder counts them, by thousands.
    static func bytes(_ n: Int) -> String {
        let units = ["bytes", "KB", "MB", "GB"]
        var value = Double(n), unit = 0
        while value >= 1000, unit < units.count - 1 { value /= 1000; unit += 1 }
        return unit == 0 ? "\(n) bytes" : String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, units[unit])
    }

    private static func number(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
    private static func size(_ frame: [Double]) -> String { "\(number(frame[2]))×\(number(frame[3]))" }

    private static func cut(_ text: String, to length: Int) -> String {
        guard text.count > length else { return text }
        return String(text.prefix(length - 1)) + "…"
    }
}

/// What a target comes to: a window on its own, which a recording follows wherever it goes, or
/// a fixed area of one display, in points from its top-left corner.
public struct ScriptAim: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case window(UInt32)
        case area(display: Int, rect: CGRect)
    }

    public var source: Source
    /// What the answer says was captured.
    public var info: ScriptTargetInfo

    /// `--window` alone is the window; with `--region`, that part of the screen where the window
    /// is now. `--display` is the whole display, or with `--region` part of it; `--region` alone
    /// is part of the main display. A region is cut to its display, and one off it is a mistake.
    public static func of(_ target: ScriptTarget, windows: [ScriptWindow], displays: [ScriptDisplay]) -> Result<ScriptAim, ScriptError> {
        func rect(_ f: [Double]) -> CGRect { CGRect(x: f[0], y: f[1], width: f[2], height: f[3]) }
        func frame(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
        var origin = CGPoint.zero
        let display: ScriptDisplay
        if let query = target.window {
            let window: ScriptWindow
            switch WindowMatch.find(query, in: windows) {
            case let .one(w): window = w
            case .none: return .failure(ScriptError(.notFound, "no window matches '\(query)' (`shotts list` shows them)"))
            case let .ambiguous(found):
                return .failure(ScriptError(.ambiguousWindow, "\(found.count) windows match '\(query)': give its id or more of its title",
                                            candidates: found))
            }
            guard let d = displays.first(where: { $0.number == window.display }) ?? displays.first else {
                return .failure(ScriptError(.notFound, "no display"))
            }
            guard target.region != nil else {
                return .success(ScriptAim(source: .window(window.id), info: ScriptTargetInfo(
                    kind: "window", id: window.id, app: window.app, bundle: window.bundle, title: window.title, frame: window.frame,
                    scale: d.scale, display: d.number)))
            }
            display = d
            origin = CGPoint(x: window.frame[0], y: window.frame[1])
        } else {
            let number = target.display ?? 1
            guard let d = displays.first(where: { $0.number == number }) else {
                return .failure(ScriptError(.notFound, "no display \(number); there \(displays.count == 1 ? "is 1" : "are \(displays.count)")"))
            }
            display = d
            origin = CGPoint(x: d.frame[0], y: d.frame[1])
        }
        let bounds = rect(display.frame)
        let wanted = target.region.map { $0.offsetBy(dx: origin.x, dy: origin.y) } ?? bounds
        let area = wanted.intersection(bounds)
        guard !area.isNull, area.width >= 1, area.height >= 1 else {
            return .failure(ScriptError(.usage, "the region is not on display \(display.number)"))
        }
        return .success(ScriptAim(source: .area(display: display.number, rect: area.offsetBy(dx: -bounds.minX, dy: -bounds.minY)),
                                  info: ScriptTargetInfo(kind: target.region == nil ? "display" : "region", frame: frame(area),
                                                         scale: display.scale, display: display.number)))
    }
}

public enum ScriptErrorCode: String, Codable, Sendable {
    case usage, permission, notAllowed = "not_allowed", notFound = "not_found", ambiguousWindow = "ambiguous_window", busy
    case captureFailed = "capture_failed", encodeFailed = "encode_failed"

    /// The tool's exit status.
    public var exitCode: Int32 {
        switch self {
        case .usage: 2
        case .permission, .notAllowed: 3
        case .notFound, .ambiguousWindow: 4
        case .busy: 5
        case .captureFailed, .encodeFailed: 1
        }
    }
}

public struct ScriptError: Error, Codable, Equatable, Sendable {
    public var code: ScriptErrorCode
    public var message: String
    public var candidates: [ScriptWindow]?

    public init(_ code: ScriptErrorCode, _ message: String, candidates: [ScriptWindow]? = nil) {
        self.code = code
        self.message = message
        self.candidates = candidates
    }
}

/// One file made.
public struct ScriptFile: Codable, Equatable, Sendable {
    public var path: String
    public var format: OutputFormat
    public var width: Int
    public var height: Int
    public var fps: Int?
    public var frames: Int?
    public var bytes: Int

    public init(path: String, format: OutputFormat, width: Int, height: Int, fps: Int? = nil, frames: Int? = nil, bytes: Int) {
        self.path = path
        self.format = format
        self.width = width
        self.height = height
        self.fps = fps
        self.frames = frames
        self.bytes = bytes
    }
}

/// What was captured.
public struct ScriptTargetInfo: Codable, Equatable, Sendable {
    public var kind: String
    public var id: UInt32?
    public var app: String?
    public var bundle: String?
    public var title: String?
    public var frame: [Double]
    public var scale: Double
    public var display: Int

    public init(kind: String, id: UInt32? = nil, app: String? = nil, bundle: String? = nil, title: String? = nil, frame: [Double],
                scale: Double, display: Int) {
        self.kind = kind
        self.id = id
        self.app = app
        self.bundle = bundle
        self.title = title
        self.frame = frame
        self.scale = scale
        self.display = display
    }
}

/// Shotts' answer. A `record` sends one with state "recording" once it is live, then the last.
public struct ScriptResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var command: ScriptCommand
    /// "recording", "saving" (files being made, `progress` of the way through, `saving` the one
    /// being made now; sent along the way, never the answer), or "done".
    public var state: String?
    public var progress: Double?
    public var saving: String?
    public var target: ScriptTargetInfo?
    /// When capturing began, ISO 8601.
    public var started: String?
    public var duration: Double?
    public var files: [ScriptFile]?
    public var windows: [ScriptWindow]?
    public var displays: [ScriptDisplay]?
    public var error: ScriptError?

    public init(command: ScriptCommand, state: String? = nil, target: ScriptTargetInfo? = nil, started: String? = nil, duration: Double? = nil,
                files: [ScriptFile]? = nil) {
        ok = true
        self.command = command
        self.state = state
        self.target = target
        self.started = started
        self.duration = duration
        self.files = files
    }

    public static func failure(_ command: ScriptCommand, _ error: ScriptError) -> ScriptResult {
        var r = ScriptResult(command: command)
        r.ok = false
        r.error = error
        return r
    }

    /// One line of JSON, keys in a fixed order.
    public func line() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(self)) ?? Data()) + Data("\n".utf8)
    }
}

extension ScriptRequest {
    public func line() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(self)) ?? Data()) + Data("\n".utf8)
    }
}

/// Where the tool and the app meet: a socket in a folder only its user can open.
public enum ScriptSocket {
    public static func path(home: String) -> String {
        (home as NSString).appendingPathComponent("Library/Caches/com.github.shreeve.shotts/cli.sock")
    }
}
