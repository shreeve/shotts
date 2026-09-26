import AppKit
import ShottsCore
import ShottsUI

/// One capture from key press to editor: pick an area, capture it, edit it, and hand focus back
/// to the app that had it.
final class CaptureFlow {
    private var selection: AreaSelection?
    private var editors: [EditorWindowController] = []
    private var previousApp: NSRunningApplication?

    func begin() {
        guard selection == nil else { return }
        guard ScreenCapture.hasPermission else {
            explainPermission()
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        selection = AreaSelection { [weak self] outcome in
            guard let self else { return }
            selection = nil
            switch outcome {
            case .cancelled:
                restoreFocus()
            case let .selected(screen, rect):
                Task { await self.capture(rect: rect, on: screen) }
            }
        }
        selection?.show()
    }

    private func capture(rect: CGRect, on screen: NSScreen) async {
        // Let the overlay leave the screen before reading it.
        try? await Task.sleep(for: .milliseconds(60))
        do {
            let capture = try await ScreenCapture.capture(rect: rect, on: screen)
            open(capture, on: screen)
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Shotts could not capture the screen"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            restoreFocus()
        }
    }

    func open(_ capture: ScreenCapture.Capture, on screen: NSScreen?) {
        let document = Document(width: capture.image.width, height: capture.image.height, scale: capture.scale)
        let editor = EditorWindowController(document: document, source: capture.image, on: screen)
        editor.onClose = { [weak self, weak editor] in
            self?.editors.removeAll { $0 === editor }
            if self?.editors.isEmpty == true { self?.restoreFocus() }
        }
        editors.append(editor)
        editor.present()
    }

    private func restoreFocus() {
        if let app = previousApp, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            app.activate()
        }
        previousApp = nil
    }

    private func explainPermission() {
        NSApp.activate(ignoringOtherApps: true)
        if ScreenCapture.requestPermission() {
            begin()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Allow Shotts to record the screen"
        alert.informativeText = "Turn on Shotts under System Settings › Privacy & Security › Screen & System Audio Recording, then press F10 again. macOS may ask you to quit and reopen Shotts first."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
