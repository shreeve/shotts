import Darwin
import Foundation
import ShottsCore

// `shotts`: the command line for the running Shotts. It captures nothing itself: it sends the
// request to Shotts over a socket only its user can reach, and Shotts, which holds the Screen
// Recording permission, does the capturing and the files. Shotts answers only while Allow
// Command-Line Capture is on in its menu; when it is not running, this starts it in the
// background.

let arguments = Array(CommandLine.arguments.dropFirst())
let wantsJSON = arguments.contains("--json")

/// Where output goes: a terminal gets boxes and, unless NO_COLOR says otherwise, color; a pipe
/// or a file gets plain text for scripts.
struct Terminal {
    let fd: Int32
    var isTerminal: Bool { isatty(fd) != 0 }
    var hasColor: Bool {
        let env = ProcessInfo.processInfo.environment
        return isTerminal && env["NO_COLOR"] == nil && env["TERM"] != "dumb"
    }

    /// Its width in columns, when it is a terminal.
    var width: Int? {
        var size = winsize()
        guard isTerminal, ioctl(fd, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return nil }
        return Int(size.ws_col)
    }

    var handle: FileHandle { fd == STDERR_FILENO ? .standardError : .standardOutput }

    func write(_ text: String) { handle.write(Data(text.utf8)) }

    func write(_ tables: [TextTable]) {
        write(tables.map { isTerminal ? $0.boxed(width: width, color: hasColor) : $0.plain(width: width) }.joined(separator: "\n"))
    }

    /// `text` in an ANSI style, if this terminal shows color.
    func styled(_ text: String, _ code: String) -> String { hasColor ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
}

let stdout = Terminal(fd: STDOUT_FILENO), stderr = Terminal(fd: STDERR_FILENO)

/// The version of the Shotts this tool is inside (Contents/Helpers/shotts, beside
/// Contents/Info.plist), wherever it is linked from.
let version: String? = {
    // Where this executable really is: run by name from the PATH, the first argument is only
    // "shotts", and Homebrew's or the menu's link stands in front of it.
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var executable = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&executable, &size) == 0, let path = realpath(executable, nil) else { return nil }
    defer { free(path) }
    let plist = URL(fileURLWithPath: String(cString: path)).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Info.plist")
    return (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String)
}()

/// Prints the failure as the request asked (JSON on stdout, a line on stderr, and the windows
/// that matched or how to get help) and exits with its code.
func fail(_ command: ScriptCommand, _ error: ScriptError) -> Never {
    if wantsJSON { FileHandle.standardOutput.write(ScriptResult.failure(command, error).line()) }
    stderr.write(stderr.styled("shotts:", "1;31") + " \(error.message)\n")
    if let candidates = error.candidates, !candidates.isEmpty {
        stderr.write("\n")
        stderr.write([ScriptListing.windows(candidates, showingDisplay: Set(candidates.map(\.display)).count > 1)])
    } else if error.code == .usage {
        stderr.write(stderr.styled(ScriptParser.helpHint, "2") + "\n")
    }
    exit(error.code.exitCode)
}

if arguments == ["--version"] || arguments == ["-v"] {
    stdout.write("shotts \(version ?? "(not inside Shotts)")\n")
    exit(0)
}

if ScriptParser.wantsHelp(arguments) {
    // Asked for, help is the answer; with nothing asked, it is a mistake, and says so by its status.
    let asked = !arguments.isEmpty
    let out = asked ? stdout : stderr
    // Headings bold: the lines that start at the margin and end in a colon.
    let help = ScriptParser.help.split(separator: "\n", omittingEmptySubsequences: false).map { line in
        !line.hasPrefix(" ") && line.hasSuffix(":") ? out.styled(String(line), "1") : String(line)
    }.joined(separator: "\n")
    out.write(help)
    exit(asked ? 0 : ScriptErrorCode.usage.exitCode)
}

let request: ScriptRequest
do {
    request = try ScriptParser.parse(arguments, workingDirectory: FileManager.default.currentDirectoryPath)
} catch {
    fail(ScriptCommand(rawValue: arguments.first ?? "") ?? .list, ScriptError(.usage, error.message))
}

let socketPath = ScriptSocket.path(home: NSHomeDirectory())

/// A connection to Shotts, or nil when nothing listens.
func connectOnce() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        socketPath.utf8CString.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buffer.count - 1))) }
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if connected == 0 { return fd }
    close(fd)
    return nil
}

/// Connects, starting Shotts in the background first if need be.
func connect(_ command: ScriptCommand) -> Int32 {
    if let fd = connectOnce() { return fd }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", "-b", "com.github.shreeve.shotts"]
    try? open.run()
    open.waitUntilExit()
    guard open.terminationStatus == 0 else { fail(command, ScriptError(.captureFailed, "Shotts is not installed")) }
    for _ in 0..<100 {
        if let fd = connectOnce() { return fd }
        usleep(100_000)
    }
    // A Shotts that takes no requests still answers, to say so: one that never answers is older.
    fail(command, ScriptError(.notAllowed, "Shotts did not answer: update it (Check for Updates… in its menu) and try again"))
}

func send(_ request: ScriptRequest, to fd: Int32) {
    let line = request.line()
    _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
}

/// The next line from Shotts; nil when it hangs up.
func readLine(_ fd: Int32, _ buffer: inout Data) -> Data? {
    while true {
        if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            return Data(line)
        }
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &chunk, chunk.count)
        guard n > 0 else { return nil }
        buffer.append(contentsOf: chunk[0..<n])
    }
}

/// The answer, printed as asked: JSON, or absolute paths one a line (windows and displays for
/// `list`).
func finish(_ result: ScriptResult, line: Data) -> Never {
    guard result.ok else { fail(result.command, result.error ?? ScriptError(.captureFailed, "Shotts could not do it")) }
    if request.json {
        FileHandle.standardOutput.write(line + Data("\n".utf8))
    } else if result.command == .list {
        stdout.write(ScriptListing.tables(windows: result.windows ?? [], displays: result.displays ?? [], version: version))
    } else if let files = result.files, !files.isEmpty {
        // A person sees what was made; a script gets the paths, one a line.
        if stdout.isTerminal {
            stdout.write([ScriptListing.files(result, home: NSHomeDirectory())])
        } else {
            stdout.write(files.map { $0.path + "\n" }.joined())
        }
    } else if result.command == .start, stdout.isTerminal {
        stdout.write(stdout.styled("●", "31") + " recording" + stdout.styled(" · `shotts stop` ends it and makes the files", "2") + "\n")
    }
    exit(0)
}

// Control-C during `record` stops it and keeps the files; a second one keeps nothing.
var interrupts = 0
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let interruptions = [SIGINT, SIGTERM].map { DispatchSource.makeSignalSource(signal: $0, queue: .global()) }
for source in interruptions {
    source.setEventHandler {
        interrupts += 1
        guard request.command == .record, let fd = connectOnce() else { exit(130) }
        send(ScriptRequest(command: interrupts == 1 ? .stop : .abort), to: fd)
        if interrupts > 1 { exit(130) }
    }
    source.resume()
}

let fd = connect(request.command)
send(request, to: fd)
Thread.detachNewThread {
    var buffer = Data()
    while let line = readLine(fd, &buffer) {
        guard let result = try? JSONDecoder().decode(ScriptResult.self, from: line) else { continue }
        // A recording under way: say so, and wait for the end.
        if request.command == .record, result.ok, result.state == "recording" {
            stderr.write(stderr.isTerminal
                ? stderr.styled("●", "31") + " recording" + stderr.styled(" · Control-C or `shotts stop` ends it", "2") + "\n"
                : "recording\n")
            continue
        }
        finish(result, line: line)
    }
    fail(request.command, ScriptError(.captureFailed, "Shotts stopped answering"))
}
dispatchMain()
