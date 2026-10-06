import AppKit
import ShottsCore

/// The area about to be recorded, and then being recorded: a red outline just outside it (just
/// inside, for an area that fills its display), and a small panel beside it (inside its bottom
/// edge, when there is no room beside). Until recording starts the panel has Record, the
/// Microphone, Clicks, and Keys switches, and Cancel; Return records, Escape cancels. Then it has
/// the drawing tools, Pause, and Stop, and a clear layer over the area takes what is drawn and
/// shows clicks and keys. Neither the outline nor the panel is ever in the recording: the
/// recorder leaves out `windowNumbers`. The drawing layer is recorded: it is `keptNumbers`.
public final class RecordingSetup {
    /// What the recording takes besides the screen, chosen with the switches.
    public struct Choices: Equatable, Sendable {
        public var microphone: Bool
        /// A ripple where each click lands.
        public var clicks: Bool
        /// The shortcuts pressed, shown near the area's bottom; typing is not.
        public var keys: Bool

        public init(microphone: Bool = false, clicks: Bool = false, keys: Bool = false) {
            self.microphone = microphone
            self.clicks = clicks
            self.keys = keys
        }
    }

    public enum Outcome {
        case record(Choices)
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
    public init(screen: NSScreen, rect: CGRect, choices: Choices, completion: @escaping (Outcome) -> Void) {
        self.screen = screen
        area = CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        self.completion = completion
        outline = Self.makeOutline(around: area, on: screen.frame)
        drawing = DrawingLayer(area: area, scale: screen.backingScaleFactor)
        let panel = SetupPanel(choices: choices)
        self.panel = panel
        panel.onFinish = { [weak self] outcome in self?.finish(outcome) }
        panel.onControl = { [weak self] control in self?.onControl?(control) }
        panel.onTool = { [weak self] tool in self?.drawing.tool = tool }
        drawing.onToolChange = { [weak panel] tool in panel?.showTool(tool) }
        panel.setFrameOrigin(Self.panelOrigin(size: panel.frame.size, beside: area, on: screen.visibleFrame))
        drawing.keysClearance = Self.clearance(of: panel.frame, in: area)
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
        // Nothing focused: with keyboard navigation on, a button would be, its ring around it.
        panel?.makeFirstResponder(nil)
    }

    /// Recording has started: the panel becomes the recording bar, and the drawing layer goes
    /// over the area, letting clicks through until a tool is on.
    public func recording() {
        drawing.orderFrontRegardless()
        guard let panel else { return }
        panel.showControls()
        panel.setFrameOrigin(Self.panelOrigin(size: panel.frame.size, beside: area, on: screen.visibleFrame))
        drawing.keysClearance = Self.clearance(of: panel.frame, in: area)
    }

    /// A ripple where a click landed, `point` in screen coordinates, if it is in the area.
    public func showClick(at point: CGPoint) { drawing.canvas.showClick(atScreen: point, in: area) }

    /// A shortcut pressed, as `KeystrokeLine.key` names it.
    public func showKey(_ shortcut: String) { drawing.canvas.showKey(shortcut) }

    /// How far above the area's bottom the keys show, clear of a panel inside the area.
    private static func clearance(of panel: CGRect, in area: CGRect) -> CGFloat {
        area.intersects(panel) ? panel.maxY - area.minY + 16 : 28
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
    /// For tests: where the outline's window is.
    var outlineFrame: CGRect { outline.frame }
    #endif

    /// A frame just around the area, clear inside, that lets every click through: a red line
    /// two points wide a point off the area, in a dark band with a faint light edge, so the
    /// area reads as framed on any background.
    static func makeOutline(around area: CGRect, on screen: CGRect, color: NSColor = .systemRed) -> NSWindow {
        // Outside the area when the frame fits on its display; else, as for a whole display,
        // just inside its edge, where it is still left out of the recording.
        let outside = area.insetBy(dx: -OutlineView.width, dy: -OutlineView.width)
        let inward = !screen.contains(outside)
        let window = NSWindow(contentRect: inward ? area : outside, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = OutlineView()
        view.inward = inward
        view.color = color
        window.contentView = view
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

final class OutlineView: NSView {
    /// How far the frame reaches out from the area.
    static let width: CGFloat = 9
    /// The frame inside the area's edge, for an area with no room around it.
    var inward = false
    /// Red while recording; blue while an area is scrolled.
    var color: NSColor = .systemRed

    override func draw(_ dirtyRect: NSRect) {
        if inward {
            color.setStroke()
            let line = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            line.lineWidth = 3
            line.stroke()
            return
        }
        let outer = bounds, inner = bounds.insetBy(dx: Self.width, dy: Self.width)
        // The band, between the area and the frame's outer edge.
        let band = NSBezierPath(rect: outer)
        band.append(NSBezierPath(rect: inner.insetBy(dx: -1, dy: -1)).reversed)
        NSColor(white: 0.08, alpha: 0.5).setFill()
        band.fill()
        NSColor(white: 1, alpha: 0.35).setStroke()
        let edge = NSBezierPath(rect: outer.insetBy(dx: 0.5, dy: 0.5))
        edge.lineWidth = 1
        edge.stroke()
        color.setStroke()
        let line = NSBezierPath(rect: inner.insetBy(dx: -2, dy: -2))
        line.lineWidth = 2
        line.stroke()
    }
}

/// A button Shotts draws itself, alike whether or not its panel is key. The panels belong to an
/// app kept in the background, so nothing on screen moves, and AppKit draws a background app's
/// buttons faded, which on a dark panel is hard to read.
final class PillButton: NSButton {
    var fill: NSColor { didSet { needsDisplay = true } }
    /// The fill while on, for a button that stays pressed.
    var onFill: NSColor?
    /// The symbols for off and on, when they differ.
    var symbols: (off: String, on: String)?

    init(title: String, symbol: String?, fill: NSColor, toggles: Bool = false) {
        self.fill = fill
        super.init(frame: .zero)
        self.title = title
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: title.isEmpty ? symbol : nil) }
        isBordered = false
        setButtonType(toggles ? .pushOnPushOff : .momentaryPushIn)
        if title.isEmpty, let symbol { setAccessibilityLabel(symbol) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var state: NSControl.StateValue {
        didSet {
            if let symbols { image = NSImage(systemSymbolName: state == .on ? symbols.on : symbols.off, accessibilityDescription: nil) }
            needsDisplay = true
        }
    }

    override var isHighlighted: Bool { didSet { needsDisplay = true } }

    /// With keyboard navigation on, the focus ring goes around the pill, not around its title.
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }

    private static let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private static let icon: CGFloat = 18

    override var intrinsicContentSize: NSSize {
        let text = title.isEmpty ? 0 : (title as NSString).size(withAttributes: [.font: Self.font]).width
        let icon: CGFloat = image == nil ? 0 : Self.icon
        let gap: CGFloat = text > 0 && icon > 0 ? 7 : 0
        return NSSize(width: max(text + icon + gap + (title.isEmpty ? 18 : 28), 38), height: 32)
    }

    override func draw(_ dirtyRect: NSRect) {
        var color = state == .on ? (onFill ?? fill) : fill
        if isHighlighted { color = color.blended(withFraction: 0.3, of: .black) ?? color }
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.white]
        let text = title.isEmpty ? .zero : (title as NSString).size(withAttributes: attributes)
        let icon: CGFloat = image == nil ? 0 : Self.icon
        let gap: CGFloat = text.width > 0 && icon > 0 ? 7 : 0
        var x = bounds.midX - (text.width + icon + gap) / 2
        if let image {
            let tinted = image.withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
                .flatMap { $0.withSymbolConfiguration(.init(paletteColors: [.white])) } ?? image
            let size = tinted.size, scale = min(icon / max(size.width, 1), icon / max(size.height, 1), 1)
            let drawn = NSSize(width: size.width * scale, height: size.height * scale)
            tinted.draw(in: NSRect(x: x + (icon - drawn.width) / 2, y: bounds.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
            x += icon + gap
        }
        if !title.isEmpty {
            (title as NSString).draw(at: NSPoint(x: x, y: bounds.midY - text.height / 2), withAttributes: attributes)
        }
    }
}

/// The panel: a non-activating panel, like the picker's windows, so Shotts stays in the
/// background and nothing on screen moves. It starts as the setup (Record, Microphone, Cancel)
/// and becomes the recording bar (Arrow, Rectangle, Pause, Stop).
final class SetupPanel: NSPanel {
    var onFinish: ((RecordingSetup.Outcome) -> Void)?
    var onControl: ((RecordingSetup.Control) -> Void)?
    var onTool: ((DrawingTool?) -> Void)?
    let record = PillButton(title: "Record", symbol: "record.circle", fill: .systemRed)
    let microphone = PillButton(title: "Microphone", symbol: "mic.slash.fill", fill: SetupPanel.plain, toggles: true)
    let clicks = PillButton(title: "Clicks", symbol: "cursorarrow.click", fill: SetupPanel.plain, toggles: true)
    let keys = PillButton(title: "Keys", symbol: "keyboard", fill: SetupPanel.plain, toggles: true)
    let cancel = PillButton(title: "Cancel", symbol: nil, fill: SetupPanel.plain)
    let arrow = PillButton(title: "", symbol: "arrow.up.right", fill: SetupPanel.plain, toggles: true)
    let rectangle = PillButton(title: "", symbol: "rectangle", fill: SetupPanel.plain, toggles: true)
    let pause = PillButton(title: "", symbol: "pause.fill", fill: SetupPanel.plain, toggles: true)
    let stop = PillButton(title: "Stop (F10)", symbol: "stop.fill", fill: .systemRed)
    private let row = NSStackView()
    private(set) var recording = false
    /// A button's fill at rest, and while a toggle is on.
    static let plain = NSColor(white: 0.32, alpha: 1)
    static let on = NSColor(srgbRed: 0.16, green: 0.45, blue: 0.95, alpha: 1)

    init(choices: RecordingSetup.Choices) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        // A level above the drawing layer's, which covers the whole area and takes clicks while
        // a tool is on: a bar inside the area, as for a whole display, stays within reach.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        appearance = NSAppearance(named: .darkAqua)

        record.keyEquivalent = "\r"
        record.target = self
        record.action = #selector(recordPressed)
        record.toolTip = "Start recording (Return)"
        microphone.symbols = ("mic.slash.fill", "mic.fill")
        microphone.onFill = Self.on
        microphone.state = choices.microphone ? .on : .off
        microphone.toolTip = "Record your voice along with the screen"
        clicks.onFill = Self.on
        clicks.state = choices.clicks ? .on : .off
        clicks.toolTip = "Show a ripple where each click lands"
        keys.onFill = Self.on
        keys.state = choices.keys ? .on : .off
        keys.toolTip = "Show the shortcuts you press, such as ⌘C or Return; typing never shows"
        cancel.keyEquivalent = "\u{1b}"
        cancel.target = self
        cancel.action = #selector(cancelPressed)
        cancel.toolTip = "Put it away (Escape)"

        for (button, tip) in [(arrow, "Draw arrows on the recording"), (rectangle, "Draw rectangles on the recording")] {
            button.onFill = Self.on
            button.toolTip = tip + "; each fades after a few seconds"
            button.setAccessibilityLabel(tip)
            button.target = self
            button.action = #selector(toolPressed(_:))
        }
        pause.symbols = ("pause.fill", "play.fill")
        pause.onFill = .systemOrange
        pause.target = self
        pause.action = #selector(pausePressed)
        stop.toolTip = "Stop recording (F10)"
        stop.target = self
        stop.action = #selector(stopPressed)
        showPaused(false)

        row.setViews([record, microphone, clicks, keys, cancel], in: .leading)
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        // Solid, so the buttons read the same over any background.
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
        setContentSize(row.fittingSize)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    @objc func recordPressed() {
        onFinish?(.record(RecordingSetup.Choices(microphone: microphone.state == .on, clicks: clicks.state == .on, keys: keys.state == .on)))
    }
    @objc func cancelPressed() { onFinish?(.cancelled) }

    /// Escape: before recording, Cancel; while recording, the tool off.
    override func cancelOperation(_ sender: Any?) {
        if recording { onTool?(nil) } else { cancelPressed() }
    }

    /// The recording bar, in the setup's place.
    func showControls() {
        recording = true
        row.setViews([arrow, rectangle, pause, stop], in: .leading)
        row.setCustomSpacing(16, after: rectangle)
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
        pause.setAccessibilityLabel(paused ? "Resume" : "Pause")
        pause.toolTip = paused ? "Resume recording" : "Pause recording"
    }
}

#if DEBUG
/// The recording frame and panel drawn off screen over a light page, as they show over most
/// windows, before recording or while it records.
public enum RecordingSetupPreview {
    public static func write(to output: URL, recording: Bool) -> Bool {
        let panel = SetupPanel(choices: RecordingSetup.Choices(microphone: true, clicks: true))
        if recording {
            panel.showControls()
            panel.showTool(.arrow)
        }
        let content = panel.contentView!
        content.layoutSubtreeIfNeeded()
        let frame = OutlineView(frame: CGRect(x: 0, y: 0, width: 320 + OutlineView.width * 2, height: 160 + OutlineView.width * 2))
        let size = CGSize(width: max(frame.bounds.width, content.bounds.width) + 80, height: frame.bounds.height + content.bounds.height + 80)
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.scaleBy(x: scale, y: scale)
        NSColor(white: 0.97, alpha: 1).setFill()
        CGRect(origin: .zero, size: size).fill()
        ("Some text on the page behind" as NSString).draw(at: CGPoint(x: 70, y: size.height - 80), withAttributes: [.font: NSFont.systemFont(ofSize: 15)])
        func place(_ view: NSView, at origin: CGPoint) {
            ctx.cgContext.saveGState()
            ctx.cgContext.translateBy(x: origin.x, y: origin.y)
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                rep.draw(in: view.bounds)
            }
            ctx.cgContext.restoreGState()
        }
        place(frame, at: CGPoint(x: (size.width - frame.bounds.width) / 2, y: size.height - 40 - frame.bounds.height))
        place(content, at: CGPoint(x: (size.width - content.bounds.width) / 2, y: 28))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: output)) != nil
    }
}
#endif
