import AppKit
import AVKit
import ShottsCore
import UniformTypeIdentifiers

/// The window a recording opens in once it stops: a bar of export settings above a player,
/// and a timeline below it that plays, and trims what the files keep.
/// The window always holds the file its settings make, made again in the background whenever
/// they change, so its size shows exactly and Copy, Save, and a drag use it at once. Closing
/// the window deletes the recording and every file made from it.
public final class RecordingWindowController: NSWindowController, NSWindowDelegate {
    public let recording: Recording
    public let contents: RecordingExport.Contents
    public var onClose: (() -> Void)?
    /// The pasteboard Copy writes to: the general one, or a private one in tests.
    var pasteboard: NSPasteboard = .general

    /// Each format keeps its own settings, so switching between them and back loses nothing.
    private var settings: [RecordingSettings.Format: RecordingSettings]
    private(set) var format: RecordingSettings.Format = .mp4
    var current: RecordingSettings { settings[format]! }

    /// The file for `current`, once made.
    private(set) var file: URL?
    private var making: Task<Void, Never>?
    private var waiting: [(URL) -> Void] = []

    let player = AVPlayerView()
    let timeline: Timeline
    private var timeObserver: Any?
    /// Setting up the player, which closing stops.
    private var loading: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    let formats = NSPopUpButton()
    let sizes = NSPopUpButton()
    let rates = NSPopUpButton()
    let sounds = NSPopUpButton()
    let status = NSTextField(labelWithString: "")
    let progress = NSProgressIndicator()
    private var grip: RecordingGrip!
    private var bar: NSStackView!

    public init(recording: Recording, contents: RecordingExport.Contents, on screen: NSScreen? = NSScreen.main) {
        self.recording = recording
        self.contents = contents
        settings = [
            .mp4: RecordingRule.defaults(for: .mp4, scale: recording.scale, hasMicrophone: contents.hasMicrophone),
            .gif: RecordingRule.defaults(for: .gif, scale: recording.scale, hasMicrophone: contents.hasMicrophone),
        ]
        timeline = Timeline(duration: contents.duration)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = (Self.fileName(for: recording, format: .mp4) as NSString).deletingPathExtension
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        grip = RecordingGrip(controller: self)
        window.contentView = makeContent()

        // The video at the size it had on screen, or smaller to fit, and never so narrow the
        // bar is cut off.
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let bar = self.bar.fittingSize
        let chrome = bar.height + Self.timelineHeight
        let points = CGSize(width: Double(recording.width) / recording.scale, height: Double(recording.height) / recording.scale)
        let fit = min(1, visible.width * 0.9 / points.width, (visible.height * 0.9 - chrome) / points.height)
        let video = CGSize(width: (points.width * fit).rounded(), height: (points.height * fit).rounded())
        window.setContentSize(CGSize(width: max(video.width, bar.width), height: video.height + chrome))
        window.contentMinSize = CGSize(width: bar.width, height: chrome + 120)
        window.initialFirstResponder = timeline.track
        window.center()

        loadPlayer()
        showSettings()
        remake()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public func present() {
        Front.bringShotts()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout

    private func makeContent() -> NSView {
        formats.addItems(withTitles: ["MP4", "GIF"])
        formats.item(at: 0)?.toolTip = "H.264 video, which plays nearly everywhere"
        formats.item(at: 1)?.toolTip = "An animated GIF: loops, silent, 256 colors"
        formats.target = self
        formats.action = #selector(formatChanged)

        for percent in RecordingRule.sizes {
            sizes.addItem(withTitle: "\(percent)%")
            sizes.lastItem?.tag = percent
        }
        sizes.target = self
        sizes.action = #selector(sizeChanged)

        rates.target = self
        rates.action = #selector(rateChanged)
        rates.toolTip = "Frames a second"
        sounds.target = self
        sounds.action = #selector(soundChanged)
        sounds.toolTip = "Sound"

        status.textColor = .secondaryLabelColor
        status.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        progress.style = .bar
        progress.controlSize = .small
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let copy = NSButton(title: "Copy", target: self, action: #selector(copyPressed))
        copy.keyEquivalent = "c"
        copy.keyEquivalentModifierMask = .command
        let save = NSButton(title: "Save…", target: self, action: #selector(savePressed))
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [formats, sizes, rates, sounds, spacer, progress, status, grip, copy, save])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        // The timeline below is the player's only control.
        player.controlsStyle = .none
        // The bar across the top and the player filling the rest, pinned edge to edge: the
        // player's own idea of its size, which it takes from the video once loaded, never wins.
        for view in [player as NSView] {
            view.setContentHuggingPriority(.init(1), for: .horizontal)
            view.setContentHuggingPriority(.init(1), for: .vertical)
            view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            view.setContentCompressionResistancePriority(.init(1), for: .vertical)
        }
        let content = NSView()
        for view in [bar, player, timeline] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            player.topAnchor.constraint(equalTo: bar.bottomAnchor),
            player.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            player.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            player.bottomAnchor.constraint(equalTo: timeline.topAnchor),
            timeline.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            timeline.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            timeline.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            timeline.heightAnchor.constraint(equalToConstant: Self.timelineHeight),
        ])
        timeline.play.target = self
        timeline.play.action = #selector(togglePlaying)
        timeline.track.onToggle = { [weak self] in self?.togglePlaying() }
        timeline.track.onSeek = { [weak self] time in self?.seek(to: time) }
        timeline.track.onTrim = { [weak self] trim, done in self?.trimmed(trim, done: done) }
        self.bar = bar
        return content
    }

    private static let timelineHeight: CGFloat = 40

    /// `Shotts Recording 2026-09-30 at 2.15.00 PM.mp4`, from when it was recorded.
    static func fileName(for recording: Recording, format: RecordingSettings.Format) -> String {
        Export.suggestedName(date: recording.started, prefix: "Shotts Recording", fileExtension: format.fileExtension)
    }

    /// Plays the video with every sound it has, the microphone's file alongside.
    private func loadPlayer() {
        let recording = recording
        loading = Task {
            let composition = AVMutableComposition()
            let movie = AVURLAsset(url: recording.movie)
            var sources: [(AVAsset, AVMediaType)] = [(movie, .video), (movie, .audio)]
            if let url = recording.microphone { sources.append((AVURLAsset(url: url), .audio)) }
            for (asset, type) in sources {
                guard let track = try? await asset.loadTracks(withMediaType: type).first,
                      let range = try? await track.load(.timeRange),
                      let added = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { continue }
                try? added.insertTimeRange(range, of: track, at: .zero)
            }
            guard !Task.isCancelled else { return }
            let item = AVPlayerItem(asset: composition)
            let playing = AVPlayer(playerItem: item)
            player.player = playing
            let timeline = timeline
            timeObserver = playing.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { time in
                MainActor.assumeIsolated { timeline.playhead = time.seconds }
            }
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { _ in
                MainActor.assumeIsolated { timeline.showPlaying(false) }
            }
        }
    }

    // MARK: - Playing and trimming

    /// Plays the part kept, from its start again once it has played to its end.
    @objc func togglePlaying() {
        guard let playing = player.player else { return }
        if playing.rate != 0 {
            playing.pause()
            timeline.showPlaying(false)
            return
        }
        let trim = timeline.track.trim
        if timeline.playhead >= trim.end - 0.05 || timeline.playhead < trim.start { seek(to: trim.start) }
        playing.play()
        timeline.showPlaying(true)
    }

    private func seek(to time: Double) {
        timeline.playhead = time
        player.player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Playing stops at the trim's end as it is dragged; the files follow once the drag ends,
    /// for every format, since what to keep is the same whatever it is saved as.
    func trimmed(_ trim: Trim, done: Bool) {
        player.player?.pause()
        timeline.showPlaying(false)
        player.player?.currentItem?.forwardPlaybackEndTime = CMTime(seconds: trim.end, preferredTimescale: 600)
        guard done else { return }
        let kept = trim.isWhole(contents.duration) ? nil : trim
        guard kept != current.trim else { return }
        for format in settings.keys { settings[format]?.trim = kept }
        remake()
    }

    // MARK: - Settings

    /// The controls, from `current`.
    private func showSettings() {
        let s = current
        formats.selectItem(at: s.format == .mp4 ? 0 : 1)
        sizes.selectItem(withTag: s.percent)
        // The pixels, for anyone who wants them.
        for item in sizes.itemArray {
            let size = RecordingRule.size(percent: item.tag, format: s.format, recorded: (recording.width, recording.height))
            item.toolTip = "\(size.width) × \(size.height) pixels"
        }
        sizes.toolTip = sizes.selectedItem?.toolTip.map { "Size: \($0)" }

        rates.removeAllItems()
        for rate in RecordingRule.frameRates(for: s.format) {
            rates.addItem(withTitle: "\(rate) fps")
            rates.lastItem?.tag = rate
        }
        rates.selectItem(withTag: s.frameRate)

        sounds.removeAllItems()
        var choices: [(RecordingSettings.Sound, String)] = [(.none, "No Sound")]
        if contents.hasSystemSound { choices.append((.system, "Mac Sound")) }
        if contents.hasMicrophone { choices.append((.microphone, "Microphone")) }
        if contents.hasSystemSound, contents.hasMicrophone { choices.append((.both, "Mac Sound and Microphone")) }
        for (sound, title) in choices {
            sounds.addItem(withTitle: title)
            sounds.lastItem?.representedObject = sound.rawValue
        }
        sounds.selectItem(at: choices.firstIndex { $0.0 == s.sound } ?? 0)
        // A GIF has no sound, and a recording with none has nothing to choose.
        sounds.isHidden = s.format == .gif || choices.count == 1
    }

    private func change(_ edit: (inout RecordingSettings) -> Void) {
        var s = current
        edit(&s)
        guard s != current else { showSettings(); return }
        settings[format] = s
        showSettings()
        remake()
    }

    @objc func formatChanged() {
        format = formats.indexOfSelectedItem == 1 ? .gif : .mp4
        showSettings()
        remake()
    }

    @objc func sizeChanged() { change { $0.percent = sizes.selectedTag() } }
    @objc func rateChanged() { change { $0.frameRate = rates.selectedTag() } }
    @objc func soundChanged() {
        change { s in
            if let raw = sounds.selectedItem?.representedObject as? String, let sound = RecordingSettings.Sound(rawValue: raw) { s.sound = sound }
        }
    }

    // MARK: - The file

    /// Makes the file for the settings as they are now, in a folder of its own so a file still
    /// being made for earlier settings never meets it. Files made before stay until the window
    /// closes, so one already copied or dragged still pastes.
    private func remake() {
        making?.cancel()
        file = nil
        grip.isEnabled = false
        let settings = current
        let name = Self.fileName(for: recording, format: settings.format)
        let folder = recording.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(name)
        status.stringValue = "Making \(settings.format == .mp4 ? "MP4" : "GIF")…"
        progress.doubleValue = 0
        progress.isHidden = false
        let recording = recording, bar = progress
        making = Task {
            // A moment's wait, so typing a width or stepping through rates makes one file.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await RecordingExport.write(recording, settings: settings, to: url) { fraction in
                    DispatchQueue.main.async { MainActor.assumeIsolated { bar.doubleValue = fraction } }
                }
                guard !Task.isCancelled, settings == current else { throw CancellationError() }
                made(url)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                guard !(error is CancellationError), !Task.isCancelled else { return }
                // A Copy or Save waiting for this file is dropped rather than run later by surprise.
                waiting = []
                NSSound.beep()
                progress.isHidden = true
                // What went wrong, short enough for the bar; all of it on hover.
                status.stringValue = "Could not make the file: \(error.localizedDescription)"
                status.lineBreakMode = .byTruncatingTail
                status.toolTip = (error as NSError).description
            }
        }
    }

    private func made(_ url: URL) {
        file = url
        grip.isEnabled = true
        progress.isHidden = true
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        status.stringValue = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        status.toolTip = nil
        let ready = waiting
        waiting = []
        ready.forEach { $0(url) }
    }

    /// Runs `action` with the file, now or once it is made.
    private func withFile(_ action: @escaping (URL) -> Void) {
        if let file { action(file) } else { waiting.append(action) }
    }

    /// The file itself on the pasteboard, as the Finder copies files: it pastes into Messages,
    /// Mail, and Slack as the video or GIF. What is copied is a copy of its own, outside the
    /// recording's folder, so it still pastes after this window closes; one at a time is kept,
    /// as with a drag from the editor.
    @objc public func copyPressed() {
        withFile { [weak self] url in
            guard let self else { return }
            do {
                let copy = try Export.temporaryFolder("Shotts Copied").appendingPathComponent(url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: copy)
                pasteboard.clearContents()
                pasteboard.writeObjects([copy as NSURL])
            } catch {
                NSSound.beep()
            }
        }
    }

    /// Save…: the file copied where the user says, off the main thread, since a long recording
    /// can be a large file. A file already there is replaced only once the copy has worked.
    @objc public func savePressed() {
        guard let window else { return }
        let settings = current
        let panel = NSSavePanel()
        panel.allowedContentTypes = [settings.format == .mp4 ? .mpeg4Movie : .gif]
        panel.nameFieldStringValue = Self.fileName(for: recording, format: settings.format)
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            withFile { url in
                Task {
                    do {
                        try await Task.detached(priority: .userInitiated) { try Self.copy(url, to: destination) }.value
                    } catch {
                        NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
                    }
                }
            }
        }
    }

    /// Copies `url` to `destination` beside it first, then swaps it in, so a failed copy leaves
    /// whatever was there.
    nonisolated static func copy(_ url: URL, to destination: URL) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: destination.path) else { return try files.copyItem(at: url, to: destination) }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)-\(destination.lastPathComponent)")
        try files.copyItem(at: url, to: staged)
        do {
            _ = try files.replaceItemAt(destination, withItemAt: staged)
        } catch {
            try? files.removeItem(at: staged)
            throw error
        }
    }

    // MARK: - Closing

    public func windowWillClose(_ notification: Notification) {
        making?.cancel()
        loading?.cancel()
        player.player?.pause()
        if let timeObserver { player.player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        player.player = nil
        Recording.removeFolder(recording.folder)
        let done = onClose
        onClose = nil
        done?()
    }

    /// Escape closes the window, as it does the editor's with nothing to cancel.
    public override func cancelOperation(_ sender: Any?) {
        window?.performClose(nil)
    }
}

/// The handle you drag the file out by. It works from the first press even while another app
/// is in front, and only once the file is made.
final class RecordingGrip: NSImageView {
    private weak var controller: RecordingWindowController?

    init(controller: RecordingWindowController) {
        self.controller = controller
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "hand.draw", accessibilityDescription: "Drag out")
        toolTip = "Drag the file into another app"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Drag the file into another app")
        widthAnchor.constraint(equalToConstant: 28).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let file = controller?.file else { return }
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: file.path)
        item.setDraggingFrame(NSRect(origin: convert(event.locationInWindow, from: nil), size: NSSize(width: 64, height: 64)), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self).animatesToStartingPositionsOnCancelOrFail = true
    }
}

extension RecordingGrip: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
