import AppKit
import ShottsCore

public enum Tool: Int, CaseIterable, Sendable {
    case select, callout, arrow, text, rectangle, ellipse, pen, highlighter, obscure, crop

    public var title: String {
        switch self {
        case .select: "Select"
        case .callout: "Arrow with text"
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
        case .callout: "n"
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
        case .callout: "text.bubble"
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
    public var tool: Tool = .callout { didSet { endTextEntry(commit: true); selectedID = nil; needsDisplay = true; resetCursorRects(); onToolChange?(tool) } }
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
    /// For a callout being dragged with the select tool: which part was grabbed.
    private var dragPart: HitTest.CalloutPart?
    fileprivate(set) var textField: TextEntry?

    /// The dark field around the picture, and the room its shadow needs.
    public static let inset: CGFloat = 28
    /// How close to the picture's edges a callout's text may go, in points.
    public static let textMargin: Double = 8

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
        if textField != nil { endTextEntry(commit: true); return true }
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

    private func viewPoint(_ p: CGPoint) -> CGPoint {
        let picture = pictureRect
        return CGPoint(x: p.x * zoom + picture.minX, y: p.y * zoom + picture.minY)
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
            dragPart = dragOriginal.flatMap { HitTest.calloutPart(at: p, of: $0, tolerance: hitTolerance) }
            if event.clickCount == 2, let a = dragOriginal {
                if case let .text(origin, string, _, _) = a.shape {
                    var d = document
                    d.remove(a.id)
                    commit(d)
                    beginTextEntry(at: origin, initial: string, style: a.style)
                } else if case let .callout(from, to, text) = a.shape, dragPart == .text {
                    editCalloutText(a.id, from: from, to: to, initial: text.string, style: a.style)
                }
            }
        case .text:
            beginTextEntry(at: p, initial: "", style: style)
        case .arrow, .callout:
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
        // Option while drawing makes a rectangle or ellipse solid; either key may change mid-drag.
        let filled = event.modifierFlags.contains(.option)
        switch tool {
        case .select:
            if let original = dragOriginal {
                var d = document
                d.replace(dragged(original, by: p - anchor))
                history = History(history: history, replacingCurrent: d)
            }
        case .arrow, .callout:
            live?.shape = .arrow(from: anchor, to: p)
        case .rectangle:
            live?.shape = .rectangle(SelectionRule.rect(anchor: anchor, pointer: p, square: shift), filled: filled)
        case .ellipse:
            live?.shape = .ellipse(SelectionRule.rect(anchor: anchor, pointer: p, square: shift), filled: filled)
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
        defer { dragAnchor = nil; dragOriginal = nil; dragPart = nil; live = nil; liveCrop = nil; needsDisplay = true }
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
        case .callout:
            // The arrow lands as a callout with no words yet, and typing starts at its tail.
            if let live, !live.isDegenerate, case let .arrow(tail, tip) = live.shape {
                let layout = calloutLayout(tail: tail, tip: tip, style: live.style)
                let callout = Annotation(shape: .callout(from: tail, to: tip, text: Annotation.TextBox(origin: layout.origin, string: "", size: .zero, alignment: layout.alignment)), style: live.style)
                var d = document
                d.add(callout)
                commit(d)
                editCalloutText(callout.id, from: tail, to: tip, initial: "", style: live.style)
            }
        default:
            if let live, !live.isDegenerate {
                var d = document
                d.add(live)
                commit(d)
            }
        }
    }

    // MARK: - Callouts

    /// The text may run to within a small margin of the picture's edge on its side; Return
    /// breaks a line sooner. Only that margin wraps.
    private func calloutLayout(tail: CGPoint, tip: CGPoint, style: Style) -> CalloutLayout {
        let margin = Self.textMargin * document.scale
        return CalloutLayout(tail: tail, tip: tip, lineHeight: Renderer.lineHeight(style: style, scale: document.scale),
                             maxWidth: Double(document.width), in: document.pixelBounds.insetBy(dx: margin, dy: margin))
    }

    /// A callout with its words laid out afresh for its arrow.
    private func relaid(_ a: Annotation, from: CGPoint, to: CGPoint, string: String) -> Annotation {
        let layout = calloutLayout(tail: from, tip: to, style: a.style)
        let size = string.isEmpty ? CGSize.zero : Renderer.textSize(string, style: a.style, scale: document.scale, width: layout.width)
        var copy = a
        copy.shape = .callout(from: from, to: to, text: Annotation.TextBox(origin: layout.origin(for: size), string: string, size: size, alignment: layout.alignment))
        return copy
    }

    /// The annotation as a drag of `delta` leaves it: a callout moves by the part grabbed
    /// (its words or the tail's end move the tail, the head moves the tip, the shaft moves all),
    /// anything else moves whole.
    private func dragged(_ original: Annotation, by delta: CGPoint) -> Annotation {
        guard case let .callout(from, to, text) = original.shape else { return original.translated(by: delta) }
        switch dragPart {
        case .text, .tail: return relaid(original, from: from + delta, to: to, string: text.string)
        case .head: return relaid(original, from: from, to: to + delta, string: text.string)
        default: return original.translated(by: delta)
        }
    }

    /// Opens typing for a callout's words. While typing, the callout shows its arrow only and
    /// the live text; the words land in the callout on commit.
    private func editCalloutText(_ id: Annotation.ID, from: CGPoint, to: CGPoint, initial: String, style: Style) {
        var d = document
        if let a = d.annotation(id) { d.replace(relaid(a, from: from, to: to, string: "")) }
        history = History(history: history, replacingCurrent: d)
        let layout = calloutLayout(tail: from, tip: to, style: style)
        beginTextEntry(at: layout.origin, initial: initial, style: style, layout: layout)
        textField?.calloutID = id
    }

    // MARK: - Text entry

    /// Typing happens on the picture: the canvas draws the text in its final style as a live
    /// annotation, and an invisible text view under it only supplies the caret and keystrokes.
    fileprivate func beginTextEntry(at origin: CGPoint, initial: String, style: Style, layout: CalloutLayout? = nil) {
        let entry = TextEntry(style: style, origin: origin, zoom: zoom, scale: document.scale)
        entry.layout = layout
        switch layout?.alignment {
        case .right: entry.alignment = .right
        case .center: entry.alignment = .center
        default: break
        }
        entry.string = initial
        entry.onChange = { [weak self] string in self?.updateLiveText(string) }
        entry.onFinish = { [weak self] in self?.endTextEntry(commit: true) }
        addSubview(entry)
        textField = entry
        entry.place(in: pictureRect)
        window?.makeFirstResponder(entry)
        entry.setSelectedRange(NSRange(location: (initial as NSString).length, length: 0))
        updateLiveText(initial)
    }

    private func updateLiveText(_ string: String) {
        guard let entry = textField else { return }
        let size = Renderer.textSize(string.isEmpty ? " " : string, style: entry.style, scale: document.scale, width: entry.layout?.width)
        if let layout = entry.layout {
            // A callout's text hangs from its anchor and stays inside the picture.
            entry.origin = layout.origin(for: size)
            entry.box = size
        }
        live = string.isEmpty ? nil : Annotation(shape: .text(origin: entry.origin, string: string, size: size, alignment: entry.layout?.alignment ?? .left), style: entry.style)
        entry.place(in: pictureRect)
        needsDisplay = true
    }

    func endTextEntry(commit: Bool) {
        guard let entry = textField else { return }
        textField = nil
        live = nil
        let string = entry.string.trimmingCharacters(in: .newlines)
        entry.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
        if let id = entry.calloutID {
            // The words land in the callout; a callout left without words is a plain arrow.
            guard let a = document.annotation(id), case let .callout(from, to, _) = a.shape else { return }
            var d = document
            if commit, !string.isEmpty {
                d.replace(relaid(a, from: from, to: to, string: string))
            } else {
                var plain = a
                plain.shape = .arrow(from: from, to: to)
                d.replace(plain)
            }
            self.commit(d)
            return
        }
        guard commit, !string.isEmpty else { return }
        let size = Renderer.textSize(string, style: entry.style, scale: document.scale, width: entry.layout?.width)
        let origin = entry.layout?.origin(for: size) ?? entry.origin
        var d = document
        d.add(Annotation(shape: .text(origin: origin, string: string, size: size, alignment: entry.layout?.alignment ?? .left), style: entry.style))
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
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            if case let .callout(from, to, text) = a.shape {
                // A callout shows what each part does: a box around the words, a dot at each end.
                if !text.string.isEmpty { ctx.stroke(viewRect(text.frame).insetBy(dx: -4, dy: -4)) }
                ctx.setLineDash(phase: 0, lengths: [])
                for p in [from, to] {
                    let v = viewPoint(p)
                    let dot = CGRect(x: v.x - 5, y: v.y - 5, width: 10, height: 10)
                    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                    ctx.fillEllipse(in: dot)
                    ctx.strokeEllipse(in: dot)
                }
            } else {
                ctx.stroke(viewRect(a.bounds).insetBy(dx: -6, dy: -6))
            }
        }
    }
}

/// The invisible text view a text annotation is typed into. It draws nothing but its caret;
/// the canvas shows the text. Return adds a line; Escape or Command-Return finishes.
final class TextEntry: NSTextView {
    private(set) var style = Style.standard
    var origin = CGPoint.zero
    /// Set for a callout: the box wraps at its width and hangs from its anchor.
    var layout: CalloutLayout?
    /// For a callout: the measured box of the words, which the entry sits over exactly.
    var box = CGSize.zero
    /// The callout these words belong to, when editing one.
    var calloutID: Annotation.ID?
    private var zoom: CGFloat = 1
    private var scale: Double = 1
    var onChange: ((String) -> Void)?
    var onFinish: (() -> Void)?

    // NSTextView's designated initializer; `init(frame:)` calls it, and a subclass that does
    // not provide it traps the first time text entry opens.
    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
    }

    convenience init(style: Style, origin: CGPoint, zoom: CGFloat, scale: Double) {
        // The classic text system, built by hand: a convenience initializer must hand a
        // container to the designated one.
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 4000, height: 4000))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
        self.style = style
        self.origin = origin
        self.zoom = zoom
        self.scale = scale
        drawsBackground = false
        isRichText = false
        allowsUndo = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        textContainer?.containerSize = NSSize(width: 4000, height: 4000)
        font = Renderer.font(for: style, scale: scale * zoom)
        textColor = .clear
        insertionPointColor = NSColor(cgColor: Renderer.cgColor(style.color)) ?? .red
        isHorizontallyResizable = true
        isVerticallyResizable = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Sits exactly over where the canvas draws the text, and grows with it.
    func place(in picture: CGRect) {
        let outline = Renderer.outlineWidth(style, scale: scale)
        let pad = outline * zoom
        var width: CGFloat = 0
        var x = origin.x * zoom + picture.minX + pad
        if let layout {
            // Wrap where the renderer will: the full wrap width, never the measured box, whose
            // width at the zoomed font's rounding could be a hair short and fold the last word
            // onto a phantom line. The view is as wide as the wrap and is slid so the edge the
            // words align to sits on the measured box's edge; only the caret is drawn, and it
            // is always inside the box.
            width = (layout.width - outline * 2) * zoom
            textContainer?.containerSize = NSSize(width: width, height: 4000)
            let inner = (box.width - outline * 2) * zoom
            switch layout.alignment {
            case .left: break
            case .right: x += inner - width
            case .center: x += (inner - width) / 2
            }
        }
        layoutManager?.ensureLayout(for: textContainer!)
        let used = layoutManager?.usedRect(for: textContainer!) ?? .zero
        if layout == nil { width = max(used.width, 4) + 4 }
        frame = CGRect(x: x, y: origin.y * zoom + picture.minY, width: width, height: max(used.height, font?.pointSize ?? 20))
    }

    override func didChangeText() {
        super.didChangeText()
        onChange?(string)
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if event.keyCode == 53 || (isReturn && event.modifierFlags.contains(.command)) {
            onFinish?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onFinish?()
    }
}

extension History {
    /// The same past and future with a different present, for a drag that edits in place.
    init(history: History, replacingCurrent state: State) {
        self = history
        self.replaceCurrent(state)
    }
}

/// Opens text entry on a canvas in a window that is never shown, types into it, and commits,
/// so the entry's construction and commit path can be checked without a display.
public enum TextEntryCheck {
    public static func run() -> Bool {
        guard let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let source = ctx.makeImage() else { return false }
        let canvas = CanvasView(document: Document(width: 400, height: 300, scale: 2), source: source, zoom: 0.5)
        let window = NSWindow(contentRect: canvas.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.check_beginText(at: CGPoint(x: 40, y: 40), initial: "Hello")
        canvas.check_typed("Hello there")
        canvas.endTextEntry(commit: true)
        guard canvas.document.annotations.count == 1, case let .text(_, string, size, _) = canvas.document.annotations[0].shape,
              string == "Hello there", size.width > 0, size.height > 0 else { return false }
        // A callout: its words land in it, right-justified against the tail.
        let callout = Annotation(shape: .callout(from: CGPoint(x: 300, y: 150), to: CGPoint(x: 380, y: 100),
                                                 text: Annotation.TextBox(origin: .zero, string: "", size: .zero, alignment: .left)), style: canvas.style)
        var d = canvas.document
        d.add(callout)
        canvas.commit(d)
        canvas.check_editCallout(callout.id, from: CGPoint(x: 300, y: 150), to: CGPoint(x: 380, y: 100))
        canvas.check_typed("wrapped words beside the tail of the arrow")
        canvas.endTextEntry(commit: true)
        guard canvas.document.annotations.count == 2, case let .callout(from, _, text) = canvas.document.annotations[1].shape,
              from == CGPoint(x: 300, y: 150), text.string.hasPrefix("wrapped"), text.alignment == .right, text.size.width > 0,
              text.frame.maxX <= 300 else { return false }
        return true
    }
}

extension CanvasView {
    func check_beginText(at origin: CGPoint, initial: String, layout: CalloutLayout? = nil) {
        beginTextEntry(at: origin, initial: initial, style: style, layout: layout)
    }

    func check_editCallout(_ id: Annotation.ID, from: CGPoint, to: CGPoint) {
        editCalloutText(id, from: from, to: to, initial: "", style: style)
    }

    func check_typed(_ string: String) {
        textField?.string = string
        textField?.didChangeText()
    }
}
