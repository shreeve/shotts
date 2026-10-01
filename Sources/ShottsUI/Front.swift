import AppKit

/// The one way Shotts comes to the front, and the one way it hands focus back. A menu bar app
/// (`LSUIElement`) is not active when its windows appear, and on macOS 27 the plain
/// `NSApp.activate()` is refused for it, so every activation is `activate(ignoringOtherApps:)`
/// (HANDOFF, Traps). Activating brings all of an app's windows forward, which is why the
/// picker never calls this.
public enum Front {
    public static func bringShotts() {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Gives focus back to `app`, unless it is Shotts itself.
    public static func giveBack(to app: NSRunningApplication?) {
        guard let app, app.processIdentifier != NSRunningApplication.current.processIdentifier else { return }
        app.activate()
    }
}
