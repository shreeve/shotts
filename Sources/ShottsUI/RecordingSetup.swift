import AppKit

/// The area about to be recorded, and then being recorded: a red outline just outside it, and
/// a small panel beside it. Until recording starts the panel has Record, the Microphone switch,
/// and Cancel; Return records, Escape cancels. Then it has the drawing tools, Pause, and Stop,
/// and a clear layer over the area takes what is drawn. Neither the outline nor the panel is
/// ever in the recording: the recorder leaves out `windowNumbers`, and both sit outside the
/// area. The drawing layer is recorded: it is `keptNumbers`.
public final class RecordingSetup {
    public enum Outcome {
        case record(microphone: Bool)
        case cancelled
    }

    /// The recording bar's buttons, once recording.
    public enum Control {
        case pause, resume, stop
    }

    public var onControl: ((Control) -> Void)?

    /// The area in screen coordinates.
    public let area: CGRect
    public let screen: NSScreen
    private let outline: NSWindow
    private var panel: SetupPanel?
    let drawing: DrawingLayer
    private var completion: ((Outcome) -> Void)?
    private var observer: NSObjectProtocol?

    /// `rect` is in points from the top-left of `screen`, as the picker gives it.
    public init(screen: NSScreen, rect: CGRect, microphone: Bool, completion: @escaping (Outcome) -> Void) {
        self.screen = screen
        area = CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        self.completion = completion
        outline = Self.makeOutline(around: area)
        drawing = DrawingLayer(area: area, scale: screen.backingScaleFactor)
        let panel = SetupPanel(microphone: microphone)
        self.panel = panel
        panel.onFinish = { [weak self] outcome in self?.finish(outcome) }
        panel.onControl = { [weak self] control in self?.onControl?(control) }
        panel.onTool = { [weak self] tool in self?.drawing.tool = tool }
        drawing.onToolChange = { [weak panel] tool in panel?.showTool(tool) }
        panel.setFrameOrigin(Self.panelOrigin(size: panel.frame.size, beside: area, on: screen.visibleFrame))
        // The area's display going, or the displays rearranging, leaves the outline over nothing.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.cancelled) }
        }
    }

    /// The drawing layer's window, for the recorder to keep though it floats as the others do.
    public var keptNumbers: Set<Int> { [drawing.windowNumber] }

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

    /// Recording has started: the panel becomes the recording bar, and the drawing layer goes
    /// over the area, letting clicks through until a tool is on.
    public func recording() {
        drawing.orderFrontRegardless()
        guard let panel else { return }
        panel.showControls()
        panel.setFrameOrigin(Self.panelOrigin(size: panel.frame.size, beside: area, on: screen.visibleFrame))
    }

    /// The recording bar shows it paused, or not.
    public func showPaused(_ paused: Bool) { panel?.showPaused(paused) }

    /// Takes everything down, without an outcome.
    public func close() {
        completion = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        panel?.orderOut(nil)
        panel = nil
        drawing.tool = nil
        drawing.orderOut(nil)
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
/// background and nothing on screen moves. It starts as the setup (Record, Microphone, Cancel)
/// and becomes the recording bar (Arrow, Rectangle, Pause, Stop).
final class SetupPanel: NSPanel {
    var onFinish: ((RecordingSetup.Outcome) -> Void)?
    var onControl: ((RecordingSetup.Control) -> Void)?
    var onTool: ((DrawingTool?) -> Void)?
    let microphone: NSButton
    let record: NSButton
    let arrow = NSButton()
    let rectangle = NSButton()
    let pause = NSButton()
    let stop = NSButton()
    private let row = NSStackView()
    private(set) var recording = false

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

        for (button, symbol, tip) in [(arrow, "arrow.up.right", "Draw arrows on the recording"),
                                      (rectangle, "rectangle", "Draw rectangles on the recording")] {
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .texturedRounded
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.toolTip = tip + "; each fades after a few seconds"
            button.target = self
            button.action = #selector(toolPressed(_:))
        }
        pause.setButtonType(.pushOnPushOff)
        pause.bezelStyle = .texturedRounded
        pause.target = self
        pause.action = #selector(pausePressed)
        stop.title = "Stop"
        stop.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        stop.imagePosition = .imageLeading
        stop.bezelStyle = .rounded
        stop.toolTip = "Stop recording (F10)"
        stop.target = self
        stop.action = #selector(stopPressed)
        showPaused(false)

        row.setViews([record, microphone, cancel], in: .leading)
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

    /// Escape: before recording, Cancel; while recording, the tool off.
    override func cancelOperation(_ sender: Any?) {
        if recording { onTool?(nil) } else { cancelPressed() }
    }

    /// The recording bar, in the setup's place.
    func showControls() {
        recording = true
        let divider = NSBox()
        divider.boxType = .separator
        row.setViews([arrow, rectangle, divider, pause, stop], in: .leading)
        row.spacing = 8
        setContentSize(row.fittingSize)
    }

    /// One tool at a time; pressing the one on turns it off.
    @objc func toolPressed(_ sender: NSButton) {
        let tool: DrawingTool? = sender.state == .on ? (sender === arrow ? .arrow : .rectangle) : nil
        onTool?(tool)
    }

    /// The buttons as the drawing layer's tool is, whichever turned it on or off.
    func showTool(_ tool: DrawingTool?) {
        arrow.state = tool == .arrow ? .on : .off
        rectangle.state = tool == .rectangle ? .on : .off
    }

    @objc func pausePressed() { onControl?(pause.state == .on ? .pause : .resume) }
    @objc func stopPressed() { onControl?(.stop) }

    func showPaused(_ paused: Bool) {
        pause.state = paused ? .on : .off
        pause.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: paused ? "Resume" : "Pause")
        pause.toolTip = paused ? "Resume recording" : "Pause recording"
    }
}
