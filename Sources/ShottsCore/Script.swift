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
    public var json = false

    public init(command: ScriptCommand) { self.command = command }

    /// A recording started with `start` stops itself after this long, should `stop` never come.
    public static let startCap: Double = 600

    /// Each video format's frame rate when none is asked for: smooth video, a lighter GIF.
    public static func defaultFrameRate(for format: RecordingSettings.Format) -> Int { format == .gif ? 20 : 30 }
}

/// A usage mistake, with what to say.
public struct ScriptUsageError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public enum ScriptParser {
    public static let usage = """
        usage: shotts shot   [file…] (--window <q> | --display <n> | --region x,y,w,h) [--delay t] [--width px] [--json]
               shotts record [file…] <target> [--delay t] [--duration t] [--fps n] [--width px] [--json]
               shotts start  [file…] <target> [--delay t] [--duration t] [--fps n] [--width px] [--json]
               shotts stop   [--json]
               shotts list   [--json]
        Files: .png .jpg .heic for shot; .mp4 .gif for record and start (each listed is made).
        Times: 5, 500ms, 1.5s, 2m, 1m30s. Turn on Allow Command-Line Capture in the Shotts menu first.
        """

    /// The arguments after the tool's name, with relative paths taken from `workingDirectory`.
    public static func parse(_ arguments: [String], workingDirectory: String) throws(ScriptUsageError) -> ScriptRequest {
        guard let name = arguments.first else { throw ScriptUsageError(usage) }
        guard let command = ScriptCommand(rawValue: name), command != .abort else {
            throw ScriptUsageError("unknown command '\(name)'\n\(usage)")
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
            case "--width":
                guard let n = Int(try value(argument)), n >= RecordingRule.minWidth else { throw ScriptUsageError("--width takes pixels, \(RecordingRule.minWidth) or more") }
                request.width = n
            case "-h", "--help": throw ScriptUsageError(usage)
            default:
                guard !argument.hasPrefix("-") else { throw ScriptUsageError("unknown option '\(argument)'\n\(usage)") }
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
            guard r.outputs.isEmpty, r.target.isEmpty, r.delay == 0, r.duration == nil, r.fps == nil, r.width == nil else {
                throw ScriptUsageError("\(r.command.rawValue) takes only --json")
            }
            return
        case .shot:
            if r.fps != nil || r.duration != nil { throw ScriptUsageError("shot takes neither --fps nor --duration") }
        case .record, .start:
            break
        }
        guard !r.target.isEmpty else {
            throw ScriptUsageError("say what to capture: --window, --display, or --region (`shotts list` shows windows and displays)")
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

public struct ScriptError: Codable, Equatable, Sendable {
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
    /// "recording" or "done".
    public var state: String?
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
