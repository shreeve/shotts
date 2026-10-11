import AppKit

/// An area being captured as it is scrolled: a blue outline just outside it (just inside, for
/// an area that fills its display), and a small panel beside it saying where the capture stands
/// (Shotts scrolling, or the user, how tall the picture is so far), with Done (F10, as it ends
/// a recording too, or Return) and Cancel (Escape). Neither the outline nor the panel is ever in
/// the picture: the capture leaves out `windowNumbers`. The panel takes the keys without
/// bringing Shotts forward, as the picker does, and scrolling goes, as always, to what is under
/// the pointer.
public final class ScrollSetup {
    public enum Outcome { case done, cancelled }

    /// Where the capture stands, as the panel shows it.
    public enum State: Equatable, Sendable {
        /// Shotts scrolling to the bottom.
        case scrolling
        /// Shotts could not follow the area (frames kept not matching, none came, or it is too
        /// short), or macOS gave the mouse back to the user: the user scrolls.
        case gaveUp
        /// Shotts may not scroll other apps until Accessibility allows it: the user scrolls.
        case needsPermission
    }

    /// The area in screen coordinates.
    public let area: CGRect
    /// The area's display, as it is now.
    public private(set) var screen: NSScreen
    /// The display's number and its frame when the capture began.
    private let display: NSNumber?
    private let displayFrame: CGRect
    private let outline: NSWindow
    private let panel: ScrollPanel
    private var completion: ((Outcome) -> Void)?
    private var observer: NSObjectProtocol?

    /// `rect` is in points from the top-left of `screen`, as the picker gives it.
    public init(screen: NSScreen, rect: CGRect, completion: @escaping (Outcome) -> Void) {
        self.screen = screen
        display = Self.number(of: screen)
        displayFrame = screen.frame
        area = CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        self.completion = completion
        outline = RecordingSetup.makeOutline(around: area, on: screen.frame, color: .systemBlue)
        panel = ScrollPanel()
        panel.onFinish = { [weak self] outcome in self?.finish(outcome) }
        place()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged(to: NSScreen.screens) }
        }
    }

    /// The displays changed. With the area's display still where it was, only the room for the
    /// panel may have (the Dock, the menu bar), and it is placed again. Otherwise the outline is
    /// over something else, and the capture ends as Done does, keeping what it has: a display
    /// added or rearranged elsewhere loses nothing.
    func screensChanged(to screens: [NSScreen]) {
        guard let same = screens.first(where: { Self.number(of: $0) == display && $0.frame == displayFrame }) else {
            finish(.done)
            return
        }
        screen = same
        place()
    }

    private static func number(of screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    /// The outline's and the panel's windows, for the capture to leave out.
    public var windowNumbers: Set<Int> { [outline.windowNumber, panel.windowNumber] }

    public func show() {
        outline.orderFrontRegardless()
        panel.orderFrontRegardless()
        panel.makeKey()
        // Nothing focused: with keyboard navigation on, a button would be, its ring around it.
        panel.makeFirstResponder(nil)
    }

    /// Shows where the capture stands.
    public func show(_ state: State) {
        panel.state = state
        refresh()
    }

    /// How tall the picture is so far, in pixels, and how the last frame went: not matched
    /// (scrolled too fast), or the picture as tall as it may be.
    public func showProgress(height: Int, lost: Bool, full: Bool) {
        panel.height = height
        panel.lost = lost
        panel.full = full
        refresh()
    }

    /// The panel's words, and its place only when its size changed: progress comes with every
    /// frame, and a panel left of the area would otherwise shift as the digits change.
    private func refresh() {
        if panel.refresh() { place() }
    }

    /// Takes everything down, without an outcome.
    public func close() {
        completion = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        panel.orderOut(nil)
        outline.orderOut(nil)
    }

    /// Done, as Return or the Done button does.
    public func done() { finish(.done) }

    private func place() {
        panel.setFrameOrigin(RecordingSetup.panelOrigin(size: panel.frame.size, beside: area, on: screen.visibleFrame))
    }

    private func finish(_ outcome: Outcome) {
        guard let completion else { return }
        self.completion = nil
        close()
        completion(outcome)
    }

    #if DEBUG
    /// For tests: the panel, as Return and Escape reach it.
    var scrollPanel: ScrollPanel { panel }
    #endif
}

/// The panel. A non-activating panel, like the recording's, so Shotts stays in the background
/// and nothing on screen moves.
final class ScrollPanel: NSPanel {
    var onFinish: ((ScrollSetup.Outcome) -> Void)?
    let message = NSTextField(labelWithString: "")
    let done = PillButton(title: "Done", symbol: "checkmark", fill: .systemBlue)
    let cancel = PillButton(title: "Cancel", symbol: nil, fill: SetupPanel.plain)
    private let row = NSStackView()
    var state: ScrollSetup.State = .scrolling
    var height = 0, lost = false, full = false

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        appearance = NSAppearance(named: .darkAqua)

        // Digits all of a width: the panel keeps its size as the height counts up.
        message.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        message.textColor = .white
        message.setContentHuggingPriority(.required, for: .horizontal)
        for (button, action, tip) in [(done, #selector(donePressed), "Make the picture (F10)"),
                                      (cancel, #selector(cancelPressed), "Put it away (Escape)")] {
            button.target = self
            button.action = action
            button.toolTip = tip
        }
        done.keyEquivalent = "\r"
        cancel.keyEquivalent = "\u{1b}"
        row.setViews([message, done, cancel], in: .leading)
        row.setCustomSpacing(14, after: message)
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 8)
        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(white: 0.14, alpha: 0.96).cgColor
        background.layer?.cornerRadius = 11
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        background.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            row.topAnchor.constraint(equalTo: background.topAnchor),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background
        refresh()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    @objc func donePressed() { onFinish?(.done) }
    @objc func cancelPressed() { onFinish?(.cancelled) }
    override func cancelOperation(_ sender: Any?) { cancelPressed() }

    /// The words for the state, and the height so far; whether the panel's size changed.
    @discardableResult func refresh() -> Bool {
        let tall = height > 0 ? "   \(height.formatted()) px" : ""
        let words: String
        var warning = false
        switch state {
        case _ where full:
            words = "As tall as it can be: press F10"
        case .scrolling:
            words = "Scrolling; F10 stops"
        case .gaveUp:
            words = "Couldn't follow it: scroll by hand, then press F10"
            warning = true
        case .needsPermission:
            words = lost ? "Scroll a little slower" : "Scroll down, then press F10 (allow Accessibility for Shotts to scroll)"
            warning = lost
        }
        message.stringValue = words + tall
        message.textColor = warning ? .systemYellow : .white
        let size = row.fittingSize
        guard size != frame.size else { return false }
        setContentSize(size)
        return true
    }
}
