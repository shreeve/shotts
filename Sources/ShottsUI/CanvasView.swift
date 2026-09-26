import AppKit
import ShottsCore

public enum Tool: Int, CaseIterable, Sendable {
    case select, arrow, text, rectangle, ellipse, pen, highlighter, obscure, crop

    public var title: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .text: "Text"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .obscure: "Obscure"
        case .crop: "Crop"
        }
    }

    public var key: String {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .text: "t"
        case .rectangle: "r"
        case .ellipse: "e"
        case .pen: "p"
        case .highlighter: "h"
        case .obscure: "o"
        case .crop: "c"
        }
    }

    public var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .obscure: "eye.slash"
        case .crop: "crop"
        }
    }
}

/// The picture being edited, drawn by `Renderer`, with the mouse turning into annotations.
/// The view's coordinates are image pixels times `zoom`, flipped, so converting a mouse point
/// to the image is one division.
public final class CanvasView: NSView {
    public private(set) var history: History<Document>
    public let source: CGImage
    public var zoom: CGFloat
    public var tool: Tool = .arrow { didSet { selectedID = nil; needsDisplay = true; resetCursorRects(); onToolChange?(tool) } }
    public var onToolChange: ((Tool) -> Void)?
    public var style: Style = .standard {
        didSet {
            // Restyle the selected annotation, so picking a color recolors what is selected.
            if let id = selectedID, var a = document.annotation(id) {
                a.style = style
                var d = document
                d.replace(a)
                commit(d)
            }
        }
    }
    public var onChange: (() -> Void)?

    public var document: Document { history.current }
    public private(set) var selectedID: Annotation.ID?

    private var live: Annotation?          // the shape being dragged out
    private var liveCrop: CGRect?
    private var dragAnchor: CGPoint?
    private var dragOriginal: Annotation?
    private var textField: TextEntry?

    /// The dark field around the picture, and the room its shadow needs.
    public static let inset: CGFloat = 28

    public init(document: Document, source: CGImage, zoom: CGFloat) {
        history = History(document)
        self.source = source
        self.zoom = zoom
        super.init(frame: CGRect(x: 0, y: 0, width: CGFloat(document.width) * zoom + Self.inset * 2,
                                 height: CGFloat(document.height) * zoom + Self.inset * 2))
        wantsLayer = true
    }

    /// Where the picture sits in the view, in points: centered, on the field.
    public var pictureRect: CGRect {
        let size = CGSize(width: CGFloat(document.width) * zoom, height: CGFloat(document.height) * zoom)
        return CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: Self.inset, width: size.width, height: size.height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var intrinsicContentSize: NSSize { frame.size }

    public override func resetCursorRects() {
        addCursorRect(pictureRect, cursor: tool == .select ? .arrow : .crosshair)
    }

    public override func layout() {
        super.layout()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Editing

    public func commit(_ document: Document) {
        history.push(document)
        needsDisplay = true
        onChange?()
    }

    @objc public func undo(_ sender: Any?) {
        endTextEntry(commit: true)
        history.undo(); selectedID = nil; needsDisplay = true; onChange?()
    }

    @objc public func redo(_ sender: Any?) {
        endTextEntry(commit: true)
        history.redo(); selectedID = nil; needsDisplay = true; onChange?()
    }

    @objc public func delete(_ sender: Any?) {
        guard let id = selectedID else { return }
        var d = document
        d.remove(id)
        selectedID = nil
        commit(d)
    }

    public override func selectAll(_ sender: Any?) {}

    /// Escape: an entry or drag in progress, then the selection.
    public func cancelCurrent() -> Bool {
        if textField != nil { endTextEntry(commit: false); return true }
        if live != nil || liveCrop != nil { live = nil; liveCrop = nil; dragAnchor = nil; needsDisplay = true; return true }
        if selectedID != nil { selectedID = nil; needsDisplay = true; return true }
        return false
    }

    /// One unmodified key picks a tool, as in most annotation editors: V select, A arrow,
    /// T text, R rectangle, E ellipse, P pen, H highlighter, O obscure, C crop.
    public override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased(),
              let tool = Tool.allCases.first(where: { $0.key == key }) else {
            super.keyDown(with: event)
            return
        }
        self.tool = tool
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let picture = pictureRect
        return CGPoint(x: (p.x - picture.minX) / zoom, y: (p.y - picture.minY) / zoom)
    }

    private func viewRect(_ r: CGRect) -> CGRect {
        let picture = pictureRect
        return CGRect(x: r.minX * zoom + picture.minX, y: r.minY * zoom + picture.minY, width: r.width * zoom, height: r.height * zoom)
    }

    private var hitTolerance: Double { 6 / zoom }

    // MARK: - Mouse

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        endTextEntry(commit: true)
        let p = imagePoint(event)
        dragAnchor = p
        switch tool {
        case .select:
            selectedID = HitTest.annotation(at: p, in: document, tolerance: hitTolerance)
            dragOriginal = selectedID.flatMap { document.annotation($0) }
            if event.clickCount == 2, let a = dragOriginal, case let .text(origin, string, _) = a.shape {
                var d = document
                d.remove(a.id)
                commit(d)
                beginTextEntry(at: origin, initial: string, style: a.style)
            }
        case .text:
            beginTextEntry(at: p, initial: "", style: style)
        case .arrow:
            live = Annotation(shape: .arrow(from: p, to: p), style: style)
        case .rectangle:
            live = Annotation(shape: .rectangle(CGRect(origin: p, size: .zero)), style: style)
        case .ellipse:
            live = Annotation(shape: .ellipse(CGRect(origin: p, size: .zero)), style: style)
        case .obscure:
            live = Annotation(shape: .obscure(CGRect(origin: p, size: .zero)), style: style)
        case .pen:
            live = Annotation(shape: .pen([p]), style: style)
        case .highlighter:
            live = Annotation(shape: .highlighter([p]), style: style)
        case .crop:
            liveCrop = CGRect(origin: p, size: .zero)
        }
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(event)
        guard let anchor = dragAnchor else { return }
        let shift = event.modifierFlags.contains(.shift)
        switch tool {
        case .select:
            if let original = dragOriginal {
                var d = document
                d.replace(original.translated(by: p - anchor))
                history = History(history: history, replacingCurrent: d)
            }
        case .arrow:
            live?.shape = .arrow(from: anchor, to: p)
        case .rectangle:
            live?.shape = .rectangle(SelectionRule.rect(anchor: anchor, pointer: p, square: shift))
        case .ellipse:
            live?.shape = .ellipse(SelectionRule.rect(anchor: anchor, pointer: p, square: shift))
        case .obscure:
            live?.shape = .obscure(SelectionRule.rect(anchor: anchor, pointer: p, square: shift))
        case .pen:
            if case let .pen(points) = live?.shape { live?.shape = .pen(points + [p]) }
        case .highlighter:
            if case let .highlighter(points) = live?.shape { live?.shape = .highlighter(points + [p]) }
        case .crop:
            liveCrop = SelectionRule.rect(anchor: anchor, pointer: p, square: shift).intersection(document.pixelBounds)
        case .text:
            break
        }
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        defer { dragAnchor = nil; dragOriginal = nil; live = nil; liveCrop = nil; needsDisplay = true }
        switch tool {
        case .select:
            // The drag edited the current state in place; make it an undo step against the
            // state before the drag.
            if let original = dragOriginal, let moved = document.annotation(original.id), moved != original {
                var before = document
                before.replace(original)
                history = History(history: history, replacingCurrent: before)
                var after = before
                after.replace(moved)
                commit(after)
            }
        case .crop:
            if let rect = liveCrop, SelectionRule.isUsable(rect) {
                var d = document
                d.setCrop(rect)
                commit(d)
            }
        default:
            if let live, !live.isDegenerate {
                var d = document
                d.add(live)
                commit(d)
            }
        }
    }

    // MARK: - Text entry

    private func beginTextEntry(at origin: CGPoint, initial: String, style: Style) {
        let field = TextEntry(frame: .zero)
        field.font = Renderer.font(for: style, scale: document.scale * zoom)
        field.textColor = NSColor(cgColor: Renderer.cgColor(style.color))
        field.stringValue = initial
        field.style = style
        field.origin = origin
        field.onCommit = { [weak self] commit in self?.endTextEntry(commit: commit) }
        field.sizeToFit()
        let pad = Renderer.outlineWidth(style, scale: document.scale) * zoom
        field.frame.origin = CGPoint(x: origin.x * zoom + pictureRect.minX + pad, y: origin.y * zoom + pictureRect.minY)
        field.frame.size.width = max(field.frame.width, 40)
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
        // Editing existing text continues at its end rather than replacing it.
        field.currentEditor()?.selectedRange = NSRange(location: (initial as NSString).length, length: 0)
    }

    func endTextEntry(commit: Bool) {
        guard let field = textField else { return }
        textField = nil
        let string = field.stringValue
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        guard commit, !string.isEmpty, let origin = field.origin, let style = field.style else { return }
        let size = Renderer.textSize(string, style: style, scale: document.scale)
        var d = document
        d.add(Annotation(shape: .text(origin: origin, string: string, size: size), style: style))
        self.commit(d)
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let picture = pictureRect
        // The field: dark, with the picture floating on it under a soft shadow.
        ctx.setFillColor(CGColor(gray: 0.16, alpha: 1))
        ctx.fill(bounds)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 18, color: CGColor(gray: 0, alpha: 0.7))
        ctx.setFillColor(CGColor(gray: 0.16, alpha: 1))
        ctx.fill(picture)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: picture)
        ctx.translateBy(x: picture.minX, y: picture.minY)
        ctx.scaleBy(x: zoom, y: zoom)
        Renderer.draw(document, source: source, in: ctx)
        if let live { Renderer.draw(live, document: document, source: source, in: ctx) }
        ctx.restoreGState()

        let crop = liveCrop ?? document.crop
        if let crop {
            let r = viewRect(crop)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
            ctx.addRect(picture); ctx.addRect(r)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(1)
            ctx.stroke(r.insetBy(dx: -0.5, dy: -0.5))
        }
        if let id = selectedID, let a = document.annotation(id) {
            let r = viewRect(a.bounds).insetBy(dx: -6, dy: -6)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(r)
        }
    }
}

/// The field a text annotation is typed into, placed on the canvas at the click.
final class TextEntry: NSTextField {
    var origin: CGPoint?
    var style: Style?
    var onCommit: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        drawsBackground = true
        backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85)
        focusRingType = .none
        cell?.wraps = false
        cell?.isScrollable = true
        target = self
        action = #selector(commit)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        sizeToFit()
        frame.size.width = max(frame.width, 40)
    }

    override func cancelOperation(_ sender: Any?) {
        onCommit?(false)
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onCommit?(true)
    }

    @objc private func commit() {
        onCommit?(true)
    }
}

extension History {
    /// The same past and future with a different present, for a drag that edits in place.
    init(history: History, replacingCurrent state: State) {
        self = history
        self.replaceCurrent(state)
    }
}
