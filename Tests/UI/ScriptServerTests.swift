import Foundation
import ShottsCore
import Testing
@testable import ShottsUI

/// `shotts` and Shotts over the socket: a request goes in as a line, results come back as
/// lines, and a tool that hangs up first is noticed. The capturing itself needs a real screen.
@MainActor @Suite(.serialized) struct ScriptServerTests {
    /// A socket path of its own, short enough for a Unix socket.
    private func socketPath() -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("st-\(UUID().uuidString.prefix(8))")
        return folder.appendingPathComponent("cli.sock").path
    }

    /// Gives up reading after five seconds, so a server that never answers fails the test rather
    /// than hanging the run; and a server gone first is an error to write to, not a signal.
    private nonisolated static func prepare(_ fd: Int32) {
        var limit = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Sends `bytes` as the tool sends a request, waits `pause` without reading, then reads
    /// every line until Shotts closes.
    private nonisolated static func exchange(_ path: String, _ bytes: Data, pause: Duration = .zero) async -> [ScriptResult] {
        await Task.detached {
            guard let fd = ScriptServer.connect(to: path) else { return [] }
            defer { close(fd) }
            Self.prepare(fd)
            _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            try? await Task.sleep(for: pause)
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while case let n = read(fd, &chunk, chunk.count), n > 0 { data.append(contentsOf: chunk[0..<n]) }
            return data.split(separator: UInt8(ascii: "\n")).compactMap { try? JSONDecoder().decode(ScriptResult.self, from: Data($0)) }
        }.value
    }

    private nonisolated static func ask(_ path: String, _ request: ScriptRequest) async -> [ScriptResult] {
        await exchange(path, request.line())
    }

    @Test func requestsAndAnswers() async throws {
        let path = socketPath()
        var received: [ScriptRequest] = []
        let server = ScriptServer(path: path) { request, connection in
            received.append(request)
            connection.send(ScriptResult(command: request.command, state: .recording))
            connection.send(ScriptResult(command: request.command, state: .done))
            connection.close()
        }
        try server.start()
        defer { server.stop() }
        // The folder and the socket are its user's alone.
        let folder = try FileManager.default.attributesOfItem(atPath: (path as NSString).deletingLastPathComponent)
        #expect((folder[.posixPermissions] as? Int) == 0o700)
        #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o600)
        // A second Shotts leaves the socket to the first. Should it take it instead, it is
        // stopped, so what follows fails rather than waiting on a server that never answers.
        let second = ScriptServer(path: path) { _, _ in }
        #expect(throws: ScriptServer.Failure.self) { try second.start() }
        second.stop()

        var request = ScriptRequest(command: .record)
        request.target.window = "Safari"
        request.outputs = ["/tmp/a.gif"]
        let answers = await Self.ask(path, request)
        #expect(received == [request])
        #expect(answers.map(\.state) == [.recording, .done])
    }

    /// A folder opened to others is closed again; one that is a link to elsewhere is refused.
    @Test func theFolderIsTheUsersAlone() throws {
        let path = socketPath()
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])
        chmod(folder, 0o777)
        let server = ScriptServer(path: path) { _, _ in }
        try server.start()
        server.stop()
        #expect((try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? Int) == 0o700)
        let linked = socketPath()
        try FileManager.default.createSymbolicLink(atPath: (linked as NSString).deletingLastPathComponent, withDestinationPath: folder)
        #expect(throws: ScriptServer.Failure.self) { try ScriptServer(path: linked) { _, _ in }.start() }
    }

    /// `stop` stops listening, and closes the socket, at once: through another name for it, a
    /// tool is refused rather than left waiting on a socket nothing answers. The next server
    /// answers every tool of its own.
    @Test func stoppingStopsListening() async throws {
        let oldPath = socketPath()
        let old = ScriptServer(path: oldPath) { _, connection in
            connection.send(ScriptResult.failure(.list, ScriptError(.busy, "old")))
            connection.close()
        }
        try old.start()
        #expect(await Self.ask(oldPath, ScriptRequest(command: .list)).map(\.error?.message) == ["old"])
        let alias = (oldPath as NSString).deletingLastPathComponent + "/alias.sock"
        #expect(rename(oldPath, alias) == 0)
        old.stop()
        var listening = true
        for _ in 0..<100 where listening {
            if let fd = ScriptServer.connect(to: alias) { close(fd); try await Task.sleep(for: .milliseconds(10)) } else { listening = false }
        }
        #expect(!listening)

        let path = socketPath()
        let new = ScriptServer(path: path) { request, connection in
            connection.send(ScriptResult.failure(request.command, ScriptError(.busy, "new")))
            connection.close()
        }
        try new.start()
        defer { new.stop() }
        var answers: [String?] = []
        for _ in 0..<8 { answers += await Self.ask(path, ScriptRequest(command: .list)).map(\.error?.message) }
        #expect(answers == Array(repeating: "new", count: 8))
    }

    /// A tool that stops reading (suspended, or reading only at the end) never holds the main
    /// actor up: sending returns at once, only the newest progress line waits, and the answer
    /// follows it once the tool reads again.
    @Test func aToolThatStopsReadingHoldsNothingUp() async throws {
        let path = socketPath()
        var sending: Duration = .zero
        let server = ScriptServer(path: path) { request, connection in
            let began = ContinuousClock.now
            var progress = ScriptResult(command: request.command, state: .saving)
            for n in 0..<2000 {
                progress.saving = "/Users/me/Desktop/" + String(repeating: "x", count: 200) + ".mp4"
                progress.progress = Double(n) / 2000
                connection.send(progress)
            }
            connection.send(ScriptResult(command: request.command, state: .done))
            connection.close()
            sending = ContinuousClock.now - began
        }
        try server.start()
        defer { server.stop() }
        let answers = await Self.exchange(path, ScriptRequest(command: .record).line(), pause: .milliseconds(500))
        #expect(sending < .milliseconds(400))
        #expect(answers.last?.state == .done)
        #expect(answers.count < 200, "\(answers.count) lines: the progress lines waiting were not cut to the newest")
        #expect(answers.dropLast().last?.progress == 1999.0 / 2000)
    }

    /// A tool that never takes its last answer is dropped once its deadline passes.
    @Test func anAnswerNotTakenIsDropped() async throws {
        let path = socketPath()
        var connection: ScriptConnection?
        let server = ScriptServer(path: path) { request, c in
            var big = ScriptResult(command: .list)
            big.windows = (0..<2000).map { ScriptWindow(id: UInt32($0), app: "App", bundle: "b", title: String(repeating: "t", count: 100), frame: [0, 0, 1, 1], display: 1) }
            c.send(big)
            c.close()
            connection = c
        }
        server.deadlines.answer = 0.2
        try server.start()
        defer { server.stop() }
        let fd = try #require(ScriptServer.connect(to: path))
        defer { close(fd) }
        Self.prepare(fd)
        let line = ScriptRequest(command: .list).line()
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        for _ in 0..<300 where connection?.isGone != true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(connection?.isGone == true)
    }

    /// A tool that connects and says nothing is dropped once its deadline passes.
    @Test func anIdleToolIsDropped() async throws {
        let path = socketPath()
        let server = ScriptServer(path: path) { _, _ in }
        server.deadlines.request = 0.2
        try server.start()
        defer { server.stop() }
        let ended = await Task.detached {
            guard let fd = ScriptServer.connect(to: path) else { return false }
            defer { close(fd) }
            Self.prepare(fd)
            var byte: UInt8 = 0
            return read(fd, &byte, 1) == 0
        }.value
        #expect(ended)
    }

    /// A request that is not one, or longer than 64 KB, is answered with what is wrong and never
    /// reaches the handler.
    @Test func unreadableRequestsAreRefused() async throws {
        let path = socketPath()
        var handled = 0
        let server = ScriptServer(path: path) { _, connection in
            handled += 1
            connection.close()
        }
        try server.start()
        defer { server.stop() }
        for bytes in [Data("{\"command\":\"frob\"}\n".utf8), Data(repeating: UInt8(ascii: "a"), count: 70_000)] {
            let answers = await Self.exchange(path, bytes)
            #expect(answers.count == 1 && answers.first?.ok == false && answers.first?.error?.code == .usage)
            // Nothing was asked that Shotts could read, so the answer names no command.
            #expect(answers.first.map { $0.command == nil } == true)
        }
        #expect(handled == 0)
    }

    /// A tool that goes first, as on Control-C, is how a recording learns to stop.
    @Test func hangingUpIsNoticed() async throws {
        let path = socketPath()
        var hungUp = false
        let server = ScriptServer(path: path) { _, connection in
            connection.send(ScriptResult(command: .record, state: .recording))
            connection.onClose { hungUp = true }
        }
        try server.start()
        defer { server.stop() }
        let fd = try #require(ScriptServer.connect(to: path))
        Self.prepare(fd)
        let line = ScriptRequest(command: .record).line()
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var byte: UInt8 = 0
        _ = await Task.detached { read(fd, &byte, 1) }.value
        close(fd)
        for _ in 0..<200 where !hungUp { try await Task.sleep(for: .milliseconds(10)) }
        #expect(hungUp)
    }

    /// Allow Command-Line Capture is what the user saved, never what Shotts was launched with:
    /// `-commandLine.allowed YES` on its command line does not turn it on.
    @Test func onlyTheSavedSwitchAllows() throws {
        let domain = "st-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        defaults.setVolatileDomain([ScriptServer.allowedKey: true], forName: UserDefaults.argumentDomain)
        #expect(defaults.bool(forKey: ScriptServer.allowedKey), "the launch argument is what `bool(forKey:)` reads")
        #expect(!ScriptServer.isAllowed(in: defaults, domain: domain))
        defaults.set(true, forKey: ScriptServer.allowedKey)
        #expect(ScriptServer.isAllowed(in: defaults, domain: domain))
        defaults.set(false, forKey: ScriptServer.allowedKey)
        #expect(!ScriptServer.isAllowed(in: defaults, domain: domain))
    }

    /// Shotts closing its side, having answered, is not the tool hanging up.
    @Test func answeringIsNotHangingUp() async throws {
        let path = socketPath()
        var hungUp = false
        let server = ScriptServer(path: path) { _, connection in
            connection.onClose { hungUp = true }
            connection.send(ScriptResult(command: .shot, state: .done))
            connection.close()
        }
        try server.start()
        defer { server.stop() }
        let answers = await Self.ask(path, ScriptRequest(command: .shot))
        #expect(answers.count == 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!hungUp)
    }
}
