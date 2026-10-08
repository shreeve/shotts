import AppKit
import AVFoundation
import ScreenCaptureKit
import ShottsCore
import ShottsUI

/// One capture from key press to editor: picture every display, pick an area on it, cut it
/// out, edit it, and hand focus back to the app that had it. Or, with Command held as the drag
/// ends, a recording of the area: set up, recorded, and opened in a window of its own.
final class CaptureFlow {
    /// The capture under way, from the hot key until its editor opens or it ends. There is one
    /// at a time: the hot key does nothing while the picker is up, a window is being captured,
    /// or an alert is open.
    private var capture: Capture?
    /// The open editors, each with the app it gives focus back to when it closes.
    private var editors: [(editor: EditorWindowController, returnTo: NSRunningApplication?)] = []
    /// The editor closed last, as it was: Option-F10 opens it again. Only this one capture is
    /// kept after its editor closes, until another editor closes and takes its place.
    private var lastClosed: (document: Document, source: CGImage)?
    /// The recording being set up or made, from Command-release until it stops.
    private var recording: RecordingSession?
    /// The open recording windows.
    private var recordings: [RecordingWindowController] = []
    /// A scrolling capture under way, from Option-release until Done or Cancel.
    private var scrolling: ScrollSession?

    private struct ScrollSession {
        var setup: ScrollSetup
        var capture: ScrollCapture
        /// Shotts scrolling, when Accessibility allows, until the bottom or it gives up.
        var auto: AutoScroller?
        /// The app in front when the hot key fired, for a capture cancelled.
        var frontmost: NSRunningApplication?
        /// The app the editor gives focus back to.
        var returnTo: NSRunningApplication?
    }
    /// Tells the menu bar item when a recording starts, with its recorder, and stops, with nil.
    var onRecording: ((Recorder?) -> Void)?
    /// A stopped recording's files are being finished; its window opens next.
    private var finishing = false

    /// Whether a recording is being made, which quitting would lose. One being finished is not:
    /// stopping again would do nothing, and refusing to quit then could leave Shotts unquittable.
    var isRecording: Bool { recording?.recorder != nil }

    /// Whether a recording is being set up, made, or finished: `shotts` waits its turn.
    var isBusyRecording: Bool { recording != nil || finishing }

    private struct RecordingSession {
        var setup: RecordingSetup
        /// Set once recording has started.
        var recorder: Recorder?
        /// The app in front when the hot key fired, for a recording cancelled before it starts.
        var frontmost: NSRunningApplication?
        /// The app the recording's window gives focus back to.
        var returnTo: NSRunningApplication?
        /// Clicks and keys, while a recording that shows them runs.
        var inputs: InputWatcher?
    }

    private struct Capture {
        /// The app in front when the hot key fired, Shotts itself when an editor was: a capture
        /// that ends without an editor leaves focus there.
        var frontmost: NSRunningApplication?
        /// The app this capture's editor gives focus back to; never Shotts.
        var returnTo: NSRunningApplication?
        /// The picker, which calls back once, to nothing, unless someone holds it.
        var selection: AreaSelection?
        /// The displays, streaming while the picker is up.
        var displays: [LiveDisplay] = []
    }

    /// F10: a capture, or while recording, the end of the recording. Nothing while a capture or
    /// a recording is being set up.
    func begin() {
        if recording?.recorder != nil { stopRecording(); return }
        // While an area is scrolled, F10 is Done.
        if let scrolling { scrolling.setup.done(); return }
        guard capture == nil, recording == nil, !finishing else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        capture = Capture(frontmost: frontmost, returnTo: appToReturnTo(from: frontmost))
        guard ScreenCapture.hasPermission else {
            askPermission()
            return
        }
        // The picker goes up at once over the live screen; the streams it reads start behind it,
        // leaving its own windows out.
        let displays = LiveDisplay.all()
        capture?.displays = displays
        let selection = select(from: displays)
        for display in displays { display.onInterrupted = { [weak selection] in selection?.cancel() } }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                for display in displays { try await display.start(in: content, excluding: selection.windowNumbers) }
            } catch {
                selection.cancel()
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

    private func select(from displays: [LiveDisplay]) -> AreaSelection {
        let selection = AreaSelection(displays: displays.map(\.display)) { [weak self] outcome in
            guard let self else { return }
            let live = capture?.displays ?? []
            switch outcome {
            case .cancelled:
                live.forEach { $0.stop() }
                end()
            case let .selected(display, rect):
                // Cut from the frame at the moment of release, then stop streaming.
                Task {
                    _ = await live.first { $0.display === display }?.firstFrame()
                    let image = display.cut(rect)
                    live.forEach { $0.stop() }
                    // Nothing to cut (no frame came in time): say so rather than nothing.
                    guard let image else { NSSound.beep(); self.end(); return }
                    self.deliver(image, scale: display.scale, on: display.screen)
                }
            case let .record(display, rect):
                live.forEach { $0.stop() }
                setUpRecording(on: display.screen, rect: rect)
            case let .scroll(display, rect):
                live.forEach { $0.stop() }
                setUpScroll(on: display, rect: rect)
            case let .window(display, window):
                // The window on its own, whatever covered it. If it has gone meanwhile, the
                // area it occupied on the display stands in.
                Task {
                    let captured = (try? await ScreenCapture.captureWindow(window.id, shadow: SelectionOptions.current.dropShadow))
                        ?? display.cut(window.frame).map { ($0, display.scale) }
                    live.forEach { $0.stop() }
                    guard let (image, scale) = captured else { NSSound.beep(); end(); return }
                    deliver(image, scale: scale, on: display.screen)
                }
            }
        }
        capture?.selection = selection
        selection.show()
        return selection
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
        open(Document(width: image.width, height: image.height, scale: scale), source: image, on: screen, returningTo: returnTo)
    }

    /// Unless New Window per Capture is on, the new editor takes the place of the open one in
    /// front, where it was on screen; the one replaced becomes the capture Option-F10 brings back.
    private func open(_ document: Document, source: CGImage, on screen: NSScreen?, returningTo returnTo: NSRunningApplication?) {
        let editor = EditorWindowController(document: document, source: source, on: screen)
        editor.onClose = { [weak self, weak editor] in
            let working = editor?.window?.isKeyWindow ?? false
            if let editor { self?.keepAsLast(editor) }
            self?.editors.removeAll { $0.editor === editor }
            if working { Front.giveBack(to: returnTo) }
        }
        // The editor in front is the one replaced, else the newest.
        let front = NSApp.orderedWindows.lazy.compactMap { window in self.editors.firstIndex { $0.editor.window === window } }.first
        if !SelectionOptions.current.newWindows, let index = front ?? editors.indices.last, let window = editor.window {
            let (replaced, _) = editors.remove(at: index)
            // Replaced, not closed by the user: it goes quietly, with no focus handed back.
            replaced.onClose = { [weak self] in self?.keepAsLast(replaced) }
            if let old = replaced.window {
                // Where the old one was, its top-left corner kept, and still on screen if the
                // new picture is bigger.
                window.setFrameTopLeftPoint(CGPoint(x: old.frame.minX, y: old.frame.maxY))
                window.setFrame(window.constrainFrameRect(window.frame, to: old.screen), display: false)
            }
            replaced.close()
        }
        editors.append((editor, returnTo))
        editor.present()
    }

    // MARK: - Scrolling capture

    /// Set once macOS's own Accessibility dialog has been shown for scrolling, which it shows once.
    private static let askedScrollingKey = "scroll.askedAccessibility"

    /// The area, from a drag that ended blue (Option pressed during it), outlined in blue with a
    /// panel beside it. It streams at once, each frame stitched as it comes. With Accessibility,
    /// Shotts puts the pointer in the middle of the area and scrolls what is under it to the
    /// bottom, then opens the picture; without it (macOS asks once), the user scrolls and presses
    /// Return.
    private func setUpScroll(on display: DisplayImage, rect: CGRect) {
        let frontmost = capture?.frontmost, returnTo = capture?.returnTo
        capture = nil
        let screen = display.screen
        let scroller = ScrollCapture(scale: display.scale)
        let setup = ScrollSetup(screen: screen, rect: rect) { [weak self] outcome in
            switch outcome {
            case .done: self?.finishScroll()
            case .cancelled: self?.cancelScroll()
            }
        }
        var auto: AutoScroller?
        if AutoScroller.allowed {
            let area = setup.area
            let primary = NSScreen.screens.first?.frame.maxY ?? area.maxY
            let middle = CGPoint(x: area.midX, y: primary - area.midY)
            CGWarpMouseCursorPosition(middle)
            let autoScroller = AutoScroller(areaHeight: area.height, pointer: middle)
            // At the bottom, the picture opens; unable to follow, the user scrolls.
            autoScroller.onFinish = { [weak setup] in setup?.done() }
            autoScroller.onGiveUp = { [weak self, weak setup] in
                self?.scrolling?.auto = nil
                setup?.show(.gaveUp)
            }
            auto = autoScroller
            setup.show(.scrolling)
        } else {
            if !UserDefaults.standard.bool(forKey: Self.askedScrollingKey) {
                UserDefaults.standard.set(true, forKey: Self.askedScrollingKey)
                AutoScroller.ask()
            }
            setup.show(.needsPermission)
        }
        scroller.onProgress = { [weak self, weak setup] height, lost, full in
            setup?.showProgress(height: height, lost: lost, full: full)
            self?.scrolling?.auto?.progress(height: height, lost: lost, full: full)
        }
        // The display going ends it with what was taken.
        scroller.onInterrupted = { [weak setup] in setup?.done() }
        scrolling = ScrollSession(setup: setup, capture: scroller, auto: auto, frontmost: frontmost, returnTo: returnTo)
        setup.show()
        Task {
            do {
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                    throw ScreenCapture.Failure.noDisplay
                }
                try await scroller.start(display: number.uint32Value, rect: rect, excluding: setup.windowNumbers)
                // It waits for the first frame before counting anything against the bottom.
                scrolling?.auto?.start()
            } catch {
                cancelScroll()
                fail("Shotts could not capture the screen", error)
            }
        }
    }

    /// Done, Return, F10, or the bottom reached: the stitched picture opens in an editor, as any
    /// capture does.
    private func finishScroll() {
        guard let session = scrolling else { return }
        scrolling = nil
        session.auto?.stop()
        session.setup.close()
        Task {
            guard let image = await session.capture.finish() else {
                NSSound.beep()
                Front.giveBack(to: session.frontmost)
                return
            }
            let scale = session.capture.scale
            if SelectionOptions.current.copiesOnCapture { Export.copyInBackground(image, scale: scale) }
            open(image: image, scale: scale, on: session.setup.screen, returningTo: session.returnTo)
        }
    }

    /// Cancel or Escape: nothing is kept, and focus goes back to the app that had it.
    private func cancelScroll() {
        guard let session = scrolling else { return }
        scrolling = nil
        session.auto?.stop()
        session.setup.close()
        Task { await session.capture.cancel() }
        Front.giveBack(to: session.frontmost)
    }

    // MARK: - Recording

    private static let microphoneKey = "recording.microphone"
    private static let clicksKey = "recording.clicks"
    private static let keysKey = "recording.keys"
    /// Set once macOS's own Input Monitoring dialog has been shown, which it shows only once.
    private static let askedKeysKey = "recording.askedInputMonitoring"

    /// The area outlined, with Record, the Microphone, Clicks, and Keys switches as last set, and
    /// Cancel beside it; nothing records yet.
    private func setUpRecording(on screen: NSScreen, rect: CGRect) {
        let frontmost = capture?.frontmost, returnTo = capture?.returnTo
        capture = nil
        let d = UserDefaults.standard
        let last = RecordingSetup.Choices(microphone: d.bool(forKey: Self.microphoneKey), clicks: d.bool(forKey: Self.clicksKey),
                                          keys: d.bool(forKey: Self.keysKey))
        let setup = RecordingSetup(screen: screen, rect: rect, choices: last) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .cancelled:
                cancelRecording()
            case let .record(choices):
                d.set(choices.microphone, forKey: Self.microphoneKey)
                d.set(choices.clicks, forKey: Self.clicksKey)
                d.set(choices.keys, forKey: Self.keysKey)
                Task { await self.startRecording(on: screen, rect: rect, choices: choices) }
            }
        }
        recording = RecordingSession(setup: setup, frontmost: frontmost, returnTo: returnTo)
        setup.show()
    }

    private func startRecording(on screen: NSScreen, rect: CGRect, choices wanted: RecordingSetup.Choices) async {
        guard let setup = recording?.setup else { return }
        var microphone = wanted.microphone
        if microphone, !(await Self.microphoneAllowed()) {
            switch askAboutMicrophone() {
            case .withoutIt: microphone = false
            case .cancel: cancelRecording(); return
            }
        }
        var keys = wanted.keys
        if keys, !InputWatcher.keysAllowed {
            if !UserDefaults.standard.bool(forKey: Self.askedKeysKey) {
                // The first time, macOS's own dialog asks, and points to the setting; this
                // recording goes ahead without keys, which show once Shotts is allowed.
                UserDefaults.standard.set(true, forKey: Self.askedKeysKey)
                InputWatcher.askForKeys()
                keys = false
            } else {
                switch askAboutKeys() {
                case .withoutIt: keys = false
                case .cancel: cancelRecording(); return
                }
            }
        }
        let recorder = Recorder()
        recorder.onInterrupted = { [weak self] in self?.stopRecording() }
        do {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { throw ScreenCapture.Failure.noDisplay }
            try await recorder.start(display: number.uint32Value, scale: screen.backingScaleFactor, rect: rect,
                                     excluding: setup.windowNumbers, keeping: setup.keptNumbers, microphone: microphone)
        } catch {
            _ = try? await recorder.stop()
            cancelRecording()
            fail("Shotts could not record the screen", error)
            return
        }
        guard recording != nil else { _ = try? await recorder.stop(); return }
        recording?.recorder = recorder
        setup.onControl = { [weak self, weak setup, weak recorder] control in
            guard let self, let setup, let recorder else { return }
            switch control {
            case .pause: recorder.pause()
            case .resume: recorder.resume()
            case .stop: stopRecording()
            }
            setup.showPaused(recorder.isPaused)
        }
        setup.recording()
        if wanted.clicks || keys {
            recording?.inputs = InputWatcher(clicks: wanted.clicks, keys: keys,
                                             onClick: { [weak setup] point in setup?.showClick(at: point) },
                                             onKey: { [weak setup] key in setup?.showKey(key) })
        }
        onRecording?(recorder)
    }

    /// Takes the outline and panel down and leaves focus with the app that had it.
    private func cancelRecording() {
        let app = recording?.frontmost
        recording?.inputs?.stop()
        recording?.setup.close()
        recording = nil
        Front.giveBack(to: app)
    }

    /// F10, or the menu bar timer: the recording ends and opens in its window.
    func stopRecording() {
        guard let session = recording, let recorder = session.recorder else { return }
        recording = nil
        finishing = true
        onRecording?(nil)
        session.inputs?.stop()
        session.setup.close()
        Task {
            defer { finishing = false }
            do {
                let made = try await recorder.stop()
                do {
                    let contents = try await RecordingExport.contents(of: made)
                    openRecording(made, contents: contents, on: session.setup.screen, returningTo: session.returnTo)
                } catch {
                    Recording.removeFolder(made.folder)
                    throw error
                }
            } catch {
                fail("Shotts could not finish the recording", error)
            }
        }
    }

    private func openRecording(_ made: Recording, contents: RecordingExport.Contents, on screen: NSScreen, returningTo returnTo: NSRunningApplication?) {
        let window = RecordingWindowController(recording: made, contents: contents, on: screen)
        window.onClose = { [weak self, weak window] in
            let working = window?.window?.isKeyWindow ?? false
            self?.recordings.removeAll { $0 === window }
            if working { Front.giveBack(to: returnTo) }
        }
        recordings.append(window)
        window.present()
    }

    /// Whether Shotts may use the microphone, asking macOS the first time.
    static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    private enum MicrophoneAnswer { case withoutIt, cancel }

    /// Input Monitoring is off for Shotts: record without keys, or go and turn it on.
    private func askAboutKeys() -> MicrophoneAnswer {
        Front.bringShotts()
        let alert = NSAlert()
        alert.messageText = "Shotts can't see the keys you press"
        alert.informativeText = "Turn on Shotts under System Settings › Privacy & Security › Input Monitoring, then record again. macOS may ask you to quit and reopen Shotts first."
        alert.addButton(withTitle: "Record Without Keys")
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .withoutIt
        case .alertSecondButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { NSWorkspace.shared.open(url) }
            return .cancel
        default:
            return .cancel
        }
    }

    /// The microphone is turned off for Shotts: record without it, or go and turn it on.
    private func askAboutMicrophone() -> MicrophoneAnswer {
        Front.bringShotts()
        let alert = NSAlert()
        alert.messageText = "Shotts can't use the microphone"
        alert.informativeText = "Turn on Shotts under System Settings › Privacy & Security › Microphone, then record again."
        alert.addButton(withTitle: "Record Without Microphone")
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .withoutIt
        case .alertSecondButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
            return .cancel
        default:
            return .cancel
        }
    }

    /// A closed editor becomes the capture Option-F10 brings back, as `Document.keepsAsLast` says.
    private func keepAsLast(_ editor: EditorWindowController) {
        let document = editor.canvas.document
        guard Document.keepsAsLast(document, over: lastClosed?.document) else { return }
        lastClosed = (document, editor.canvas.source)
    }

    /// Whether Option-F10 has anything to show.
    var hasLastCapture: Bool { !editors.isEmpty || lastClosed != nil }

    /// What quitting now would lose: open captures annotated or cropped, and recordings not yet
    /// saved, copied, or dragged out.
    var unsavedWork: (captures: Int, recordings: Int) {
        (editors.filter { $0.editor.canvas.document.isEdited }.count, recordings.filter { !$0.kept }.count)
    }

    /// Option-F10: the newest open editor, brought to the front; else the editor closed last,
    /// opened again as it was, its annotations still editable.
    func showLast() {
        if let editor = editors.last?.editor {
            editor.present()
        } else if let (document, source) = lastClosed {
            lastClosed = nil
            open(document, source: source, on: NSScreen.main, returningTo: appToReturnTo())
        } else {
            NSSound.beep()
        }
    }

    /// Ends a capture that opened no editor, leaving focus with the app that had it.
    private func end() {
        let app = capture?.frontmost
        capture = nil
        Front.giveBack(to: app)
    }

    private func fail(_ message: String, _ error: Error) {
        Front.bringShotts()
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
        Front.bringShotts()
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
