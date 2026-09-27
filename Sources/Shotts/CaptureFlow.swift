import AppKit
import ShottsCore
import ShottsUI

/// One capture from key press to editor: picture every display, pick an area on it, cut it
/// out, edit it, and hand focus back to the app that had it.
final class CaptureFlow {
    /// The capture under way, from the hot key until its editor opens or it ends. There is one
    /// at a time: the hot key does nothing while the picker is up, a window is being captured,
    /// or an alert is open.
    private var capture: Capture?
    /// The open editors, each with the app it gives focus back to when it closes.
    private var editors: [(editor: EditorWindowController, returnTo: NSRunningApplication?)] = []

    private struct Capture {
        /// The app in front when the hot key fired, Shotts itself when an editor was: a capture
        /// that ends without an editor leaves focus there.
        var frontmost: NSRunningApplication?
        /// The app this capture's editor gives focus back to; never Shotts.
        var returnTo: NSRunningApplication?
        /// The picker, which calls back once, to nothing, unless someone holds it.
        var selection: AreaSelection?
    }

    func begin() {
        guard capture == nil else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        capture = Capture(frontmost: frontmost, returnTo: appToReturnTo(from: frontmost))
        guard ScreenCapture.hasPermission else {
            askPermission()
            return
        }
        Task {
            do {
                select(from: try await ScreenCapture.captureDisplays())
            } catch {
                fail("Shotts could not capture the screen", error)
            }
        }
    }

    /// The app an editor opened now should give focus back to: `app`, unless that is Shotts
    /// itself because one of its editors is in front, in which case the app that editor goes
    /// back to.
    func appToReturnTo(from app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) -> NSRunningApplication? {
        guard app?.processIdentifier == NSRunningApplication.current.processIdentifier else { return app }
        return (editors.first { $0.editor.window?.isKeyWindow == true } ?? editors.last)?.returnTo
    }

    private func select(from displays: [DisplayImage]) {
        let selection = AreaSelection(displays: displays) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .cancelled:
                end()
            case let .selected(display, rect):
                guard let image = display.cut(rect) else { end(); return }
                deliver(image, scale: display.scale, on: display.screen)
            case let .window(display, window):
                // The window on its own, whatever covered it. If it has gone meanwhile, the
                // area it occupied in the display picture stands in.
                Task {
                    let captured = (try? await ScreenCapture.captureWindow(window.id, shadow: SelectionOptions.current.dropShadow))
                        ?? display.cut(window.frame).map { ($0, display.scale) }
                    guard let (image, scale) = captured else { end(); return }
                    deliver(image, scale: scale, on: display.screen)
                }
            }
        }
        capture?.selection = selection
        selection.show()
    }

    private func deliver(_ image: CGImage, scale: CGFloat, on screen: NSScreen) {
        let returnTo = capture?.returnTo
        capture = nil
        if SelectionOptions.current.copiesOnCapture {
            // The plain capture reaches the clipboard once it is encoded, off the main thread so
            // the editor opens at once; a Copy from the editor made before then is left alone.
            Export.copyInBackground(image, scale: scale)
        }
        open(image: image, scale: scale, on: screen, returningTo: returnTo)
    }

    /// Opens `image` in an editor that, when it closes as the window being worked in, gives focus
    /// back to `returnTo`. One closing in the background (Close All) leaves focus where it is.
    func open(image: CGImage, scale: CGFloat, on screen: NSScreen?, returningTo returnTo: NSRunningApplication?) {
        let document = Document(width: image.width, height: image.height, scale: scale)
        let editor = EditorWindowController(document: document, source: image, on: screen)
        editor.onClose = { [weak self, weak editor] in
            let working = editor?.window?.isKeyWindow ?? false
            self?.editors.removeAll { $0.editor === editor }
            if working { returnTo?.activate() }
        }
        editors.append((editor, returnTo))
        editor.present()
    }

    /// Ends a capture that opened no editor, leaving focus with the app that had it.
    private func end() {
        let app = capture?.frontmost
        capture = nil
        if let app, app.processIdentifier != NSRunningApplication.current.processIdentifier { app.activate() }
    }

    private func fail(_ message: String, _ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.runModal()
        end()
    }

    /// Without Screen Recording permission, the first press shows only the system's own prompt,
    /// which macOS shows once. Later presses explain where to turn it on.
    private func askPermission() {
        let asked = "capture.askedPermission"
        guard UserDefaults.standard.bool(forKey: asked) else {
            UserDefaults.standard.set(true, forKey: asked)
            ScreenCapture.requestPermission()
            capture = nil
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow Shotts to record the screen"
        alert.informativeText = "Turn on Shotts under System Settings › Privacy & Security › Screen & System Audio Recording, then press F10 again. macOS may ask you to quit and reopen Shotts first."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            capture = nil
            NSWorkspace.shared.open(url)
        } else {
            end()
        }
    }
}
