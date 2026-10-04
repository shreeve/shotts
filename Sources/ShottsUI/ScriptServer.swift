import Foundation
import ShottsCore

/// Where `shotts` reaches the running Shotts: a Unix socket in a folder only its user can
/// open, answering only its own user. Each connection brings one request, a line of JSON, and
/// gets result lines back until Shotts closes it; when the tool goes first, `onClose` says so.
/// Everything the handler sees happens on the main actor; the socket's waiting happens off it.
public nonisolated final class ScriptServer: @unchecked Sendable {
    public typealias Handler = @MainActor @Sendable (ScriptRequest, ScriptConnection) -> Void

    private let path: String
    private let handle: Handler
    private var listener: Int32 = -1

    public init(path: String, handle: @escaping Handler) {
        self.path = path
        self.handle = handle
    }

    public enum Failure: Error { case inUse, socket(String) }

    /// Listens, unless another Shotts already does: then this one leaves the socket to it.
    public func start() throws {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Made by someone else, or opened up since: refuse rather than listen where others could.
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR else {
            throw Failure.socket("\(folder) is not this user's own folder")
        }
        if info.st_mode & 0o077 != 0 { chmod(folder, 0o700) }
        if let fd = Self.connect(to: path) {
            close(fd)
            throw Failure.inUse
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket("socket: \(String(cString: strerror(errno)))") }
        guard var address = Self.address(path) else { close(fd); throw Failure.socket("the socket's path is too long") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw Failure.socket("bind: \(reason)")
        }
        listener = fd
        Thread.detachNewThread { [self] in accept(on: fd) }
    }

    /// Stops listening; connections already made go on.
    public func stop() {
        guard listener >= 0 else { return }
        // Shutting the socket down wakes `accept`, which then returns an error and ends.
        shutdown(listener, SHUT_RDWR)
        close(listener)
        listener = -1
        unlink(path)
    }

    private func accept(on fd: Int32) {
        while true {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    /// Reads the request, hands it on, then waits for the tool to hang up.
    private func serve(_ fd: Int32) {
        let connection = ScriptConnection(fd)
        var buffer = Data()
        var request: ScriptRequest?
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            guard request == nil else { continue }
            buffer.append(contentsOf: chunk[0..<n])
            guard let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) else {
                if buffer.count > 1 << 16 { break }
                continue
            }
            guard let decoded = try? JSONDecoder().decode(ScriptRequest.self, from: buffer[..<newline]) else {
                connection.send(.failure(.list, ScriptError(.usage, "Shotts could not read the request; is `shotts` the same version as Shotts?")))
                connection.close()
                break
            }
            request = decoded
            let handle = handle
            DispatchQueue.main.async { MainActor.assumeIsolated { handle(decoded, connection) } }
        }
        connection.hungUp()
    }

    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    /// A connection to whatever listens at `path`, or nil.
    static func connect(to path: String) -> Int32? {
        guard var address = address(path) else { return nil }
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

/// One tool's connection: results go back on it, and it says when the tool has gone.
public nonisolated final class ScriptConnection: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var open = true
    private var gone = false
    private var closeHandler: (@MainActor () -> Void)?

    init(_ fd: Int32) { self.fd = fd }

    /// Sends a result line; nothing once closed.
    public func send(_ result: ScriptResult) {
        lock.withLock {
            guard open else { return }
            let line = result.line()
            line.withUnsafeBytes { bytes in
                var sent = 0
                while sent < bytes.count {
                    let n = write(fd, bytes.baseAddress! + sent, bytes.count - sent)
                    if n <= 0 { break }
                    sent += n
                }
            }
        }
    }

    /// The last result has gone: the tool sees the end and exits.
    public func close() {
        lock.withLock {
            guard open else { return }
            open = false
            shutdown(fd, SHUT_WR)
        }
    }

    /// Whether the tool has hung up.
    public var isGone: Bool { lock.withLock { gone } }

    /// Called on the main actor when the tool hangs up first, as a Control-C does; at once if it
    /// already has.
    @MainActor public func onClose(_ handler: @escaping @MainActor () -> Void) {
        let already = lock.withLock {
            if !gone { closeHandler = handler }
            return gone
        }
        if already { handler() }
    }

    fileprivate func hungUp() {
        let (handler, wasOpen) = lock.withLock { () -> ((@MainActor () -> Void)?, Bool) in
            gone = true
            let h = closeHandler
            closeHandler = nil
            let wasOpen = open
            open = false
            return (h, wasOpen)
        }
        Darwin.close(fd)
        // A connection Shotts closed itself was finished with; only a tool leaving early counts.
        guard wasOpen, let handler else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { handler() } }
    }
}
