import AppKit
import ImageIO
import ShottsCore
import UniformTypeIdentifiers

/// Where a finished capture goes: the pasteboard, a file the user names, or a temporary file
/// for a drag.
public enum Export {
    /// Puts the picture on the pasteboard as PNG, and as TIFF for the apps that still read only
    /// that. Returns false, leaving the pasteboard alone, when the picture cannot be made.
    public static func copy(_ document: Document, source: CGImage, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let image = Renderer.image(of: document, source: source),
              let data = pasteboardData(image, scale: document.scale) else { return false }
        put(data, on: pasteboard)
        return true
    }

    /// Copies a plain capture as it is taken without holding up the editor: encoding a 5K
    /// capture takes a tenth of a second or more, so it happens off the main thread. The
    /// pasteboard is written only if nothing has been copied since the call, so the editor's
    /// Copy, or anything copied in another app meanwhile, is never replaced by the plain capture.
    @discardableResult
    public static func copyInBackground(_ image: CGImage, scale: Double, to pasteboard: NSPasteboard = .general) -> Task<Void, Never> {
        let count = pasteboard.changeCount
        return Task {
            let data = await Task.detached(priority: .userInitiated) { pasteboardData(image, scale: scale) }.value
            guard let data, pasteboard.changeCount == count else { return }
            put(data, on: pasteboard)
        }
    }

    /// `Shotts 2026-09-26 at 10.12.34 PM.png`, named the way the Screenshot app names its files:
    /// the date year first, then the time as the user's locale writes it, 12 or 24 hour. Colons,
    /// which Finder shows as slashes, become dots, and the narrow space some locales put before
    /// AM or PM becomes a plain one, which is easier to type in a shell. A recording's files
    /// are `Shotts Recording 2026-09-26 at 10.12.34 PM.mp4`.
    public static func suggestedName(date: Date = .now, locale: Locale = .current, prefix: String = "Shotts",
                                     fileExtension: String = "png") -> String {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = Calendar(identifier: .gregorian)
        // A time style, unlike a fixed format, follows the 24-hour setting in System Settings;
        // medium is the one with seconds.
        f.timeStyle = .medium
        f.dateFormat = "yyyy-MM-dd 'at' " + f.dateFormat
        let stamp = f.string(from: date).replacing(":", with: ".").replacing("/", with: "-").replacing(/\s/, with: " ")
        return "\(prefix) \(stamp).\(fileExtension)"
    }

    /// Writes the PNG.
    public static func write(_ document: Document, source: CGImage, to url: URL) throws {
        guard let image = Renderer.image(of: document, source: source),
              let png = encode(image, scale: document.scale, as: .png) else { throw ExportError.render }
        try png.write(to: url, options: .atomic)
    }

    /// A PNG for a drag out of the editor. It goes in one temporary folder that is emptied
    /// first, so no more than the latest drag's picture is ever left on disk: the app it was
    /// dropped on has had its copy by the next drag.
    public static func temporaryFile(_ document: Document, source: CGImage) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Shotts Drag", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(suggestedName())
        try write(document, source: source, to: url)
        return url
    }

    public enum ExportError: Error { case render }

    /// The image as a file of the given type, marked with the capture's resolution (144 dpi at
    /// 2x, as the Screenshot app marks its files) so that apps which honor it, like Pages, Mail,
    /// and Keynote, place it at its on-screen size rather than twice that. Every export goes
    /// through here.
    nonisolated static func encode(_ image: CGImage, scale: Double, as type: UTType) -> Data? {
        let data = NSMutableData()
        guard let file = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * scale
        CGImageDestinationAddImage(file, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        return CGImageDestinationFinalize(file) ? data as Data : nil
    }

    /// Both of the pasteboard's forms, or nothing if either cannot be made: an empty TIFF on
    /// the pasteboard would paste as nothing in the apps that read it.
    nonisolated static func pasteboardData(_ image: CGImage, scale: Double) -> (png: Data, tiff: Data)? {
        guard let png = encode(image, scale: scale, as: .png), let tiff = encode(image, scale: scale, as: .tiff) else { return nil }
        return (png, tiff)
    }

    static func put(_ data: (png: Data, tiff: Data), on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setData(data.png, forType: .png)
        pasteboard.setData(data.tiff, forType: .tiff)
    }
}
