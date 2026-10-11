import Foundation
import ShottsCore

/// Where `shotts` reaches the running Shotts: a Unix socket in a folder only its user can
/// open, answering only its own user. Each connection brings one request, a line of JSON, and
/// gets result lines back until Shotts closes it; when the tool goes first, `onClose` says so.
/// Everything the handler sees happens on the main actor; the socket's waiting happens on
/// Dispatch queues, so a tool that is slow, or stops reading, never holds the main actor up.
public nonisolated final class ScriptServer: @unchecked Sendable {
    public typealias Handler = @MainActor @Sendable (ScriptRequest, ScriptConnection) -> Void

    private let path: String
    private let handle: Handler
    private var listening: DispatchSourceRead?
    /// Seconds a tool has to send its request, and to take Shotts' last answer once it is sent;
    /// past either, its connection is dropped.
    var deadlines = ScriptConnection.Deadlines(request: 10, answer: 5)

    public init(path: String, handle: @escaping Handler) {
        self.path = path
        self.handle = handle
    }

    public enum Failure: Error { case inUse, socket(String) }

    /// Where Allow Command-Line Capture is kept.
    public static let allowedKey = "commandLine.allowed"

    /// Allow Command-Line Capture, as the user left it in `domain`, the app's own saved settings,
    /// and nowhere else: `bool(forKey:)` also reads the arguments a process was launched with, so
    /// `open -a Shotts --args -commandLine.allowed YES` would turn it on without the user.
    public static func isAllowed(in defaults: UserDefaults, domain: String) -> Bool {
        defaults.persistentDomain(forName: domain)?[allowedKey] as? Bool ?? false
    }

    /// Listens, unless another Shotts already does: then this one leaves the socket to it.
    public func start() throws {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Made by someone else (or a link to elsewhere): refuse rather than listen where others
        // could. Opened up since: closed again.
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR else {
            throw Failure.socket("\(folder) is not this user's own folder")
        }
        if info.st_mode & 0o077 != 0, chmod(folder, 0o700) != 0 { throw Failure.socket("\(folder) could not be closed to others") }
        if let fd = Self.connect(to: path) {
            close(fd)
            throw Failure.inUse
        }
        unlink(path)
        guard var address = ScriptSocket.address(path) else { throw Failure.socket("the socket's path is too long") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket("socket: \(String(cString: strerror(errno)))") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0, listen(fd, 8) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw Failure.socket("bind: \(reason)")
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "com.github.shreeve.shotts.script"))
        let (handle, deadlines) = (handle, deadlines)
        source.setEventHandler {
            // Every connection waiting; one given up before it was taken is passed over.
            while case let client = accept(fd, nil, nil), client >= 0 || errno == EINTR || errno == ECONNABORTED {
                guard client >= 0 else { continue }
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                    close(client)
                    continue
                }
                ScriptConnection(client, deadlines: deadlines).begin(handle)
            }
        }
        // Closed only once the source is done with it, so nothing ever waits on a number that
        // has gone to another socket.
        source.setCancelHandler { close(fd) }
        source.resume()
        listening = source
    }

    /// Stops listening, at once, and removes the socket; connections already made go on.
    public func stop() {
        guard let listening else { return }
        listening.cancel()
        self.listening = nil
        unlink(path)
    }

    /// A connection to whatever listens at `path`, or nil.
    static func connect(to path: String) -> Int32? {
        guard var address = ScriptSocket.address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected == 0 { return fd }
        close(fd)
        return nil
    }
}

/// One tool's connection. Its reading and writing happen on a queue of its own and never wait:
/// what Shotts sends is kept until the tool can take it, and of the progress lines kept only the
/// newest, since a tool that has stopped reading needs no more than that.
public nonisolated final class ScriptConnection: @unchecked Sendable {
    public struct Deadlines: Sendable {
        var request: Double
        var answer: Double
    }

    private let fd: Int32
    private let deadlines: Deadlines
    private let queue = DispatchQueue(label: "com.github.shreeve.shotts.script.connection")
    /// Entered by each source on the socket and left as it is cancelled: the socket is closed
    /// once the last is done with it.
    private let sources = DispatchGroup()

    // Everything below is used on `queue` alone.
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var received = Data()
    private var asked = false
    private var outgoing: [(line: Data, isProgress: Bool)] = []
    /// Shotts has sent its last.
    private var closing = false
    private var ended = false
    private var hungUp = false
    private var closeHandler: (@MainActor () -> Void)?

    init(_ fd: Int32, deadlines: Deadlines) {
        self.fd = fd
        self.deadlines = deadlines
    }

    /// Reads the request, and hands it to `handle` on the main actor.
    fileprivate func begin(_ handle: @escaping ScriptServer.Handler) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [self] in read(handle) }
        watch(reader)
        self.reader = reader
        reader.resume()
        queue.asyncAfter(deadline: .now() + deadlines.request) { [self] in if !asked { end() } }
    }

    /// Sends a result line; nothing once closed.
    public func send(_ result: ScriptResult) {
        let line = result.line(), isProgress = result.state == .saving
        queue.async { [self] in
            guard !ended, !closing else { return }
            if isProgress { outgoing.removeAll(where: \.isProgress) }
            outgoing.append((line, isProgress))
            flush()
        }
    }

    /// The last result has been sent: once the tool has it, it sees the end and exits.
    public func close() {
        queue.async { [self] in finish() }
    }

    /// Whether the connection is over, the tool gone.
    public var isGone: Bool { queue.sync { ended } }

    /// Called on the main actor when the tool hangs up first, as a Control-C does; at once if it
    /// already has.
    @MainActor public func onClose(_ handler: @escaping @MainActor () -> Void) {
        let already = queue.sync {
            if !ended { closeHandler = handler }
            return hungUp
        }
        if already { handler() }
    }

    private func read(_ handle: @escaping ScriptServer.Handler) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !ended {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN { return }
            // The end of what the tool sends, or an error: either way it has gone.
            guard n > 0 else { return end(hangingUp: true) }
            // One request a connection; anything after it is not read.
            guard !asked else { continue }
            received.append(contentsOf: chunk[..<n])
            if let newline = received.firstIndex(of: UInt8(ascii: "\n")) {
                asked = true
                guard let request = try? JSONDecoder().decode(ScriptRequest.self, from: received[..<newline]) else {
                    return refuse("Shotts could not read the request; is `shotts` the same version as Shotts?")
                }
                received = Data()
                DispatchQueue.main.async { MainActor.assumeIsolated { handle(request, self) } }
            } else if received.count > 1 << 16 {
                asked = true
                return refuse("the request is longer than Shotts reads")
            }
        }
    }

    private func refuse(_ message: String) {
        received = Data()
        outgoing.append((ScriptResult.failure(nil, ScriptError(.usage, message)).line(), false))
        finish()
    }

    private func finish() {
        guard !ended, !closing else { return }
        closing = true
        flush()
        if !ended { queue.asyncAfter(deadline: .now() + deadlines.answer) { [self] in end() } }
    }

    /// Writes what the socket takes now, and waits for room for the rest.
    private func flush() {
        while let line = outgoing.first?.line {
            let n = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n == line.count {
                outgoing.removeFirst()
            } else if n > 0 {
                // Begun, so sent whole even if a newer progress line comes.
                outgoing[0] = (line.dropFirst(n), false)
            } else if n < 0, errno == EINTR {
                continue
            } else if n < 0, errno == EAGAIN {
                return waitForRoom()
            } else {
                return end(hangingUp: true)
            }
        }
        if closing { end() }
    }

    private func waitForRoom() {
        guard writer == nil else { return }
        let writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        writer.setEventHandler { [self] in
            self.writer?.cancel()
            self.writer = nil
            flush()
        }
        watch(writer)
        self.writer = writer
        writer.resume()
    }

    private func watch(_ source: any DispatchSourceProtocol) {
        sources.enter()
        source.setCancelHandler { [sources] in sources.leave() }
    }

    /// The connection is over: Shotts has sent its last and the tool has it, a deadline has
    /// passed, or the tool is gone (`hangingUp`). Only a tool going before Shotts has sent its
    /// last is hanging up.
    private func end(hangingUp: Bool = false) {
        guard !ended else { return }
        ended = true
        reader?.cancel()
        writer?.cancel()
        (reader, writer, outgoing) = (nil, nil, [])
        sources.notify(queue: queue) { [fd] in Darwin.close(fd) }
        if hangingUp, !closing {
            hungUp = true
            if let handler = closeHandler { DispatchQueue.main.async { MainActor.assumeIsolated { handler() } } }
        }
        closeHandler = nil
    }
}
