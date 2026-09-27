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
///
/// A change made in place (a drag, or typing) keeps `base`, the document as it was when the
/// change began: the change ends as one undo step against it, or Escape puts it back.
public final class CanvasView: NSView {
    public private(set) var history: History<Document>
    public let source: CGImage
    /// Points per picture pixel; the window's resizing sets it.
    public var zoom: CGFloat {
        didSet {
            guard zoom != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    public var tool: Tool = .callout { didSet { endTextEntry(commit: true); selectedID = nil; needsDisplay = true; onToolChange?(tool) } }
    public var onToolChange: ((Tool) -> Void)?
    /// The style new annotations get. Changing it restyles the text being typed, or else the
    /// selected annotation, in whatever changed and nothing else.
    public var style: Style = .standard { didSet { restyle(from: oldValue) } }
    public var onChange: (() -> Void)?

    public var document: Document { history.current }
    public private(set) var selectedID: Annotation.ID?

    private var base: Document?
    private var live: Annotation?          // the shape being dragged out
    private var liveCrop: CGRect?
    private var dragAnchor: CGPoint?
    private var dragOriginal: Annotation?
    /// For an arrow or callout being dragged with the select tool: which part was grabbed.
    private var dragPart: HitTest.ArrowPart?
    /// The tool the drag in progress behaves as: the current tool, or select when a tool clicked
    /// something it edits rather than draws over.
    private var dragTool: Tool = .select
    private(set) var textField: TextEntry?

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
        // Views no longer clip their drawing by default, and the rect AppKit asks the canvas to
        // draw can reach past it; unclipped, the dark field was painted over the bar above.
        clipsToBounds = true
        setAccessibilityRole(.image)
        setAccessibilityLabel("Capture")
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

    public override func resetCursorRects() {
        // The ordinary pointer for every tool: the crosshair belongs to the picker, not the editor.
        addCursorRect(pictureRect, cursor: .arrow)
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

    /// Ends the change in progress as one undo step.
    private func endChange() {
        if let base { history.record(since: base) }
        base = nil
        needsDisplay = true
        onChange?()
    }

    /// While typing, undo and redo work on the words; otherwise on the document. Never mid-drag.
    @objc public func undo(_ sender: Any?) {
        guard dragAnchor == nil else { return }
        if let words = textField?.undoManager, words.canUndo { words.undo(); return }
        endTextEntry(commit: true)
        if history.undo() != nil { selectedID = nil; needsDisplay = true; onChange?() }
    }

    @objc public func redo(_ sender: Any?) {
        guard dragAnchor == nil else { return }
        if let words = textField?.undoManager, words.canRedo { words.redo(); return }
        endTextEntry(commit: true)
        if history.redo() != nil { selectedID = nil; needsDisplay = true; onChange?() }
    }

    /// There is nothing to select all of; this keeps Command-A from beeping.
    public override func selectAll(_ sender: Any?) {}

    @objc public func delete(_ sender: Any?) {
        guard let id = selectedID, dragAnchor == nil else { return }
        var d = document
        d.remove(id)
        selectedID = nil
        commit(d)
    }


    /// Escape: typing, then a drag in progress, then the selection. False when there was
    /// nothing to cancel.
    public func cancelCurrent() -> Bool {
        if textField != nil {
            endTextEntry(commit: true)
        } else if dragAnchor != nil {
            // A move is put back; a shape being drawn is dropped.
            if let base, dragOriginal != nil { history.replaceCurrent(base) }
            base = nil
            dragAnchor = nil; dragOriginal = nil; dragPart = nil; live = nil; liveCrop = nil
        } else if selectedID != nil {
            selectedID = nil
        } else {
            return false
        }
        needsDisplay = true
        onChange?()
        return true
    }

    /// One unmodified key picks a tool, as in most annotation editors: V select, N arrow with
    /// text, A arrow, T text, R rectangle, E ellipse, P pen, H highlighter, O obscure, C crop.
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
        // A drag whose mouse-up never came (a close asked mid-drag, say) is put back, not
        // carried into this one.
        if dragAnchor != nil { _ = cancelCurrent() }
        let p = imagePoint(event)
        let hit = HitTest.annotation(at: p, in: document, tolerance: hitTolerance).flatMap(document.annotation)
        dragAnchor = p
        dragTool = tool
        switch (tool, hit?.shape) {
        case (.callout, .arrow?), (.callout, .callout?), (.arrow, .arrow?), (.arrow, .callout?):
            // The arrow tools select an arrow or callout as the select tool would, so what was
            // just drawn can be moved or reshaped without changing tools.
            dragTool = .select
        case (.text, .text?):
            // The text tool edits the text it clicks rather than typing over it.
            selectedID = hit?.id
            editText(hit!.id)
            dragAnchor = nil
            return
        default:
            if tool != .select { selectedID = nil }
        }
        switch dragTool {
        case .select:
            selectedID = hit?.id
            guard let hit else { break }
            dragPart = HitTest.arrowPart(at: p, of: hit, scale: document.scale, tolerance: hitTolerance)
            if event.clickCount == 2, hit.isText || dragPart == .text {
                // Double-click edits words; the rest of the click is not a drag.
                editText(hit.id)
                dragAnchor = nil
                dragPart = nil
            } else {
                dragOriginal = hit
                base = document
            }
        case .text:
            // Words start on the picture, even for a click in the field around it.
            let inside = CGPoint(x: min(max(p.x, 0), Double(document.width - 1)), y: min(max(p.y, 0), Double(document.height - 1)))
            beginTextEntry(at: inside, initial: "", style: style)
            dragAnchor = nil
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
        guard let anchor = dragAnchor else { return }
        let p = imagePoint(event)
        let before = dragExtent
        let shift = event.modifierFlags.contains(.shift)
        // Option while drawing makes a rectangle or ellipse solid; either key may change mid-drag.
        let filled = event.modifierFlags.contains(.option)
        switch dragTool {
        case .select:
            if let original = dragOriginal {
                var d = document
                d.replace(dragged(original, by: p - anchor))
                history.replaceCurrent(d)
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
        // Only what the drag touched is drawn again: on a big capture a whole redraw is many
        // times the cost.
        if let before, let after = dragExtent {
            setNeedsDisplay(before.union(after))
        } else {
            needsDisplay = true
        }
    }

    /// The part of the view a drag in progress can change: the shape being drawn or moved, its
    /// shadow, and its selection marks. Nil when the whole view changes (a crop dims everything
    /// outside it).
    private var dragExtent: CGRect? {
        guard liveCrop == nil, let a = live ?? dragOriginal.flatMap({ document.annotation($0.id) }) else { return nil }
        return viewRect(Renderer.extent(of: a, scale: document.scale)).insetBy(dx: -12, dy: -12)
    }

    public override func mouseUp(with event: NSEvent) {
        guard dragAnchor != nil else { return }
        defer { dragAnchor = nil; dragOriginal = nil; dragPart = nil; live = nil; liveCrop = nil; needsDisplay = true }
        switch dragTool {
        case .select:
            // The drag edited the document in place; it becomes one undo step, or none.
            if dragOriginal != nil { endChange() }
        case .crop:
            // A click, or a drag too small to be one, clears the crop.
            var d = document
            if let rect = liveCrop, SelectionRule.isUsable(rect, minimum: 4 / zoom) { d.setCrop(rect) } else { d.setCrop(nil) }
            commit(d)
        case .callout:
            // The arrow lands as a callout with no words yet, and typing starts at its tail. The
            // arrow and its words are one undo step.
            if let live, !live.isDegenerate(in: document.pixelBounds), case let .arrow(tail, tip) = live.shape {
                base = document
                var d = document
                let callout = relaid(Annotation(shape: .callout(from: tail, to: tip, text: Annotation.TextBox(origin: tail, string: "", size: .zero, alignment: .left)),
                                                style: live.style), from: tail, to: tip, string: "")
                d.add(callout)
                history.replaceCurrent(d)
                editText(callout.id)
            }
        default:
            if let live, !live.isDegenerate(in: document.pixelBounds) {
                var d = document
                d.add(live)
                commit(d)
            }
        }
    }

    // MARK: - Style

    private func restyle(from old: Style) {
        if let entry = textField {
            entry.restyle(entry.style.applying(from: old, to: style))
            if let id = entry.editingID, let a = document.annotation(id) {
                var d = document
                d.replace(restyled(a, entry.style))
                history.replaceCurrent(d)
            }
            updateLiveText(entry.string)
            return
        }
        guard let id = selectedID, let a = document.annotation(id) else { return }
        var d = document
        d.replace(restyled(a, a.style.applying(from: old, to: style)))
        commit(d)
    }

    /// The annotation in another style: text is measured again and a callout's words laid out
    /// again, since both depend on the font.
    private func restyled(_ a: Annotation, _ style: Style) -> Annotation {
        var copy = a
        copy.style = style
        switch a.shape {
        case let .text(origin, string, _, alignment):
            copy.shape = .text(origin: origin, string: string, size: Renderer.textSize(string, style: style, scale: document.scale), alignment: alignment)
        case let .callout(from, to, text):
            copy = relaid(copy, from: from, to: to, string: text.string)
        default:
            break
        }
        return copy
    }

    // MARK: - Callouts

    /// The text may run to within a small margin of the picture's edge on its side; Return
    /// breaks a line sooner. Only that margin wraps.
    private func calloutLayout(tail: CGPoint, tip: CGPoint, style: Style) -> CalloutLayout {
        CalloutLayout(tail: tail, tip: tip, lineHeight: Renderer.lineHeight(style: style, scale: document.scale),
                      maxWidth: Double(document.width), in: document.pixelBounds, margin: Self.textMargin * document.scale)
    }

    /// A callout with its words laid out afresh for its arrow.
    private func relaid(_ a: Annotation, from: CGPoint, to: CGPoint, string: String) -> Annotation {
        let layout = calloutLayout(tail: from, tip: to, style: a.style)
        let size = string.isEmpty ? CGSize.zero : Renderer.textSize(string, style: a.style, scale: document.scale, width: layout.width)
        var copy = a
        copy.shape = .callout(from: from, to: to, text: Annotation.TextBox(origin: layout.origin(for: size), string: string, size: size, alignment: layout.alignment))
        return copy
    }

    /// The annotation as a drag of `delta` on the part grabbed leaves it, a callout whose arrow
    /// changed shape with its words laid out afresh.
    private func dragged(_ original: Annotation, by delta: CGPoint) -> Annotation {
        let moved = original.dragged(dragPart, by: delta)
        guard case let .callout(from, to, text) = moved.shape, dragPart != .shaft, dragPart != nil else { return moved }
        return relaid(moved, from: from, to: to, string: text.string)
    }

    // MARK: - Text entry

    /// Opens typing for the words of a text or callout. They stay in the document without their
    /// words while typed, so the text keeps its place in the stack, and land when typing ends.
    func editText(_ id: Annotation.ID) {
        guard let a = document.annotation(id) else { return }
        if base == nil { base = document }
        var d = document
        switch a.shape {
        case let .text(origin, string, size, alignment):
            d.replace(Annotation(id: id, shape: .text(origin: origin, string: "", size: size, alignment: alignment), style: a.style))
            history.replaceCurrent(d)
            selectedID = nil // its box would stay at the old words' size while new ones are typed
            beginTextEntry(at: origin, initial: string, style: a.style)
        case let .callout(from, to, text):
            d.replace(relaid(a, from: from, to: to, string: ""))
            history.replaceCurrent(d)
            beginTextEntry(at: from, initial: text.string, style: a.style, layout: calloutLayout(tail: from, tip: to, style: a.style))
        default:
            return
        }
        textField?.editingID = id
    }

    /// Typing happens on the picture: the canvas draws the text in its final style as the entry's
    /// preview, and an invisible text view under it only supplies the caret and keystrokes.
    func beginTextEntry(at origin: CGPoint, initial: String, style: Style, layout: CalloutLayout? = nil) {
        if base == nil { base = document }
        let entry = TextEntry(style: style, origin: layout?.origin ?? origin, zoom: zoom, scale: document.scale)
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
        window?.makeFirstResponder(entry)
        entry.setSelectedRange(NSRange(location: (initial as NSString).length, length: 0))
        updateLiveText(initial)
    }

    private func updateLiveText(_ string: String) {
        guard let entry = textField else { return }
        let size = Renderer.textSize(string.isEmpty ? " " : string, style: entry.style, scale: document.scale, width: entry.layout?.width)
        // A callout's text hangs from its anchor and stays inside the picture.
        if let layout = entry.layout { entry.origin = layout.origin(for: size) }
        entry.box = size
        entry.preview = string.isEmpty ? nil : Annotation(shape: .text(origin: entry.origin, string: string, size: size, alignment: entry.layout?.alignment ?? .left),
                                                          style: entry.style)
        entry.place(in: pictureRect)
        needsDisplay = true
    }

    /// Ends typing: the words land in the text or callout they belong to, or as a new text, and
    /// the whole entry is one undo step. A text left without words goes; a callout left without
    /// words becomes a plain arrow.
    func endTextEntry(commit: Bool) {
        guard let entry = textField else { return }
        textField = nil
        entry.removeFromSuperview()
        window?.makeFirstResponder(self)
        let typed = entry.string.trimmingCharacters(in: .newlines)
        let words = commit && !typed.allSatisfy(\.isWhitespace) ? typed : ""
        var d = document
        if let id = entry.editingID, let a = d.annotation(id) {
            switch a.shape {
            case let .callout(from, to, _):
                var styled = a
                styled.style = entry.style
                if words.isEmpty { styled.shape = .arrow(from: from, to: to) }
                d.replace(words.isEmpty ? styled : relaid(styled, from: from, to: to, string: words))
            default:
                if words.isEmpty { d.remove(id) } else { d.replace(Annotation(id: id, shape: textShape(words, entry), style: entry.style)) }
            }
        } else if !words.isEmpty {
            d.add(Annotation(shape: textShape(words, entry), style: entry.style))
        }
        history.replaceCurrent(d)
        endChange()
    }

    private func textShape(_ words: String, _ entry: TextEntry) -> Annotation.Shape {
        let size = Renderer.textSize(words, style: entry.style, scale: document.scale, width: entry.layout?.width)
        return .text(origin: entry.layout?.origin(for: size) ?? entry.origin, string: words, size: size, alignment: entry.layout?.alignment ?? .left)
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let picture = pictureRect
        // The field: dark, with the picture floating on it under a soft shadow.
        ctx.setFillColor(CGColor(gray: 0.16, alpha: 1))
        ctx.fill(dirtyRect.intersection(bounds))
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 18, color: CGColor(gray: 0, alpha: 0.7))
        ctx.setFillColor(CGColor(gray: 0.16, alpha: 1))
        ctx.fill(picture)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: picture)
        ctx.translateBy(x: picture.minX, y: picture.minY)
        ctx.scaleBy(x: zoom, y: zoom)
        Renderer.draw(document, source: source, in: ctx, baseScale: zoom)
        for extra in [live, textField?.preview] {
            if let extra { Renderer.draw(extra, document: document, source: source, in: ctx, baseScale: zoom) }
        }
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
            switch a.shape {
            case let .arrow(from, to), let .callout(from, to, _):
                // An arrow shows its grips: a dot at each end, and a box around a callout's words.
                if case let .callout(_, _, text) = a.shape, !text.string.isEmpty { ctx.stroke(viewRect(text.frame).insetBy(dx: -4, dy: -4)) }
                ctx.setLineDash(phase: 0, lengths: [])
                for p in [from, to] {
                    let v = viewPoint(p)
                    let dot = CGRect(x: v.x - 5, y: v.y - 5, width: 10, height: 10)
                    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                    ctx.fillEllipse(in: dot)
                    ctx.strokeEllipse(in: dot)
                }
            default:
                ctx.stroke(viewRect(a.bounds).insetBy(dx: -6, dy: -6))
            }
        }
    }
}

/// The invisible text view words are typed into. It draws nothing but its caret; the canvas
/// draws `preview`, the words in their final style. Return adds a line; Escape or Command-Return
/// finishes. Its undo covers keystrokes only, and goes when it does.
final class TextEntry: NSTextView {
    private(set) var style = Style.standard
    var origin = CGPoint.zero
    /// Set for a callout: the box wraps at its width and hangs from its anchor.
    var layout: CalloutLayout?
    /// The measured box of the words, which the entry sits over exactly.
    var box = CGSize.zero
    /// The text or callout these words belong to, when editing one.
    var editingID: Annotation.ID?
    /// The words as they will land, for the canvas to draw.
    var preview: Annotation?
    private var zoom: CGFloat = 1
    private var scale: Double = 1
    private let words = UndoManager()
    /// Where the words are, in the canvas's coordinates: only clicks there reach the entry.
    private var wordsFrame = CGRect.zero
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
        self.origin = origin
        self.zoom = zoom
        self.scale = scale
        drawsBackground = false
        isRichText = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        textColor = .clear
        isHorizontallyResizable = true
        isVerticallyResizable = true
        restyle(style)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Its own undo, so keystrokes never reach the document's history or outlive the entry.
    override var undoManager: UndoManager? { words }

    func restyle(_ style: Style) {
        self.style = style
        font = Renderer.font(for: style, scale: scale * zoom)
        insertionPointColor = NSColor(cgColor: Renderer.cgColor(style.color)) ?? .red
    }

    /// Sits exactly over where the canvas draws the text, and grows with it.
    func place(in picture: CGRect) {
        let outline = Renderer.outlineWidth(style, scale: scale)
        let pad = outline * zoom
        var width: CGFloat = 0
        // The caret sits a hair right of where the words end, clear of the outline that
        // strokes outside the last glyph; the whole view shifts, which moves nothing visible
        // but the caret.
        var x = origin.x * zoom + picture.minX + pad * 2 + 2
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
        frame = CGRect(x: x, y: origin.y * zoom + picture.minY + pad, width: width, height: max(used.height, font?.pointSize ?? 20))
        wordsFrame = CGRect(x: origin.x * zoom + picture.minX, y: origin.y * zoom + picture.minY, width: box.width * zoom, height: box.height * zoom)
    }

    /// A callout's entry is as wide as its wrap, most of the picture for a vertical one; a click
    /// beside the words belongs to the canvas, which finishes typing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        wordsFrame.insetBy(dx: -4, dy: -4).contains(point) ? super.hitTest(point) : nil
    }

    override func didChangeText() {
        super.didChangeText()
        onChange?(string)
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        // Escape and Command-Return finish, except while an input method is composing.
        if !hasMarkedText(), event.keyCode == 53 || (isReturn && event.modifierFlags.contains(.command)) {
            onFinish?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if !hasMarkedText() { onFinish?() }
    }
}

extension CanvasView: NSMenuItemValidation {
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): (textField?.undoManager?.canUndo ?? false) || history.canUndo
        case #selector(redo(_:)): (textField?.undoManager?.canRedo ?? false) || history.canRedo
        case #selector(delete(_:)): selectedID != nil
        default: true
        }
    }
}

extension Annotation {
    var isText: Bool {
        if case .text = shape { true } else { false }
    }
}
