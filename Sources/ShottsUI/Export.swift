import AppKit
import ShottsCore
import UniformTypeIdentifiers

/// Where a finished capture goes: the pasteboard, a file the user names, or a temporary file
/// for a drag.
public enum Export {
    /// Whether exports carry the drop shadow, from the saved options unless a caller says.
    public static var shadow: Bool { SelectionOptions.current.dropShadow }

    public static func copy(_ document: Document, source: CGImage, shadow: Bool = Export.shadow) -> Bool {
        guard let image = Renderer.image(of: document, source: source, shadow: shadow),
              let png = Renderer.pngData(of: document, source: source, shadow: shadow) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        pasteboard.setData(NSBitmapImageRep(cgImage: image).tiffRepresentation ?? Data(), forType: .tiff)
        return true
    }

    /// `Shotts 2026-09-26 at 10.12.34.png`, in the style of the Screenshot app.
    public static func suggestedName(date: Date = .now) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Shotts \(f.string(from: date)).png"
    }

    /// Writes the PNG. Returns the URL written.
    @discardableResult
    public static func write(_ document: Document, source: CGImage, to url: URL, shadow: Bool = Export.shadow) throws -> URL {
        guard let png = Renderer.pngData(of: document, source: source, shadow: shadow) else { throw ExportError.render }
        try png.write(to: url, options: .atomic)
        return url
    }

    /// A PNG in a fresh temporary folder, for a drag out of the editor. The folder is the
    /// caller's to remove.
    public static func temporaryFile(_ document: Document, source: CGImage, shadow: Bool = Export.shadow) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shotts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try write(document, source: source, to: folder.appendingPathComponent(suggestedName()), shadow: shadow)
    }

    public enum ExportError: Error { case render }
}
