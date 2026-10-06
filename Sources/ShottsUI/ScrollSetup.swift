import AppKit

/// An area being captured as the user scrolls what is in it: a blue outline just outside it
/// (just inside, for an area that fills its display), and a small panel beside it that says to
/// scroll, how tall the picture is so far, and Done or Cancel; Return is Done, Escape cancels.
/// Neither is ever in the picture: the capture leaves out `windowNumbers`. The panel takes the
/// keys without bringing Shotts forward, as the picker does, and scrolling goes, as always, to
/// what is under the pointer.
public final class ScrollSetup {
    public enum Outcome { case done, cancelled }

    /// The area in screen coordinates.
    public let area: CGRect
    public let screen: NSScreen
    private let outline: NSWindow
    private let panel: ScrollPanel
    private var completion: ((Outcome) -> Void)?
    private var observer: NSObjectProtocol?

    /// `rect` is in points from the top-left of `screen`, as the picker gives it.
    public init(screen: NSScreen, rect: CGRect, completion: @escaping (Outcome) -> Void) {
        self.screen = screen
        area = CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        self.completion = completion
        outline = RecordingSetup.makeOutline(around: area, on: screen.frame, color: .systemBlue)
        panel = ScrollPanel()
        panel.onFinish = { [weak self] outcome in self?.finish(outcome) }
        place()
        // The area's display going, or the displays rearranging, leaves the outline over nothing.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.cancelled) }
        }
    }

    /// Shotts scrolls, rather than the user: the panel says to wait, or Return to stop early.
    public var automatic: Bool {
        get { panel.automatic }
        set {
            panel.automatic = newValue
            panel.show(height: 0, lost: false, full: false)
            place()
        }
    }

    /// The outline's and the panel's windows, for the capture to leave out.
    public var windowNumbers: Set<Int> { [outline.windowNumber, panel.windowNumber] }

    public func show() {
        outline.orderFrontRegardless()
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    /// How tall the picture is so far, in pixels, and how the last frame went: matched, not
    /// matched (scrolled too fast), or as tall as it may be.
    public func showProgress(height: Int, lost: Bool, full: Bool) {
        panel.show(height: height, lost: lost, full: full)
        place()
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

/// The panel: what to do, the height so far, Done, and Cancel. A non-activating panel, like the
/// recording's, so Shotts stays in the background and nothing on screen moves.
final class ScrollPanel: NSPanel {
    var onFinish: ((ScrollSetup.Outcome) -> Void)?
    let message = NSTextField(labelWithString: "")
    let done = PillButton(title: "Done", symbol: "checkmark", fill: .systemBlue)
    let cancel = PillButton(title: "Cancel", symbol: nil, fill: SetupPanel.plain)
    private let row = NSStackView()
    /// Shotts scrolls, rather than the user.
    var automatic = false

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

        message.font = .systemFont(ofSize: 14, weight: .medium)
        message.textColor = .white
        message.setContentHuggingPriority(.required, for: .horizontal)
        done.keyEquivalent = "\r"
        done.target = self
        done.action = #selector(donePressed)
        done.toolTip = "Make the picture (Return)"
        cancel.keyEquivalent = "\u{1b}"
        cancel.target = self
        cancel.action = #selector(cancelPressed)
        cancel.toolTip = "Put it away (Escape)"

        row.setViews([message, done, cancel], in: .leading)
        row.orientation = .horizontal
        row.spacing = 8
        row.setCustomSpacing(14, after: message)
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
        show(height: 0, lost: false, full: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    @objc func donePressed() { onFinish?(.done) }
    @objc func cancelPressed() { onFinish?(.cancelled) }
    override func cancelOperation(_ sender: Any?) { cancelPressed() }

    /// What to do next, and the height so far.
    func show(height: Int, lost: Bool, full: Bool) {
        let tall = height > 0 ? "   \(height.formatted()) px" : ""
        message.stringValue = full ? "As tall as it can be: press Return" + tall
            : automatic ? "Scrolling to the bottom; Return stops" + tall
            : lost ? "Scroll a little slower" + tall
            : "Scroll down, then press Return" + tall
        message.textColor = lost && !full && !automatic ? .systemYellow : .white
        setContentSize(row.fittingSize)
    }
}
