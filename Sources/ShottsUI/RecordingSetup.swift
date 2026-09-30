import AppKit

/// The area about to be recorded, and then being recorded: a red outline just outside it, and
/// until recording starts, a small panel beside it with Record, the Microphone switch, and
/// Cancel. Return records, Escape cancels. Neither the outline nor the panel is ever in the
/// recording: the recorder leaves out `windowNumbers`, and both sit outside the area.
public final class RecordingSetup {
    public enum Outcome {
        case record(microphone: Bool)
        case cancelled
    }

    /// The area in screen coordinates.
    public let area: CGRect
    public let screen: NSScreen
    private let outline: NSWindow
    private var panel: SetupPanel?
    private var completion: ((Outcome) -> Void)?
    private var observer: NSObjectProtocol?

    /// `rect` is in points from the top-left of `screen`, as the picker gives it.
    public init(screen: NSScreen, rect: CGRect, microphone: Bool, completion: @escaping (Outcome) -> Void) {
        self.screen = screen
        area = CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        self.completion = completion
        outline = Self.makeOutline(around: area)
        let panel = SetupPanel(microphone: microphone)
        self.panel = panel
        panel.onFinish = { [weak self] outcome in self?.finish(outcome) }
        panel.setFrameOrigin(Self.panelOrigin(size: panel.frame.size, beside: area, on: screen.visibleFrame))
        // The area's display going, or the displays rearranging, leaves the outline over nothing.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.cancelled) }
        }
    }

    /// The outline's and the panel's windows, for the recorder to leave out.
    public var windowNumbers: Set<Int> {
        var numbers: Set<Int> = [outline.windowNumber]
        if let panel { numbers.insert(panel.windowNumber) }
        return numbers
    }

    /// Shows the outline and the panel, which takes Return and Escape without bringing Shotts
    /// forward, as the picker does.
    public func show() {
        outline.orderFrontRegardless()
        panel?.orderFrontRegardless()
        panel?.makeKey()
    }

    /// Recording has started: the panel goes, the outline stays.
    public func recording() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Takes everything down, without an outcome.
    public func close() {
        completion = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        panel?.orderOut(nil)
        panel = nil
        outline.orderOut(nil)
    }

    private func finish(_ outcome: Outcome) {
        guard let completion else { return }
        self.completion = nil
        if case .cancelled = outcome { close() }
        completion(outcome)
    }

    #if DEBUG
    /// For tests: the panel, as Return and Escape and the switch reach it.
    var setupPanel: SetupPanel? { panel }
    #endif

    /// A window just around the area, clear inside, that draws a red line two points wide
    /// with a point of space between it and the area, and lets every click through.
    private static func makeOutline(around area: CGRect) -> NSWindow {
        let window = NSWindow(contentRect: area.insetBy(dx: -3, dy: -3), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = OutlineView()
        return window
    }

    /// Below the area and centered on it; above it when there is no room below; inside its
    /// bottom edge when there is room on neither side. Always on the screen.
    static func panelOrigin(size: CGSize, beside area: CGRect, on visible: CGRect) -> CGPoint {
        let gap: CGFloat = 12
        var y = area.minY - gap - size.height
        if y < visible.minY { y = area.maxY + gap }
        if y + size.height > visible.maxY { y = max(visible.minY, area.minY + gap) }
        let x = min(max(area.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        return CGPoint(x: x, y: y)
    }
}

private final class OutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
    }
}

/// The panel: a non-activating panel, like the picker's windows, so Shotts stays in the
/// background and nothing on screen moves before the recording starts.
final class SetupPanel: NSPanel {
    var onFinish: ((RecordingSetup.Outcome) -> Void)?
    let microphone: NSButton
    let record: NSButton

    init(microphone on: Bool) {
        record = NSButton(title: "Record", target: nil, action: nil)
        microphone = NSButton(checkboxWithTitle: "Microphone", target: nil, action: nil)
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

        record.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.white, .systemRed]))
        record.imagePosition = .imageLeading
        record.bezelStyle = .rounded
        record.keyEquivalent = "\r"
        record.target = self
        record.action = #selector(recordPressed)
        record.toolTip = "Start recording (Return)"
        microphone.state = on ? .on : .off
        microphone.toolTip = "Record your voice along with the screen"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.toolTip = "Put it away (Escape)"

        let row = NSStackView(views: [record, microphone, cancel])
        row.orientation = .horizontal
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            row.topAnchor.constraint(equalTo: background.topAnchor),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background
        setContentSize(row.fittingSize)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    @objc func recordPressed() { onFinish?(.record(microphone: microphone.state == .on)) }
    @objc func cancelPressed() { onFinish?(.cancelled) }

    override func cancelOperation(_ sender: Any?) { cancelPressed() }
}
