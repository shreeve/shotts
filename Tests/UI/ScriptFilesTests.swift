import Foundation
import ImageIO
import ShottsCore
import Testing
@testable import ShottsUI

/// Where `shotts`' files go and how they get there: made in a folder of their own beside their
/// place, then moved in, never over a file Shotts named itself, and never losing one the user
/// named to a request given up partway.
@MainActor @Suite struct ScriptFilesTests {
    /// A folder of its own for each test.
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func contents(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Makes `output` with `text` as its contents.
    private func make(_ output: ScriptFiles.Output, _ text: String) async throws -> ScriptFiles.Made {
        try await ScriptFiles.make(output) { url in
            try Data(text.utf8).write(to: url, options: .withoutOverwriting)
            return (1, 1, nil)
        }
    }

    /// With none named, one file in the screenshot folder, named as Shotts names its exports,
    /// which never replaces anything; those named are each made, and replace what is there.
    @Test func outputs() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let here = URL(fileURLWithPath: "/somewhere", isDirectory: true)
        let still = ScriptFiles.outputs(for: ScriptRequest(command: .shot), date: date, folder: here)
        #expect(still == [.init(path: "/somewhere/" + Export.suggestedName(date: date, prefix: "Shotts", fileExtension: "png"), format: .png, replaces: false)])
        let moving = ScriptFiles.outputs(for: ScriptRequest(command: .start), date: date, folder: here)
        #expect(moving.map(\.path) == ["/somewhere/" + Export.suggestedName(date: date, prefix: "Shotts Recording", fileExtension: "mp4")])
        var named = ScriptRequest(command: .record)
        named.outputs = ["/a/b.gif", "/a/c.MP4"]
        #expect(ScriptFiles.outputs(for: named, folder: here) == [.init(path: "/a/b.gif", format: .gif, replaces: true),
                                                                .init(path: "/a/c.MP4", format: .mp4, replaces: true)])
        var folder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: ScriptFiles.screenshotFolder().path, isDirectory: &folder) == folder.boolValue)
    }

    /// A file is made in a new folder beside its place, only the user's and named at random, and
    /// nothing is at the place until it is put there; the folder goes with it.
    @Test func madeBesideThenPlaced() async throws {
        let dir = try folder()
        let output = ScriptFiles.Output(path: dir.appendingPathComponent("a.png").path, format: .png, replaces: true)
        let first = try await make(output, "one")
        let second = try await make(output, "two")
        #expect(first.partial.deletingLastPathComponent() != second.partial.deletingLastPathComponent())
        #expect(first.partial.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        let mode = try FileManager.default.attributesOfItem(atPath: first.partial.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let files = try ScriptFiles.place([first])
        ScriptFiles.discard([second])
        #expect(files.map(\.path) == [output.path] && files.first?.bytes == 3 && contents(output.path) == "one")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["a.png"])
    }

    /// A name Shotts chose never replaces a file: the next takes a number, as in the Finder.
    @Test func defaultNamesNeverReplace() async throws {
        let dir = try folder()
        let output = ScriptFiles.Output(path: dir.appendingPathComponent("Shotts at 1.png").path, format: .png, replaces: false)
        var placed: [String] = []
        for text in ["one", "two", "three"] { placed += try ScriptFiles.place([try await make(output, text)]).map(\.path) }
        #expect(placed == ["Shotts at 1.png", "Shotts at 1 2.png", "Shotts at 1 3.png"].map { dir.appendingPathComponent($0).path })
        #expect(placed.map(contents) == ["one", "two", "three"])
    }

    /// A file the user named replaces what is there; a link there is replaced, never followed.
    @Test func namedFilesReplace() async throws {
        let dir = try folder()
        let path = dir.appendingPathComponent("a.png").path
        let victim = dir.appendingPathComponent("victim").path
        try Data("old".utf8).write(to: URL(fileURLWithPath: victim))
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: victim)
        _ = try ScriptFiles.place([try await make(.init(path: path, format: .png, replaces: true), "new")])
        #expect(contents(path) == "new" && contents(victim) == "old")
        // Nor does a name Shotts chose follow one.
        let other = dir.appendingPathComponent("b.png").path
        try FileManager.default.createSymbolicLink(atPath: other, withDestinationPath: victim)
        let placed = try ScriptFiles.place([try await make(.init(path: other, format: .png, replaces: false), "new")])
        #expect(placed.map(\.path) == [dir.appendingPathComponent("b 2.png").path] && contents(victim) == "old")
    }

    /// Given up before it is placed (`abort`), a file made leaves the one the user named as it was.
    @Test func discardingLeavesTheOldFile() async throws {
        let dir = try folder()
        let path = dir.appendingPathComponent("a.mp4").path
        try Data("old".utf8).write(to: URL(fileURLWithPath: path))
        let made = try await make(.init(path: path, format: .mp4, replaces: true), "new")
        ScriptFiles.discard([made])
        #expect(contents(path) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["a.mp4"])
    }

    /// A file that cannot be made leaves nothing, and says its path once.
    @Test func failuresLeaveNothing() async throws {
        let dir = try folder()
        let path = dir.appendingPathComponent("a.gif").path
        struct Broken: LocalizedError { var errorDescription: String? { "It broke." } }
        await #expect(throws: ScriptFiles.Failure("\(path): It broke.")) {
            _ = try await ScriptFiles.make(.init(path: path, format: .gif, replaces: true)) { _ in throw Broken() }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        let nowhere = dir.appendingPathComponent("missing/a.gif").path
        await #expect(throws: ScriptFiles.Failure("\(nowhere): No such file or directory")) {
            _ = try await make(.init(path: nowhere, format: .gif, replaces: true), "x")
        }
    }

    /// `--width` makes a still narrower, its resolution down with it, so it keeps its size in points.
    @Test func stillsAtAWidth() async throws {
        let dir = try folder()
        let path = dir.appendingPathComponent("a.png").path
        let made = try await ScriptFiles.make(.init(path: path, format: .png, replaces: true)) { url in
            try ScriptFiles.writeStill(blankImage(400, 200), scale: 2, width: 100, format: .png, to: url)
        }
        let file = try #require(try ScriptFiles.place([made]).first)
        #expect(file.width == 100 && file.height == 50 && file.format == .png)
        let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 100 && properties[kCGImagePropertyDPIWidth] as? Double == 36)
    }
}
