import AppKit
import ShottsCore

/// What can be drawn on an area while it records.
public enum DrawingTool: Sendable {
    case arrow, rectangle
}

/// A clear window exactly over the area being recorded, which is recorded with it. With a
/// tool on, a drag draws an arrow or a rectangle in the editor's last style, drawn by the same
/// renderer; each stays four seconds, then fades over one. With no tool on, every click goes
/// through to what is underneath. It also shows, when asked, a ripple where each click lands
/// and the keys pressed.
final class DrawingLayer: NSPanel {
    let canvas: DrawingCanvas

    /// `area` in screen coordinates; `scale` is its display's.
    init(area: CGRect, scale: Double) {
        canvas = DrawingCanvas(size: area.size, scale: scale)
        super.init(contentRect: area, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        contentView = canvas
        canvas.onToolOff = { [weak self] in self?.tool = nil }
    }

    override var canBecomeKey: Bool { tool != nil }
    override var canBecomeMain: Bool { false }

    /// The tool on, if any: with none, the layer lets every click through.
    var tool: DrawingTool? {
        didSet {
            canvas.tool = tool
            ignoresMouseEvents = tool == nil
            if tool != nil { makeKey() }
            invalidateCursorRects(for: canvas)
            onToolChange?(tool)
        }
    }

    /// Tells the bar when the tool goes off by itself, as Escape does.
    var onToolChange: ((DrawingTool?) -> Void)?

    /// How far above the area's bottom the keys show.
    var keysClearance: CGFloat {
        get { canvas.keysClearance }
        set { canvas.keysClearance = newValue }
    }
}

final class DrawingCanvas: NSView {
    private let document: Document
    private let style: Style
    var tool: DrawingTool?
    var onToolOff: (() -> Void)?
    /// The shapes showing, each with when it was drawn.
    private(set) var shapes: [(annotation: Annotation, drawn: Date)] = []
    private var dragging: (anchor: CGPoint, annotation: Annotation)?
    private var fading: Timer?
    /// A shape shows fully this long, then fades out over `fade`.
    static let hold: TimeInterval = 4, fade: TimeInterval = 1
    /// Stands in for a source picture: nothing drawn here reads one.
    private static let noPicture: CGImage = {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }()

    init(size: CGSize, scale: Double) {
        document = Document(width: max(Int(size.width * scale), 1), height: max(Int(size.height * scale), 1), scale: scale)
        style = EditorWindowController.rememberedStyle
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
    }

    // MARK: - Clicks and keys

    /// How far above the area's bottom the keys show.
    var keysClearance: CGFloat = 28 { didSet { placeKeys() } }
    private var line = KeystrokeLine()
    private var keysBadge: KeysBadge?
    private var keysTimer: Timer?

    /// A ripple at `point` (screen coordinates) if it is inside `area`, the window's frame: a
    /// soft yellow disc that swells and fades, with a ring, over half a second.
    func showClick(atScreen point: CGPoint, in area: CGRect) {
        guard area.contains(point), let layer else { return }
        let p = CGPoint(x: point.x - area.minX, y: area.maxY - point.y)
        let ripple = CAShapeLayer()
        let radius: CGFloat = 26
        ripple.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        ripple.position = p
        ripple.fillColor = NSColor.systemYellow.withAlphaComponent(0.35).cgColor
        ripple.strokeColor = NSColor.systemYellow.cgColor
        ripple.lineWidth = 3
        ripple.opacity = 0
        layer.addSublayer(ripple)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.3
        grow.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.95
        fade.toValue = 0
        let both = CAAnimationGroup()
        both.animations = [grow, fade]
        both.duration = 0.5
        both.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ripple.removeFromSuperlayer() }
        ripple.add(both, forKey: "ripple")
        CATransaction.commit()
    }

    /// A key pressed: it joins the line showing if it came soon enough after the last, and the
    /// line goes once no key has come for `KeystrokeLine.linger`.
    func showKey(_ key: KeystrokeLine.Key) {
        let now = ProcessInfo.processInfo.systemUptime
        line.add(key, at: now)
        let badge = keysBadge ?? {
            let badge = KeysBadge()
            addSubview(badge)
            keysBadge = badge
            return badge
        }()
        badge.text = line.text
        badge.alphaValue = 1
        placeKeys()
        keysTimer?.invalidate()
        // Each key starts it again, so when it fires the line has lingered its while since the last.
        let timer = Timer(timeInterval: KeystrokeLine.linger, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    self.keysBadge?.animator().alphaValue = 0
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        keysTimer = timer
    }

    /// The keys centered near the bottom, clear of a panel inside the area.
    private func placeKeys() {
        guard let badge = keysBadge else { return }
        let size = badge.fittingSize
        let width = min(size.width, bounds.width - 16)
        badge.frame = CGRect(x: (bounds.width - width) / 2, y: bounds.height - keysClearance - size.height, width: width, height: size.height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if tool != nil { addCursorRect(bounds, cursor: .crosshair) }
    }

    /// A point in the view as the document's pixels.
    private func pixel(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * document.scale, y: p.y * document.scale) }

    override func mouseDown(with event: NSEvent) { pressed(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) {
        dragged(to: convert(event.locationInWindow, from: nil), square: event.modifierFlags.contains(.shift))
    }
    override func mouseUp(with event: NSEvent) { released() }

    /// `p` in the view's points.
    func pressed(at p: CGPoint) {
        guard tool != nil else { return }
        dragging = (pixel(p), Annotation(shape: .rectangle(CGRect(origin: pixel(p), size: .zero)), style: style))
    }

    func dragged(to p: CGPoint, square: Bool = false) {
        guard let tool, let anchor = dragging?.anchor else { return }
        let point = pixel(p)
        let shape: Annotation.Shape = switch tool {
        case .arrow: .arrow(from: anchor, to: point)
        case .rectangle: .rectangle(SelectionRule.rect(anchor: anchor, pointer: point, square: square))
        }
        dragging?.annotation = Annotation(shape: shape, style: style)
        needsDisplay = true
    }

    /// The shape stays, unless it is too small to see, and starts its time.
    func released(at date: Date = .now) {
        guard let (_, annotation) = dragging else { return }
        dragging = nil
        if !annotation.isDegenerate(in: document.pixelBounds) { shapes.append((annotation, date)) }
        needsDisplay = true
        startFading()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape: the tool goes off
            dragging = nil
            needsDisplay = true
            onToolOff?()
        } else {
            super.keyDown(with: event)
        }
    }

    /// How opaque a shape drawn at `drawn` is at `now`.
    static func opacity(drawn: Date, now: Date) -> Double {
        let age = now.timeIntervalSince(drawn)
        return age <= hold ? 1 : max(0, 1 - (age - hold) / fade)
    }

    /// Redraws as shapes fade, and drops each once it is gone; stops when none is left.
    private func startFading() {
        guard fading == nil, !shapes.isEmpty else { return }
        let timer = Timer(timeInterval: 1.0 / 30, target: self, selector: #selector(fade), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        fading = timer
    }

    @objc func fade() {
        let now = Date.now
        let before = shapes.count
        shapes.removeAll { Self.opacity(drawn: $0.drawn, now: now) <= 0 }
        if shapes.contains(where: { Self.opacity(drawn: $0.drawn, now: now) < 1 }) || shapes.count != before { needsDisplay = true }
        if shapes.isEmpty {
            fading?.invalidate()
            fading = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(dirtyRect)
        ctx.saveGState()
        ctx.scaleBy(x: 1 / document.scale, y: 1 / document.scale)
        let now = Date.now
        for (annotation, drawn) in shapes {
            ctx.saveGState()
            ctx.setAlpha(Self.opacity(drawn: drawn, now: now))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            Renderer.draw(annotation, document: document, source: Self.noPicture, in: ctx, baseScale: 1 / document.scale)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        if let annotation = dragging?.annotation {
            Renderer.draw(annotation, document: document, source: Self.noPicture, in: ctx, baseScale: 1 / document.scale)
        }
        ctx.restoreGState()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            fading?.invalidate()
            fading = nil
            keysTimer?.invalidate()
            keysTimer = nil
        }
    }
}

/// The keys pressed, white on a dark rounded plate, as a keystroke display shows them.
final class KeysBadge: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.82).cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        let font = NSFont.systemFont(ofSize: 30, weight: .semibold)
        label.font = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 30) } ?? font
        label.textColor = .white
        label.lineBreakMode = .byTruncatingHead
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
