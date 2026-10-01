import AppKit
import ShottsCore

/// What can be drawn on an area while it records.
public enum DrawingTool: Sendable {
    case arrow, rectangle
}

/// A clear window exactly over the area being recorded, which is recorded with it. With a
/// tool on, a drag draws an arrow or a rectangle in the editor's last style, drawn by the same
/// renderer; each stays four seconds, then fades over one. With no tool on, every click goes
/// through to what is underneath.
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
        }
    }
}
