import AppKit
import ShottsCore
import UniformTypeIdentifiers

/// The files `shotts` asks for: where they go when none are named, and how each is put in
/// place, written beside it under a hidden name and renamed over whatever was there, so a file
/// is never seen half made.
public enum ScriptFiles {
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

    /// The files to make: those named, else one in the screenshot folder named as Shotts names it.
    public static func outputs(for request: ScriptRequest, date: Date = .now) -> [String] {
        guard request.outputs.isEmpty else { return request.outputs }
        let format = request.defaultFormat
        let prefix = format.isStill ? "Shotts" : "Shotts Recording"
        return [screenshotFolder().appendingPathComponent(Export.suggestedName(date: date, prefix: prefix, fileExtension: format.rawValue)).path]
    }

    /// The hidden name a file is made under, beside where it goes.
    public static func partial(for path: String) -> URL {
        let url = URL(fileURLWithPath: path)
        return url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid()).partial")
    }

    /// Moves the finished file over `path`, and says what it is.
    public static func place(_ partial: URL, at path: String, format: OutputFormat, width: Int, height: Int, fps: Int? = nil,
                             frames: Int? = nil) throws -> ScriptFile {
        guard rename(partial.path, path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: partial)
            throw Failure.notPlaced("\(path): \(reason)")
        }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
        return ScriptFile(path: path, format: format, width: width, height: height, fps: fps, frames: frames, bytes: bytes)
    }

    public enum Failure: LocalizedError {
        case notPlaced(String)
        case notEncoded(String)

        public var errorDescription: String? {
            switch self {
            case let .notPlaced(m), let .notEncoded(m): m
            }
        }
    }

    /// Writes a still to `path` as its format says, `width` pixels wide at most, marked with
    /// its resolution as every Shotts export is.
    public static func writeStill(_ image: CGImage, scale: Double, width: Int?, format: OutputFormat, to path: String) throws -> ScriptFile {
        let size = ScriptRequest.stillSize(width: image.width, height: image.height, requested: width)
        var picture = image
        if size.width != image.width {
            guard let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw Failure.notEncoded("The picture could not be scaled.")
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            guard let scaled = context.makeImage() else { throw Failure.notEncoded("The picture could not be scaled.") }
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
            throw Failure.notEncoded("The picture could not be made into a .\(format.rawValue) file.")
        }
        let partial = partial(for: path)
        do {
            try data.write(to: partial)
        } catch {
            throw Failure.notPlaced("\(path): \(error.localizedDescription)")
        }
        return try place(partial, at: path, format: format, width: size.width, height: size.height)
    }
}
