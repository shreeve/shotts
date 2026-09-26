import AppKit
import ShottsCore
import ShottsUI

/// The menu bar item, the hot key, the menus that give the editor its key equivalents, and the
/// developer switches (`--edit file.png` opens a file in the editor).
@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
            // Developer check of the area selection alone, on a drawn stand-in for each display
            // (no Screen Recording needed): writes the outcome to the file and quits.
            let out = URL(fileURLWithPath: arguments[i + 1])
            selectionCheck = AreaSelection(displays: NSScreen.screens.map(Self.standIn)) { outcome in
                let line: String
                switch outcome {
                case .cancelled: line = "cancelled"
                case let .selected(display, rect): line = "selected \(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height)) on \(display.screen.localizedName)"
                case let .window(display, window): line = "window \(window.id) at \(Int(window.frame.minX)),\(Int(window.frame.minY)) on \(display.screen.localizedName)"
                }
                try? line.write(to: out, atomically: true, encoding: .utf8)
                exit(0)
            }
            selectionCheck?.show()
        }
        if let i = arguments.firstIndex(of: "--preview-overlay"), i + 1 < arguments.count {
            // Developer check of the picker's drawing, off screen: the stand-in display with the
            // pointer and a selection placed, written as a PNG.
            exit(Self.previewOverlay(to: URL(fileURLWithPath: arguments[i + 1]), selected: arguments.contains("--dragged"),
                                     dimmed: arguments.contains("--dim"), corner: arguments.contains("--corner")) ? 0 : 1)
        }
        if arguments.contains("--check-text-entry") {
            // Developer check: text entry can open and take a string without a display.
            exit(TextEntryCheck.run() ? 0 : 1)
        }
        if let i = arguments.firstIndex(of: "--preview-style"), i + 1 < arguments.count {
            // Developer check of the style popover's layout, drawn off screen.
            exit(StylePopoverPreview.write(to: URL(fileURLWithPath: arguments[i + 1])) ? 0 : 1)
        }
        if let i = arguments.firstIndex(of: "--capture-window"), i + 2 < arguments.count, let id = CGWindowID(arguments[i + 1]) {
            // Developer check of window capture: the window with that id, with its shadow
            // unless --no-shadow, written as a PNG.
            let out = URL(fileURLWithPath: arguments[i + 2])
            let shadow = !arguments.contains("--no-shadow")
            Task {
                do {
                    let image = try await ScreenCapture.captureWindow(id, scale: NSScreen.main?.backingScaleFactor ?? 2, shadow: shadow)
                    try Export.write(Document(width: image.width, height: image.height, scale: 2), source: image, to: out)
                    exit(0)
                } catch {
                    fputs("capture failed: \(error)\n", stderr)
                    exit(1)
                }
            }
            return
        }
        if let i = arguments.firstIndex(of: "--render"), i + 2 < arguments.count {
            // Developer check of the renderer: every kind of annotation on the given picture,
            // written as a PNG, no window.
            exit(renderSample(from: URL(fileURLWithPath: arguments[i + 1]), to: URL(fileURLWithPath: arguments[i + 2])) ? 0 : 1)
        }
    }

    /// A picture standing in for a display: a gradient with a few marks, so the magnifier and
    /// the color readout have something to show.
    static func standIn(for screen: NSScreen) -> DisplayImage {
        let scale = screen.backingScaleFactor
        let w = Int(screen.frame.width * scale), h = Int(screen.frame.height * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let colors = [CGColor(srgbRed: 0.34, green: 0.63, blue: 0.81, alpha: 1), CGColor(srgbRed: 0.1, green: 0.2, blue: 0.4, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.8, blue: 0.2, alpha: 1))
        // The context's y runs upward; place each square so it lands at (i, i) from the top.
        for i in stride(from: 100, to: min(w, h), by: 300) {
            ctx.fill(CGRect(x: i, y: h - i - 40, width: 40, height: 40))
        }
        // One "window" for the picker to outline, at 700,700 points, 600 by 400.
        return DisplayImage(screen: screen, image: ctx.makeImage()!, scale: scale,
                            windows: [WindowInfo(id: 0, frame: CGRect(x: 700, y: 700, width: 600, height: 400))])
    }

    static func previewOverlay(to output: URL, selected: Bool, dimmed: Bool, corner: Bool) -> Bool {
        guard let screen = NSScreen.main else { return false }
        let display = standIn(for: screen)
        var options = SelectionOptions()
        options.dims = dimmed
        // The pointer lands 3 pixels inside the corner of the stand-in's square at 1600,1600,
        // so the magnifier must show that corner 6 cells up and left of its center. With
        // --corner it sits near the display's top-left instead, where the panels collide.
        let pointer = corner ? CGPoint(x: 30, y: 40)
            : CGPoint(x: (1600 + 3) / display.scale + 0.25, y: (1600 + 3) / display.scale + 0.25) // inside the stand-in window too
        let view = OverlayPreview.make(display: display, options: options, pointer: pointer,
                                       selection: selected ? CGRect(x: pointer.x - 320, y: pointer.y - 200, width: 320, height: 200) : nil)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: output); return true } catch { return false }
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
        // Callouts: an arrow with its words wrapped beside the tail on the side away from the tip.
        func callout(_ tail: CGPoint, _ tip: CGPoint, _ words: String, _ style: Style, maxWidth: Double) -> Annotation {
            let layout = CalloutLayout(tail: tail, tip: tip, lineHeight: Renderer.lineHeight(style: style, scale: 2), maxWidth: maxWidth, in: document.pixelBounds)
            let size = Renderer.textSize(words, style: style, scale: 2, width: layout.width)
            let box = Annotation.TextBox(origin: layout.origin(for: size), string: words, size: size, alignment: layout.alignment)
            return Annotation(shape: .callout(from: tail, to: tip, text: box), style: style)
        }
        document.add(callout(CGPoint(x: w * 0.55, y: h * 0.9), CGPoint(x: w * 0.85, y: h * 0.7),
                             "A callout wraps its words beside the tail and stays inside the picture", style, maxWidth: w * 0.3))
        // And a vertical one: text centered above the tail of an arrow pointing down.
        document.add(callout(CGPoint(x: w * 0.3, y: h * 0.6), CGPoint(x: w * 0.32, y: h * 0.85), "centered above, growing up", blue, maxWidth: w * 0.25))
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
        flow.open(image: cg, scale: max(scale, 1), on: NSScreen.main)
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
        menu.addItem(optionItem("Copy to Clipboard", \.copiesOnCapture))
        menu.addItem(optionItem("Include Window Shadow", \.dropShadow))
        menu.addItem(optionItem("Dim Outside Selection", \.dims))
        menu.addItem(optionItem("Show Magnifier", \.magnifies))
        menu.addItem(optionItem("Show Hints", \.showsHints))
        menu.delegate = self
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

    // MARK: - Selection options in the menu

    private func optionItem(_ title: String, _ key: WritableKeyPath<SelectionOptions, Bool>) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(optionToggled(_:)), keyEquivalent: "")
        item.representedObject = OptionKey(key)
        item.target = self
        return item
    }

    /// A key path wrapped so a menu item can carry it.
    private final class OptionKey {
        let path: WritableKeyPath<SelectionOptions, Bool>
        init(_ path: WritableKeyPath<SelectionOptions, Bool>) { self.path = path }
    }

    @objc private func optionToggled(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? OptionKey else { return }
        var options = SelectionOptions.current
        options[keyPath: key.path].toggle()
        SelectionOptions.current = options
    }

    /// Check marks follow the saved options each time the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let options = SelectionOptions.current
        for item in menu.items {
            if let key = item.representedObject as? OptionKey {
                item.state = options[keyPath: key.path] ? .on : .off
            }
        }
    }

    private func functionKey(_ key: Int) -> String {
        String(utf16CodeUnits: [unichar(key)], count: 1)
    }
}
