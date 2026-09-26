import AppKit
import ShottsCore
import ShottsUI

/// One capture from key press to editor: picture every display, pick an area on it, cut it
/// out, edit it, and hand focus back to the app that had it.
final class CaptureFlow {
    private var selection: AreaSelection?
    private var editors: [EditorWindowController] = []
    private var previousApp: NSRunningApplication?
    private var capturing = false

    func begin() {
        guard selection == nil, !capturing else { return }
        guard ScreenCapture.hasPermission else {
            explainPermission()
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        capturing = true
        Task {
            defer { capturing = false }
            do {
                let displays = try await ScreenCapture.captureDisplays()
                select(from: displays)
            } catch {
                fail("Shotts could not capture the screen", error)
            }
        }
    }

    private func select(from displays: [DisplayImage]) {
        selection = AreaSelection(displays: displays) { [weak self] outcome in
            guard let self else { return }
            selection = nil
            switch outcome {
            case .cancelled:
                restoreFocus()
            case let .selected(display, rect):
                let pixels = SelectionRule.pixelRect(rect, scale: display.scale,
                                                     within: CGRect(x: 0, y: 0, width: display.image.width, height: display.image.height))
                guard !pixels.isEmpty, let image = display.image.cropping(to: pixels) else {
                    restoreFocus()
                    return
                }
                if SelectionOptions.current.copiesOnCapture {
                    // The plain capture is on the clipboard at once; Copy in the editor replaces
                    // it with the annotated one.
                    _ = Export.copy(Document(width: image.width, height: image.height, scale: display.scale), source: image)
                }
                open(image: image, scale: display.scale, on: display.screen)
            }
        }
        selection?.show()
    }

    func open(image: CGImage, scale: CGFloat, on screen: NSScreen?) {
        let document = Document(width: image.width, height: image.height, scale: scale)
        let editor = EditorWindowController(document: document, source: image, on: screen)
        editor.onClose = { [weak self, weak editor] in
            self?.editors.removeAll { $0 === editor }
            if self?.editors.isEmpty == true { self?.restoreFocus() }
        }
        editors.append(editor)
        editor.present()
    }

    private func fail(_ message: String, _ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.runModal()
        restoreFocus()
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
