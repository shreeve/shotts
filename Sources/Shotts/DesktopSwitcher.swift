import AppKit

/// Fast Desktop Switching: while it is on, Shotts runs `shotts-switcher`, the helper in its bundle
/// (`Switcher/` in the repository), which switches desktops at once, without the slide, on a
/// three-finger swipe or Control-Left/Right. It runs only while Shotts does: Shotts stops it on
/// quitting, and it quits by itself should Shotts go any other way.
///
/// It needs Accessibility, which macOS checks for the app that starts it, Shotts: turned on
/// without it, Shotts asks, as for a scrolling capture, and starts it once allowed. A process
/// cannot take up a grant made while it runs, so the helper exits (status 3) and is started
/// again rather than waiting.
final class DesktopSwitcher {
    static let enabledKey = "switcher.enabled"
    private static let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/shotts-switcher")

    /// macOS 26.6 or later, and the helper in the bundle.
    static var isAvailable: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0))
            && FileManager.default.isExecutableFile(atPath: helper.path)
    }

    /// noswoosh does the same, and both would answer every swipe, so the helper waits while it runs.
    static var noswooshIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "ax.max.noswoosh" || $0.executableURL?.lastPathComponent == "noswoosh"
        }
    }

    var isOn: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    private var process: Process?
    private var waiting: Timer?
    /// Recent starts: a helper that keeps failing is left alone after five in a minute.
    private var starts: [Date] = []

    /// The menu item: on starts it, asking for Accessibility if need be; off stops it.
    func toggle() {
        UserDefaults.standard.set(!isOn, forKey: Self.enabledKey)
        if isOn {
            starts = []
            start(asking: true)
        } else {
            stop()
        }
    }

    /// Starts it if it is on and nothing stands in the way. Without Accessibility it waits for
    /// it, showing macOS's own dialog only when `asking` (the user just turned it on).
    func start(asking: Bool = false) {
        guard isOn, Self.isAvailable, process == nil, waiting == nil, !Self.noswooshIsRunning else { return }
        guard AutoScroller.allowed else { return waitForAccessibility(asking: asking) }
        starts = starts.filter { $0.timeIntervalSinceNow > -60 } + [Date()]
        guard starts.count <= 5 else { return }
        let process = Process()
        process.executableURL = Self.helper
        process.standardOutput = FileHandle.nullDevice
        process.standardError = Self.log()
        let id = ObjectIdentifier(process)
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(id, status: status) } }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            NSLog("Shotts could not start shotts-switcher: \(error.localizedDescription)")
        }
    }

    /// Stops it, as quitting Shotts or turning it off does: it puts macOS's Control-arrow
    /// shortcuts back as it goes.
    func stop() {
        waiting?.invalidate()
        waiting = nil
        guard let process else { return }
        self.process = nil
        process.terminationHandler = nil
        process.terminate()
        // It quits at once on the signal; a helper that does not is not left behind.
        let deadline = Date.now.addingTimeInterval(1)
        while process.isRunning, Date.now < deadline { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func ended(_ id: ObjectIdentifier, status: Int32) {
        guard let process, ObjectIdentifier(process) == id else { return }
        self.process = nil
        switch status {
        case 3: waitForAccessibility(asking: false)   // Accessibility taken away since
        case 4, 5: break                              // this macOS cannot
        default: DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
        }
    }

    private func waitForAccessibility(asking: Bool) {
        if asking { AutoScroller.ask() }
        waiting = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AutoScroller.allowed else { return }
                self.waiting?.invalidate()
                self.waiting = nil
                self.start()
            }
        }
    }

    /// The helper's own messages, for when it does not work: `~/Library/Logs/Shotts/shotts-switcher.log`,
    /// new each time it starts.
    private static func log() -> FileHandle {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Shotts", isDirectory: true)
        let file = folder.appendingPathComponent("shotts-switcher.log")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        return (try? FileHandle(forWritingTo: file)) ?? FileHandle.nullDevice
    }
}
