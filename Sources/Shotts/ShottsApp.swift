import AppKit
import ShottsCore
import ShottsUI
import Sparkle

/// The menu bar item, the hot key, and the menus that give the editor its key equivalents.
@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem?
    private let flow = CaptureFlow()
    /// Reads SUFeedURL and SUPublicEDKey from Info.plist and checks daily, silently
    /// (SUEnableAutomaticChecks), so it never asks a question of its own. The plist always has
    /// the key: the release script refuses to build without one.
    private let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        makeStatusItem(hasHotKey: HotKey.registerF10 { [weak self] in self?.flow.begin() })
        updater.startUpdater()
        #if DEBUG
        DevSwitches.run(CommandLine.arguments) { openFile($0, returningTo: nil) }
        #endif
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc private func captureArea() {
        flow.begin()
    }

    /// Open Image…: the editor, or a cancelled panel, gives focus back to the app in front when
    /// the menu was used.
    @objc private func openFile() {
        let returnTo = flow.appToReturnTo()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        NSApp.activate(ignoringOtherApps: true) // see AreaSelection.show()
        guard panel.runModal() == .OK, let url = panel.url else { returnTo?.activate(); return }
        openFile(url, returningTo: returnTo)
    }

    private func openFile(_ url: URL, returningTo returnTo: NSRunningApplication?) {
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        // A file carries no backing scale. Trust its DPI when it says 2x; otherwise a picture
        // wider than the screen in points is taken for a Retina capture.
        var scale = Double(cg.width) / Double(image.size.width)
        if !(scale.isFinite && scale > 1), let screen = NSScreen.main, Double(cg.width) > screen.frame.width {
            scale = screen.backingScaleFactor
        }
        flow.open(image: cg, scale: max(scale, 1), on: NSScreen.main, returningTo: returnTo)
    }

    /// Without the hot key, because another app holds F10, Capture Area says so instead of
    /// showing a key that does nothing.
    private func makeStatusItem(hasHotKey: Bool) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Shotts")
        let menu = NSMenu()
        let capture = NSMenuItem(title: hasHotKey ? "Capture Area" : "Capture Area (another app has F10)", action: #selector(captureArea),
                                 keyEquivalent: hasHotKey ? functionKey(NSF10FunctionKey) : "")
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
        menu.addItem(checkForUpdatesItem())
        menu.addItem(NSMenuItem(title: "Quit Shotts", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    private func checkForUpdatesItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func checkForUpdates() {
        updater.checkForUpdates(nil)
    }

    /// Sparkle says when a check can start: not before the updater has started, and not during one.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdates) { return updater.updater.canCheckForUpdates }
        return true
    }

    /// Key equivalents route through the main menu even for a menu bar app, so the editor gets
    /// Undo, Redo, Copy, Delete, and Close from here.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(checkForUpdatesItem())
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Shotts", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let file = NSMenu(title: "File")
        file.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        file.addItem(.separator())
        // To the editor's window controller through the responder chain.
        file.addItem(NSMenuItem(title: "Print…", action: #selector(EditorWindowController.printPressed), keyEquivalent: "p"))
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
