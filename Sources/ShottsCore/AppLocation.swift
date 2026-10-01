import Foundation

/// Where Shotts belongs, and whether to offer moving it there. Run from anywhere but an
/// Applications folder (Downloads, the Desktop, the read-only spot macOS runs a fresh download
/// from), it is offered a move to Applications on launch: there it stays put and can update
/// itself. Paths only; the moving is the app's.
public enum AppLocation {
    /// Whether an app bundle at `bundlePath` should offer to move itself: anywhere but an
    /// Applications folder, the shared one or the user's own, or a folder inside either.
    public static func offersMove(bundlePath: String, home: String) -> Bool {
        let path = (bundlePath as NSString).standardizingPath
        let folders = ["/Applications", (home as NSString).appendingPathComponent("Applications")]
        return !folders.contains { path.hasPrefix($0 + "/") }
    }

    /// The folder to move into: the shared Applications folder when it can be written, which
    /// needs no password on an administrator's account, else the user's own.
    public static func destinationFolder(canWriteShared: Bool, home: String) -> String {
        canWriteShared ? "/Applications" : (home as NSString).appendingPathComponent("Applications")
    }
}
