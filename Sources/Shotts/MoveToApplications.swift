import AppKit
import ShottsCore
import ShottsUI

/// On a release build's launch from anywhere but an Applications folder, offers to move Shotts
/// there, and does it: copies the bundle in, replacing an older copy; clears the download
/// quarantine, so macOS runs it where it is and it can update itself; puts the downloaded copy in
/// the Trash; and reopens from Applications.
enum MoveToApplications {
    private static let skipKey = "app.skipMoveToApplications"

    /// True when Shotts is moving and about to quit, so launching should go no further.
    static func offerIfNeeded() -> Bool {
        let running = Bundle.main.bundleURL
        let home = NSHomeDirectory()
        guard AppLocation.offersMove(bundlePath: running.path, home: home),
              !UserDefaults.standard.bool(forKey: skipKey) else { return false }
        Front.bringShotts()
        let alert = NSAlert()
        alert.messageText = "Move Shotts to your Applications folder?"
        alert.informativeText = "There it stays put, and it can keep itself up to date. The downloaded copy goes to the Trash."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: skipKey) }
        guard response == .alertFirstButtonReturn else { return false }
        do {
            try move(running, home: home)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    private static func move(_ running: URL, home: String) throws {
        let files = FileManager.default
        let folder = URL(fileURLWithPath: AppLocation.destinationFolder(canWriteShared: files.isWritableFile(atPath: "/Applications"), home: home),
                         isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(running.lastPathComponent)
        // Copied beside it first: a copy that fails leaves the Shotts already there as it was.
        let staged = folder.appendingPathComponent(".\(UUID().uuidString)-\(running.lastPathComponent)")
        var trashed: NSURL?
        do {
            try files.copyItem(at: running, to: staged)
            if files.fileExists(atPath: destination.path) { try files.trashItem(at: destination, resultingItemURL: &trashed) }
            try files.moveItem(at: staged, to: destination)
        } catch {
            // Back as it was: no half copy left, and the Shotts that was there out of the Trash.
            try? files.removeItem(at: staged)
            if let trashed = trashed as URL?, !files.fileExists(atPath: destination.path) { try? files.moveItem(at: trashed, to: destination) }
            throw error
        }
        // Downloaded is not installed: with the quarantine left on, macOS would run the copy from
        // a read-only stand-in where Sparkle cannot update it.
        removexattr(destination.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        if let download = originalLocation(of: running), download != destination {
            try? files.trashItem(at: download, resultingItemURL: nil)
        }
        reopen(destination)
    }

    /// Opens the moved copy once this one has quit, since only one Shotts runs at a time.
    private static func reopen(_ destination: URL) {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", "while kill -0 $1 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$2\"",
                            "sh", String(ProcessInfo.processInfo.processIdentifier), destination.path]
        try? waiter.run()
        NSApp.terminate(nil)
    }

    /// Where the app really is. A freshly downloaded app runs from a hidden read-only copy
    /// ("translocated"), and macOS offers no public call for the original; this is the one other
    /// Mac apps use, looked up at run time. Nil if it cannot be found: the download then stays.
    private static func originalLocation(of url: URL) -> URL? {
        guard url.path.contains("/AppTranslocation/") else { return url }
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        return unsafeBitCast(symbol, to: Original.self)(url as CFURL, nil)?.takeRetainedValue() as URL?
    }
}
