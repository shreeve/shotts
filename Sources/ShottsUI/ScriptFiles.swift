import AppKit
import ShottsCore
import UniformTypeIdentifiers

/// The files `shotts` asks for: where they go when none are named, and how each is made. A file
/// is written in a folder of its own beside its place, new, only the user's, and named at
/// random, so nothing can be planted in its way; it is moved into place once every file asked
/// for is made, so it is never seen half made, and a file the user named is never lost to a
/// request given up partway.
public enum ScriptFiles {
    /// A file to make: where, in what format, and whether it replaces what is there, as a path
    /// the user named does. A name Shotts chose never replaces anything: a number goes after it.
    public struct Output: Equatable, Sendable {
        public var path: String
        public var format: OutputFormat
        public var replaces: Bool
    }

    /// A file made beside its place, waiting to be put there.
    public struct Made: Sendable {
        var output: Output
        var partial: URL
        var width: Int
        var height: Int
        var fps: Int?
        var frames: Int?
    }

    /// What went wrong with a file, its path said once.
    public struct Failure: LocalizedError, Equatable {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Where the Screenshot app saves (System Settings, or the Screenshot app's Options), else
    /// the Desktop.
    public static func screenshotFolder() -> URL {
        if let saved = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let path = (saved as NSString).expandingTildeInPath
            var folder: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &folder), folder.boolValue { return URL(fileURLWithPath: path) }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// The files to make: those named, else one in `folder` named as Shotts names it.
    public static func outputs(for request: ScriptRequest, date: Date = .now, folder: URL = screenshotFolder()) -> [Output] {
        guard request.outputs.isEmpty else {
            return request.outputs.compactMap { path in OutputFormat.of(path).map { Output(path: path, format: $0, replaces: true) } }
        }
        let format = request.defaultFormat
        let name = Export.suggestedName(date: date, prefix: format.isStill ? "Shotts" : "Shotts Recording", fileExtension: format.rawValue)
        return [Output(path: folder.appendingPathComponent(name).path, format: format, replaces: false)]
    }

    /// Makes `output` with `write`, which writes the file at the URL it is given and says its
    /// size, and its frames if it moves. On any error nothing is left behind.
    public static func make(_ output: Output, fps: Int? = nil,
                            write: (URL) async throws -> (width: Int, height: Int, frames: Int?)) async throws(Failure) -> Made {
        var partial: URL?
        do {
            let url = try folder(beside: output.path).appendingPathComponent((output.path as NSString).lastPathComponent)
            partial = url
            let written = try await write(url)
            return Made(output: output, partial: url, width: written.width, height: written.height, fps: fps, frames: written.frames)
        } catch {
            if let partial { discard(partial) }
            throw Failure("\(output.path): \(error.localizedDescription)")
        }
    }

    /// A new folder on `path`'s volume that only this user can open, named at random: macOS's own
    /// for replacing an item there, in the user's private temporary folder, which it clears, so a
    /// Shotts stopped mid-export leaves nothing beside the file; failing that, one beside it.
    static func folder(beside path: String) throws(Failure) -> URL {
        let parent = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true)
        var isFolder: ObjCBool = false
        // A place that is not there fails here, before anything is made, as the folder beside it does.
        if FileManager.default.fileExists(atPath: parent.path, isDirectory: &isFolder), isFolder.boolValue,
           let folder = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: parent, create: true) {
            return folder
        }
        var template = Array((parent.path as NSString).appendingPathComponent(".shotts-XXXXXXXX").utf8CString)
        guard let made = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress).map { String(cString: $0) } }) else {
            throw Failure(String(cString: strerror(errno)))
        }
        return URL(fileURLWithPath: made, isDirectory: true)
    }

    /// Puts each file made in its place, in order, and says what it is. After a failure, those
    /// not yet placed are removed.
    public static func place(_ made: [Made]) throws(Failure) -> [ScriptFile] {
        var files: [ScriptFile] = []
        defer { discard(made.dropFirst(files.count)) }
        for file in made {
            let path = try place(file.partial, at: file.output)
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
            files.append(ScriptFile(path: path, format: file.output.format, width: file.width, height: file.height, fps: file.fps,
                                    frames: file.frames, bytes: bytes))
        }
        return files
    }

    /// Moves `partial` to `output`'s path, over what is there if it replaces; else to the first
    /// free name, as the Finder numbers them. Returns the path it went to.
    private static func place(_ partial: URL, at output: Output) throws(Failure) -> String {
        defer { discard(partial) }
        /// 0 once moved, else why not.
        func move(to path: String) -> Int32 {
            if output.replaces { return rename(partial.path, path) == 0 ? 0 : errno }
            if renamex_np(partial.path, path, UInt32(RENAME_EXCL)) == 0 { return 0 }
            // A volume that cannot refuse to replace: looked at first instead.
            guard errno == ENOTSUP else { return errno }
            if FileManager.default.fileExists(atPath: path) { return EEXIST }
            return rename(partial.path, path) == 0 ? 0 : errno
        }
        var path = output.path, number = 1
        while case let error = move(to: path), error != 0 {
            guard error == EEXIST, !output.replaces else { throw Failure("\(path): \(String(cString: strerror(error)))") }
            number += 1
            path = ScriptFile.numbered(output.path, number)
        }
        return path
    }

    /// Removes files made and not placed.
    public static func discard(_ made: some Sequence<Made>) {
        for file in made { discard(file.partial) }
    }

    /// Removes a file being made, and the folder it was made in.
    static func discard(_ partial: URL) {
        try? FileManager.default.removeItem(at: partial.deletingLastPathComponent())
    }

    /// Writes a still to `url` as its format says, `width` pixels wide at most, marked with
    /// its resolution as every Shotts export is.
    public static func writeStill(_ image: CGImage, scale: Double, width: Int?, format: OutputFormat,
                                  to url: URL) throws -> (width: Int, height: Int, frames: Int?) {
        let size = ScriptRequest.stillSize(width: image.width, height: image.height, requested: width)
        var picture = image
        if size.width != image.width {
            guard let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw Failure("The picture could not be scaled.")
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            guard let scaled = context.makeImage() else { throw Failure("The picture could not be scaled.") }
            picture = scaled
        }
        let type: UTType = switch format {
        case .jpg: .jpeg
        case .heic: .heic
        default: .png
        }
        // Scaled down, the picture keeps its size in points: its resolution goes down with it.
        let resolution = scale * Double(size.width) / Double(image.width)
        guard let data = Export.encode(picture, scale: resolution, as: type) else {
            throw Failure("The picture could not be made into a .\(format.rawValue) file.")
        }
        try data.write(to: url, options: .withoutOverwriting)
        return (size.width, size.height, nil)
    }
}
