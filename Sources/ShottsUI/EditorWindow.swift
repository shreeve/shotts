import AppKit
import ShottsCore

/// The window a capture opens in: a row of tools above the canvas. It sizes itself so the
/// picture appears at its on-screen size, or smaller to fit the display.
public final class EditorWindowController: NSWindowController, NSWindowDelegate {
    public let canvas: CanvasView
    public var onClose: (() -> Void)?

    private let tools = NSSegmentedControl()
    private let colors = NSPopUpButton()
    private let widths = NSPopUpButton()
    private let sizes = NSPopUpButton()
    private let tapered = NSButton(checkboxWithTitle: "Tapered", target: nil, action: nil)
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private var closing = false
    /// Wide enough for every control in the bar, whatever the picture's size.
    static let minimumWidth: CGFloat = 860

    public init(document: Document, source: CGImage, on screen: NSScreen? = NSScreen.main) {
        let visible = (screen ?? NSScreen.screens[0]).visibleFrame
        let natural = CGSize(width: CGFloat(document.width) / document.scale, height: CGFloat(document.height) / document.scale)
        let fit = min(1, (visible.width - 40) / natural.width, (visible.height - 120) / natural.height)
        let zoom = fit / document.scale
        canvas = CanvasView(document: document, source: source, zoom: zoom)

        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Shotts"
        window.appearance = NSAppearance(named: .darkAqua) // the editor is dark whatever the system is
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let content = makeContent()
        window.contentView = content
        // The bar's height plus the canvas, with the insets below; sized here rather than from
        // `fittingSize`, which a stack view answers before it has laid out.
        content.layoutSubtreeIfNeeded()
        let barSize = content.subviews.first?.fittingSize ?? NSSize(width: 0, height: 44)
        let width = max(canvas.frame.width, barSize.width, Self.minimumWidth)
        window.setContentSize(NSSize(width: width, height: barSize.height + canvas.frame.height))
        window.center()
        canvas.style = Self.rememberedStyle
        showStyle(canvas.style)
        canvas.onChange = { [weak self] in self?.refresh() }
        canvas.onToolChange = { [weak self] tool in self?.tools.selectedSegment = tool.rawValue }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
    }

    // MARK: - Layout

    private func makeContent() -> NSView {
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        tools.segmentStyle = .texturedRounded
        tools.trackingMode = .selectOne
        tools.segmentCount = Tool.allCases.count
        for (i, tool) in Tool.allCases.enumerated() {
            tools.setImage(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title), forSegment: i)
            tools.setToolTip("\(tool.title) (\(tool.key.uppercased()))", forSegment: i)
            tools.setWidth(30, forSegment: i)
        }
        tools.selectedSegment = Tool.arrow.rawValue
        tools.target = self
        tools.action = #selector(toolChanged)

        for c in RGBA.palette {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.image = swatch(c)
            item.representedObject = [c.red, c.green, c.blue, c.alpha]
            colors.menu?.addItem(item)
        }
        colors.target = self
        colors.action = #selector(styleChanged)
        colors.toolTip = "Color"

        for w in Style.strokeWidths {
            widths.addItem(withTitle: "\(Int(w)) pt")
            widths.lastItem?.representedObject = w
        }
        widths.selectItem(at: Style.strokeWidths.firstIndex(of: Style.standard.strokeWidth) ?? 1)
        widths.target = self
        widths.action = #selector(styleChanged)
        widths.toolTip = "Line width"

        for f in Style.fontSizes {
            sizes.addItem(withTitle: "\(Int(f))")
            sizes.lastItem?.representedObject = f
        }
        sizes.selectItem(at: Style.fontSizes.firstIndex(of: Style.standard.fontSize) ?? 2)
        sizes.target = self
        sizes.action = #selector(styleChanged)
        sizes.toolTip = "Text size"

        tapered.target = self
        tapered.action = #selector(styleChanged)
        tapered.toolTip = "Arrows taper from a thin tail to the head"

        configure(undoButton, symbol: "arrow.uturn.backward", tip: "Undo", action: #selector(undoPressed))
        configure(redoButton, symbol: "arrow.uturn.forward", tip: "Redo", action: #selector(redoPressed))

        let copy = NSButton(title: "Copy", target: self, action: #selector(copyPressed))
        copy.keyEquivalent = "c"
        copy.keyEquivalentModifierMask = .command
        let save = NSButton(title: "Save…", target: self, action: #selector(savePressed))
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command
        let grip = DragGrip(controller: self)

        bar.addArrangedSubview(tools)
        bar.addArrangedSubview(colors)
        bar.addArrangedSubview(widths)
        bar.addArrangedSubview(sizes)
        bar.addArrangedSubview(tapered)
        bar.addArrangedSubview(undoButton)
        bar.addArrangedSubview(redoButton)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        bar.addArrangedSubview(spacer)
        bar.addArrangedSubview(grip)
        bar.addArrangedSubview(copy)
        bar.addArrangedSubview(save)

        let column = NSStackView(views: [bar, canvas])
        column.orientation = .vertical
        column.spacing = 0
        column.alignment = .width // the bar and the field both span the window

        canvas.heightAnchor.constraint(equalToConstant: canvas.frame.height).isActive = true
        column.setHuggingPriority(.required, for: .horizontal)
        column.setHuggingPriority(.required, for: .vertical)
        column.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        return column
    }

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.bezelStyle = .texturedRounded
        button.toolTip = tip
        button.target = self
        button.action = action
    }

    private func swatch(_ c: RGBA) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha).setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            path.stroke()
            return true
        }
        return image
    }

    private func refresh() {
        undoButton.isEnabled = canvas.history.canUndo
        redoButton.isEnabled = canvas.history.canRedo
        window?.isDocumentEdited = !canvas.document.isBlank
    }

    // MARK: - Actions

    @objc private func toolChanged() {
        canvas.tool = Tool(rawValue: tools.selectedSegment) ?? .arrow
    }

    @objc private func styleChanged() {
        var style = canvas.style
        if let parts = colors.selectedItem?.representedObject as? [Double], parts.count == 4 {
            style.color = RGBA(red: parts[0], green: parts[1], blue: parts[2], alpha: parts[3])
        }
        if let w = widths.selectedItem?.representedObject as? Double { style.strokeWidth = w }
        if let f = sizes.selectedItem?.representedObject as? Double { style.fontSize = f }
        style.taperedArrows = tapered.state == .on
        canvas.style = style
        Self.rememberedStyle = style
    }

    /// Sets the bar's controls to show a style.
    private func showStyle(_ style: Style) {
        if let i = RGBA.palette.firstIndex(of: style.color) { colors.selectItem(at: i) }
        if let i = Style.strokeWidths.firstIndex(of: style.strokeWidth) { widths.selectItem(at: i) }
        if let i = Style.fontSizes.firstIndex(of: style.fontSize) { sizes.selectItem(at: i) }
        tapered.state = style.taperedArrows ? .on : .off
    }

    /// The style the last edit used, so the next capture starts with the same color and sizes.
    static var rememberedStyle: Style {
        get {
            guard let data = UserDefaults.standard.data(forKey: "editor.style"),
                  let style = try? JSONDecoder().decode(Style.self, from: data) else { return .standard }
            return style
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "editor.style")
        }
    }

    @objc private func undoPressed() { canvas.undo(nil) }
    @objc private func redoPressed() { canvas.redo(nil) }

    @objc public func copyPressed() {
        canvas.endTextEntry(commit: true)
        if Export.copy(canvas.document, source: canvas.source) {
            finish()
        }
    }

    @objc public func savePressed() {
        canvas.endTextEntry(commit: true)
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = Export.suggestedName()
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Export.write(canvas.document, source: canvas.source, to: url)
                finish()
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    /// Closes after a copy, save, or drag out.
    func finish() {
        closing = true
        close()
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closing || canvas.document.isBlank { return true }
        let alert = NSAlert()
        alert.messageText = "Discard this capture?"
        alert.informativeText = "It has annotations that were not copied or saved."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    public func windowWillClose(_ notification: Notification) {
        onClose?()
        onClose = nil
    }

    public override func cancelOperation(_ sender: Any?) {
        if !canvas.cancelCurrent() { close() }
    }
}

/// The handle you drag to put the picture somewhere: a file promise the drop target reads.
final class DragGrip: NSImageView {
    private weak var controller: EditorWindowController?

    init(controller: EditorWindowController) {
        self.controller = controller
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "hand.draw", accessibilityDescription: "Drag out")
        toolTip = "Drag the picture into another app"
        widthAnchor.constraint(equalToConstant: 28).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func mouseDragged(with event: NSEvent) {
        guard let controller, let file = try? Export.temporaryFile(controller.canvas.document, source: controller.canvas.source) else { return }
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        let preview = NSImage(cgImage: controller.canvas.source, size: NSSize(width: 160, height: 160 * CGFloat(controller.canvas.document.height) / CGFloat(controller.canvas.document.width)))
        item.setDraggingFrame(NSRect(origin: convert(event.locationInWindow, from: nil), size: preview.size), contents: preview)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
}

extension DragGrip: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation != [] { controller?.finish() }
    }
}
