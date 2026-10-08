import AppKit
import Carbon
import ServiceManagement
import ShottsCore
import ShottsUI
import Sparkle

/// The menu bar item, the hot key, and the menus that give the editor its key equivalents.
@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem?
    /// The menu bar item's menu, set aside while it shows a recording's time.
    private var statusMenu: NSMenu?
    /// The recording the menu bar item shows the time of, and what ticks it.
    private var recorder: Recorder?
    private var ticker: Timer?
    private let flow = CaptureFlow()
    /// What `shotts` asks for, while Allow Command-Line Capture is on.
    private let script = ScriptRunner()
    /// Install Command-Line Tool…, shown only until `shotts` is found on the PATH's usual places.
    private var installItem: NSMenuItem?
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
        #if !DEBUG
        // A download run from anywhere but Applications offers to move itself there first.
        if MoveToApplications.offerIfNeeded() { return }
        #endif
        NSApp.mainMenu = makeMainMenu()
        flow.onRecording = { [weak self] recorder in self?.showRecording(recorder) }
        script.onRecording = { [weak self] recorder in self?.showRecording(recorder) }
        script.onCountdown = { [weak self] seconds in self?.showCountdown(seconds) }
        script.isRecordingElsewhere = { [weak self] in self?.flow.isBusyRecording ?? false }
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil,
                                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.poweringOff = true }
        }
        let capture = HotKey.register { [weak self] in self?.captureArea() }
        let showLast = HotKey.register(modifiers: optionKey) { [weak self] in self?.flow.showLast() }
        // ⇧⌘4 and ⌥⇧⌘4 as well, for a keyboard whose top row controls the Mac, but only once
        // macOS's own ⇧⌘4 is turned off: until then macOS answers it, and Shotts lets it.
        _ = HotKey.register(kVK_ANSI_4, modifiers: cmdKey | shiftKey) { [weak self] in
            if !Self.macOSAnswers(SystemShortcuts.shift | SystemShortcuts.command) { self?.captureArea() }
        }
        _ = HotKey.register(kVK_ANSI_4, modifiers: cmdKey | shiftKey | optionKey) { [weak self] in
            if !Self.macOSAnswers(SystemShortcuts.shift | SystemShortcuts.command | SystemShortcuts.option) { self?.flow.showLast() }
        }
        makeStatusItem(hasHotKey: capture, hasShowLastKey: showLast)
        #if DEBUG
        // A developer check runs without the updater, whose alerts would hold it up.
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) {
            DevSwitches.run(CommandLine.arguments) { openFile($0, returningTo: nil) }
            return
        }
        #endif
        // Recordings live only while their windows are open: what no running Shotts holds is
        // from a crash. Not under a developer switch, which another Shotts may be running beside.
        Recording.removeLeftovers()
        script.start()
        updater.startUpdater()
    }

    func applicationWillTerminate(_ notification: Notification) {
        script.stopListening()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Quitting while recording would lose the recording: it stops instead and opens in its
    /// window, and quitting again quits. Quitting with annotated captures or unsaved recordings
    /// open asks first, saying what would be lost; with nothing to lose, it quits at once.
    /// Logging out or shutting down is not held up: macOS says so first
    /// (`willPowerOffNotification`), and then Shotts quits as asked.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !poweringOff else { return .terminateNow }
        if flow.isRecording || script.isRecording {
            stopRecording()
            return .terminateCancel
        }
        let work = flow.unsavedWork
        guard let warning = Quitting.warning(captures: work.captures, recordings: work.recordings) else { return .terminateNow }
        Front.bringShotts()
        let alert = NSAlert()
        alert.messageText = "Quit Shotts?"
        alert.informativeText = warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Whether macOS answers "4" with `modifiers` itself, read afresh at each press, so turning
    /// its ⇧⌘4 off in System Settings hands the key to Shotts at once.
    private static func macOSAnswers(_ modifiers: Int) -> Bool {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        let shortcuts = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any]
        return SystemShortcuts.macOSAnswers(keyCode: SystemShortcuts.four, modifiers: modifiers, in: shortcuts)
    }

    private var poweringOff = false
    private var powerOffObserver: NSObjectProtocol?

    @objc private func showLastCapture() {
        flow.showLast()
    }

    /// F10: a capture, or while `shotts` is recording, the end of that recording.
    @objc private func captureArea() {
        if script.isRecording { script.stopRecording() } else { flow.begin() }
    }

    /// Open Image…: the editor, or a cancelled panel, gives focus back to the app in front when
    /// the menu was used.
    @objc private func openFile() {
        let returnTo = flow.appToReturnTo()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        Front.bringShotts()
        guard panel.runModal() == .OK, let url = panel.url else { Front.giveBack(to: returnTo); return }
        openFile(url, returningTo: returnTo)
    }

    private func openFile(_ url: URL, returningTo returnTo: NSRunningApplication?) {
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            NSSound.beep()
            return
        }
        let scale = Document.scale(ofFile: cg.width, pointWidth: image.size.width, screenWidth: NSScreen.main.map { Double($0.frame.width) },
                                   screenScale: Double(NSScreen.main?.backingScaleFactor ?? 1))
        flow.open(image: cg, scale: scale, on: NSScreen.main, returningTo: returnTo)
    }

    /// Without the hot key, because another app holds F10, Capture Area says so instead of
    /// showing a key that does nothing.
    private func makeStatusItem(hasHotKey: Bool, hasShowLastKey: Bool) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Shotts")
        let menu = NSMenu()
        menu.addItem(aboutItem())
        menu.addItem(.separator())
        let capture = NSMenuItem(title: hasHotKey ? "Capture Area" : "Capture Area (another app has F10)", action: #selector(captureArea),
                                 keyEquivalent: hasHotKey ? functionKey(NSF10FunctionKey) : "")
        capture.keyEquivalentModifierMask = []
        capture.target = self
        menu.addItem(capture)
        let last = NSMenuItem(title: "Show Last Capture", action: #selector(showLastCapture), keyEquivalent: hasShowLastKey ? functionKey(NSF10FunctionKey) : "")
        last.keyEquivalentModifierMask = .option
        last.target = self
        menu.addItem(last)
        let open = NSMenuItem(title: "Open Image…", action: #selector(openFile as () -> Void), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        // In the order a capture meets them: aiming, dragging, clicking a window, taking it,
        // and where it opens.
        menu.addItem(optionItem("Show Magnifier", \.magnifies))
        menu.addItem(optionItem("Dim Outside Selection", \.dims))
        menu.addItem(optionItem("Include Window Shadow", \.dropShadow))
        menu.addItem(optionItem("Copy to Clipboard", \.copiesOnCapture))
        menu.addItem(optionItem("New Window per Capture", \.newWindows))
        menu.delegate = self
        menu.addItem(.separator())
        // How Shotts itself runs, apart from the capture options above, which follow a capture.
        let start = NSMenuItem(title: "Start at Login", action: #selector(startAtLoginToggled), keyEquivalent: "")
        start.target = self
        menu.addItem(start)
        let allow = NSMenuItem(title: "Allow Command-Line Capture", action: #selector(allowCommandLineToggled), keyEquivalent: "")
        allow.target = self
        allow.toolTip = "Lets the shotts command, and any program you run, take screenshots and recordings through Shotts, with the Mac's sound or the microphone when asked"
        menu.addItem(allow)
        let install = NSMenuItem(title: "Install Command-Line Tool…", action: #selector(installCommandLineTool), keyEquivalent: "")
        install.target = self
        menu.addItem(install)
        installItem = install
        menu.addItem(.separator())
        menu.addItem(checkForUpdatesItem())
        menu.addItem(NSMenuItem(title: "Quit Shotts", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusMenu = menu
        statusItem = item
    }

    /// While recording, the item is a red dot and the time so far, and clicking it stops the
    /// recording; its menu comes back when the recording ends.
    private func showRecording(_ recorder: Recorder?) {
        guard let item = statusItem, let button = item.button else { return }
        ticker?.invalidate()
        ticker = nil
        self.recorder = recorder
        guard recorder != nil else {
            button.attributedTitle = NSAttributedString()
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Shotts")
            button.target = nil
            button.action = nil
            button.toolTip = nil
            item.length = NSStatusItem.squareLength
            item.menu = statusMenu
            return
        }
        item.menu = nil
        item.length = NSStatusItem.variableLength
        button.image = nil
        button.target = self
        button.action = #selector(stopRecording)
        button.toolTip = "Stop recording (F10)"
        tick()
        let timer = Timer(timeInterval: 0.25, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    @objc private func tick() {
        guard let recorder else { return }
        let time = RecordingRule.clock(recorder.elapsed)
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        // A red dot while recording; paused, the pause sign, and the time held.
        let title = recorder.isPaused
            ? NSMutableAttributedString(string: "❚❚ ", attributes: [.font: font])
            : NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: NSColor.systemRed, .font: font])
        title.append(NSAttributedString(string: time, attributes: [.font: font]))
        statusItem?.button?.attributedTitle = title
        statusItem?.button?.setAccessibilityLabel("\(recorder.isPaused ? "Paused" : "Recording"), \(time). Stop recording")
    }

    @objc private func stopRecording() {
        if script.isRecording { script.stopRecording() } else { flow.stopRecording() }
    }

    /// The seconds before a delayed `shotts` capture, in place of the icon.
    private func showCountdown(_ seconds: Int?) {
        guard recorder == nil, let button = statusItem?.button else { return }
        guard let seconds else {
            button.attributedTitle = NSAttributedString()
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Shotts")
            statusItem?.length = NSStatusItem.squareLength
            return
        }
        statusItem?.length = NSStatusItem.variableLength
        button.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.attributedTitle = NSAttributedString(string: " \(seconds)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        ])
        button.setAccessibilityLabel("Capturing in \(seconds) seconds")
    }

    // MARK: - The command line

    // MARK: - Start at Login

    /// Shotts as a login item, through macOS itself, which keeps the setting: it shows in System
    /// Settings › General › Login Items, where it can be turned off too, so the checkmark reads
    /// macOS each time the menu opens rather than remembering anything of its own.
    @objc private func startAtLoginToggled() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            Front.bringShotts()
            let alert = NSAlert()
            alert.messageText = "Shotts could not change Start at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        // macOS may want the user to allow it in Login Items first.
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc private func allowCommandLineToggled() {
        ScriptRunner.isAllowed.toggle()
    }

    /// Where `shotts` is looked for: Homebrew's cask puts it in its own bin, this menu in /usr/local/bin.
    private static let toolPlaces = ["/usr/local/bin/shotts", "/opt/homebrew/bin/shotts"]

    private static var toolIsInstalled: Bool {
        toolPlaces.contains { (try? FileManager.default.destinationOfSymbolicLink(atPath: $0)) != nil || FileManager.default.fileExists(atPath: $0) }
    }

    /// Links /usr/local/bin/shotts to the tool inside Shotts, asking for an administrator's
    /// password in the system's own dialog, since that folder belongs to the system.
    @objc private func installCommandLineTool() {
        let tool = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/shotts").path
        guard FileManager.default.isExecutableFile(atPath: tool) else { NSSound.beep(); return }
        func quoted(_ s: String) -> String { "'" + s.replacing("'", with: "'\\''") + "'" }
        let command = "mkdir -p /usr/local/bin && ln -sf \(quoted(tool)) /usr/local/bin/shotts"
        let source = "do shell script \"\(command.replacing("\\", with: "\\\\").replacing("\"", with: "\\\""))\" with administrator privileges"
        Front.bringShotts()
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        // Cancelled in the password dialog: nothing to say.
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
            let alert = NSAlert()
            alert.messageText = "The command-line tool could not be installed"
            alert.informativeText = error[NSAppleScript.errorMessage] as? String ?? ""
            alert.runModal()
        } else if error == nil, !ScriptRunner.isAllowed {
            let alert = NSAlert()
            alert.messageText = "shotts is installed"
            alert.informativeText = "Turn on Allow Command-Line Capture in the Shotts menu for it to work. Try `shotts list` in Terminal."
            alert.addButton(withTitle: "Turn It On")
            alert.addButton(withTitle: "Not Now")
            if alert.runModal() == .alertFirstButtonReturn { ScriptRunner.isAllowed = true }
        }
    }

    private func aboutItem() -> NSMenuItem {
        let item = NSMenuItem(title: "About Shotts", action: #selector(showAbout), keyEquivalent: "")
        item.target = self
        return item
    }

    /// The standard About window: icon, name, version, the copyright from Info.plist, and a link
    /// to the project. The build number is the version, so it is not shown twice.
    @objc private func showAbout() {
        Front.bringShotts()
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let credits = NSAttributedString(string: "github.com/shreeve/shotts", attributes: [
            .link: URL(string: "https://github.com/shreeve/shotts")!,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .paragraphStyle: centered,
        ])
        NSApp.orderFrontStandardAboutPanel(options: [.version: "", .credits: credits])
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
        if item.action == #selector(showLastCapture) { return flow.hasLastCapture }
        return true
    }

    /// Key equivalents route through the main menu even for a menu bar app, so the editor gets
    /// Undo, Redo, Copy, Delete, and Close from here.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(aboutItem())
        appMenu.addItem(.separator())
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
            if item.action == #selector(allowCommandLineToggled) { item.state = ScriptRunner.isAllowed ? .on : .off }
            if item.action == #selector(startAtLoginToggled) { item.state = SMAppService.mainApp.status == .enabled ? .on : .off }
        }
        installItem?.isHidden = Self.toolIsInstalled
    }

    private func functionKey(_ key: Int) -> String {
        String(utf16CodeUnits: [unichar(key)], count: 1)
    }
}
