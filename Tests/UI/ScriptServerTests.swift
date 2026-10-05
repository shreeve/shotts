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
    /// than hanging the run.
    private nonisolated static func waitAtMost5Seconds(_ fd: Int32) {
        var limit = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Sends `request` as the tool does, and reads every line until Shotts closes.
    private nonisolated static func ask(_ path: String, _ request: ScriptRequest) async -> [ScriptResult] {
        await Task.detached {
            guard let fd = ScriptServer.connect(to: path) else { return [] }
            defer { close(fd) }
            waitAtMost5Seconds(fd)
            let line = request.line()
            _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while case let n = read(fd, &chunk, chunk.count), n > 0 { data.append(contentsOf: chunk[0..<n]) }
            return data.split(separator: UInt8(ascii: "\n")).compactMap { try? JSONDecoder().decode(ScriptResult.self, from: Data($0)) }
        }.value
    }

    @Test func requestsAndAnswers() async throws {
        let path = socketPath()
        var received: [ScriptRequest] = []
        let server = ScriptServer(path: path) { request, connection in
            received.append(request)
            connection.send(ScriptResult(command: request.command, state: "recording"))
            connection.send(ScriptResult(command: request.command, state: "done"))
            connection.close()
        }
        try server.start()
        defer { server.stop() }
        // The folder and the socket are its user's alone.
        let folder = try FileManager.default.attributesOfItem(atPath: (path as NSString).deletingLastPathComponent)
        #expect((folder[.posixPermissions] as? Int) == 0o700)
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
        #expect(answers.map(\.state) == ["recording", "done"])
    }

    /// A server stopped while its thread is between connections must not come back and take the
    /// next server's: the closed socket's number goes straight to the next socket opened, and the
    /// old thread, waiting again, would answer the new server's tools with the old handler. One
    /// that never closes leaves a tool waiting forever, as once hung the whole test run.
    @Test func aStoppedServerTakesNothingFromTheNext() async throws {
        let oldPath = socketPath()
        let old = ScriptServer(path: oldPath) { _, connection in
            connection.send(ScriptResult(command: .list, state: "old"))
            connection.close()
        }
        old.afterAccept = { usleep(300_000) }
        try old.start()
        let first = try #require(ScriptServer.connect(to: oldPath))
        defer { close(first) }
        // The old server's thread has taken that connection and is between connections; stop it there.
        try await Task.sleep(for: .milliseconds(100))
        old.stop()
        let path = socketPath()
        let new = ScriptServer(path: path) { request, connection in
            connection.send(ScriptResult(command: request.command, state: "new"))
            connection.close()
        }
        try new.start()
        defer { new.stop() }
        // Past the old thread's pause, every tool is answered by the new server.
        try await Task.sleep(for: .milliseconds(400))
        var states: [String?] = []
        for _ in 0..<8 { states += await Self.ask(path, ScriptRequest(command: .list)).map(\.state) }
        #expect(states == Array(repeating: "new", count: 8))
    }

    /// A tool that goes first, as on Control-C, is how a recording learns to stop.
    @Test func hangingUpIsNoticed() async throws {
        let path = socketPath()
        var hungUp = false
        let server = ScriptServer(path: path) { _, connection in
            connection.send(ScriptResult(command: .record, state: "recording"))
            connection.onClose { hungUp = true }
        }
        try server.start()
        defer { server.stop() }
        let fd = try #require(ScriptServer.connect(to: path))
        Self.waitAtMost5Seconds(fd)
        let line = ScriptRequest(command: .record).line()
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var byte: UInt8 = 0
        _ = await Task.detached { read(fd, &byte, 1) }.value
        close(fd)
        for _ in 0..<200 where !hungUp { try await Task.sleep(for: .milliseconds(10)) }
        #expect(hungUp)
    }

    /// Shotts closing its side, having answered, is not the tool hanging up.
    @Test func answeringIsNotHangingUp() async throws {
        let path = socketPath()
        var hungUp = false
        let server = ScriptServer(path: path) { _, connection in
            connection.onClose { hungUp = true }
            connection.send(ScriptResult(command: .shot, state: "done"))
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
