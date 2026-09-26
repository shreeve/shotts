import AppKit
import ShottsCore
import ShottsUI

/// The menu bar item, the hot key, the menus that give the editor its key equivalents, and the
/// developer switches (`--edit file.png` opens a file in the editor).
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private let flow = CaptureFlow()
    private var selectionCheck: AreaSelection?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        makeStatusItem()
        hotKey = HotKey(keyCode: HotKey.f10) { [weak self] in self?.flow.begin() }

        let arguments = CommandLine.arguments
        if let i = arguments.firstIndex(of: "--edit"), i + 1 < arguments.count {
            openFile(URL(fileURLWithPath: arguments[i + 1]))
        }
        if let i = arguments.firstIndex(of: "--select"), i + 1 < arguments.count {
            // Developer check of the area selection alone: writes the outcome to the file and quits.
            let out = URL(fileURLWithPath: arguments[i + 1])
            selectionCheck = AreaSelection { outcome in
                let line: String
                switch outcome {
                case .cancelled: line = "cancelled"
                case let .selected(screen, rect): line = "selected \(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height)) on \(screen.localizedName)"
                }
                try? line.write(to: out, atomically: true, encoding: .utf8)
                exit(0)
            }
            selectionCheck?.show()
        }
        if let i = arguments.firstIndex(of: "--render"), i + 2 < arguments.count {
            // Developer check of the renderer: every kind of annotation on the given picture,
            // written as a PNG, no window.
            exit(renderSample(from: URL(fileURLWithPath: arguments[i + 1]), to: URL(fileURLWithPath: arguments[i + 2])) ? 0 : 1)
        }
    }

    private func renderSample(from input: URL, to output: URL) -> Bool {
        guard let image = NSImage(contentsOf: input),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let w = Double(cg.width), h = Double(cg.height)
        var document = Document(width: cg.width, height: cg.height, scale: 2)
        let style = Style.standard
        var blue = style; blue.color = .blue
        var yellow = style; yellow.color = .yellow
        var big = style; big.fontSize = 36
        var even = style; even.taperedArrows = false
        document.add(Annotation(shape: .arrow(from: CGPoint(x: w * 0.15, y: h * 0.75), to: CGPoint(x: w * 0.4, y: h * 0.45)), style: style))
        document.add(Annotation(shape: .arrow(from: CGPoint(x: w * 0.4, y: h * 0.75), to: CGPoint(x: w * 0.2, y: h * 0.55)), style: even))
        document.add(Annotation(shape: .rectangle(CGRect(x: w * 0.45, y: h * 0.2, width: w * 0.3, height: h * 0.25)), style: blue))
        document.add(Annotation(shape: .ellipse(CGRect(x: w * 0.6, y: h * 0.55, width: w * 0.25, height: h * 0.2)), style: style))
        document.add(Annotation(shape: .highlighter([CGPoint(x: w * 0.1, y: h * 0.15), CGPoint(x: w * 0.4, y: h * 0.16)]), style: yellow))
        document.add(Annotation(shape: .pen((0...20).map { i in CGPoint(x: w * 0.1 + Double(i) * w * 0.015, y: h * 0.9 + sin(Double(i) / 2) * h * 0.03) }), style: blue))
        document.add(Annotation(shape: .obscure(CGRect(x: w * 0.7, y: h * 0.8, width: w * 0.2, height: h * 0.12)), style: style))
        let text = "This is impossible to use!"
        document.add(Annotation(shape: .text(origin: CGPoint(x: w * 0.15, y: h * 0.3), string: text, size: Renderer.textSize(text, style: big, scale: 2)), style: big))
        if CommandLine.arguments.contains("--crop") {
            document.setCrop(CGRect(x: w * 0.1, y: h * 0.1, width: w * 0.6, height: h * 0.5))
        }
        do {
            try Export.write(document, source: cg, to: output)
            return true
        } catch {
            fputs("render failed: \(error)\n", stderr)
            return false
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc private func captureArea() {
        flow.begin()
    }

    @objc private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { openFile(url) }
    }

    private func openFile(_ url: URL) {
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        // A file carries no backing scale. Trust its DPI when it says 2x; otherwise a picture
        // wider than the screen in points is taken for a Retina capture.
        var scale = Double(cg.width) / Double(image.size.width)
        if !(scale.isFinite && scale > 1), let screen = NSScreen.main, Double(cg.width) > screen.frame.width {
            scale = screen.backingScaleFactor
        }
        flow.open(ScreenCapture.Capture(image: cg, scale: max(scale, 1)), on: NSScreen.main)
    }

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Shotts")
        let menu = NSMenu()
        let capture = NSMenuItem(title: "Capture Area", action: #selector(captureArea), keyEquivalent: functionKey(NSF10FunctionKey))
        capture.keyEquivalentModifierMask = []
        capture.target = self
        menu.addItem(capture)
        let open = NSMenuItem(title: "Open Image…", action: #selector(openFile as () -> Void), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Shotts", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    /// Key equivalents route through the main menu even for a menu bar app, so the editor gets
    /// Undo, Redo, Copy, Delete, and Close from here.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Shotts", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let file = NSMenu(title: "File")
        file.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileItem.submenu = file

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: #selector(CanvasView.undo(_:)), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: #selector(CanvasView.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        let delete = NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "\u{8}")
        delete.keyEquivalentModifierMask = []
        edit.addItem(delete)
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        return main
    }

    private func functionKey(_ key: Int) -> String {
        String(utf16CodeUnits: [unichar(key)], count: 1)
    }
}
