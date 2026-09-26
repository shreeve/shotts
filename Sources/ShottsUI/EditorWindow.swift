import AppKit
import ShottsCore

/// The window a capture opens in: a row of tools above the canvas. It sizes itself so the
/// picture appears at its on-screen size, or smaller to fit the display.
public final class EditorWindowController: NSWindowController, NSWindowDelegate {
    public let canvas: CanvasView
    public var onClose: (() -> Void)?

    private let tools = NSSegmentedControl()
    private let colorButton = NSButton()
    private let popover = NSPopover()
    private var stylePopover: StylePopover?
    private let widths = NSPopUpButton()
    private let sizes = NSPopUpButton()
    private let fonts = NSPopUpButton()
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private var closing = false
    /// Wide enough for every control in the bar, whatever the picture's size.
    static let minimumWidth: CGFloat = 880
    /// The shortest the picture's longer side may be made by resizing, in points.
    static let minimumPicture: CGFloat = 160
    /// The sizes the window may take; the bar's measured size is filled in once it is laid out.
    private(set) var layout: EditorLayout
    private var canvasHeight: NSLayoutConstraint?

    public init(document: Document, source: CGImage, on screen: NSScreen? = NSScreen.main) {
        layout = EditorLayout(picture: CGSize(width: document.width, height: document.height), scale: document.scale, barHeight: 44,
                              minimumWidth: Self.minimumWidth, inset: CanvasView.inset, minimumPicture: Self.minimumPicture)
        canvas = CanvasView(document: document, source: source, zoom: layout.naturalZoom)

        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Shotts"
        window.appearance = NSAppearance(named: .darkAqua) // the editor is dark whatever the system is
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let content = makeContent()
        window.contentView = content
        // The bar's size once laid out: a stack view's `fittingSize` before layout is not it.
        content.layoutSubtreeIfNeeded()
        let bar = content.subviews.first?.fittingSize ?? NSSize(width: Self.minimumWidth, height: 44)
        layout.barHeight = bar.height
        layout.minimumWidth = max(Self.minimumWidth, bar.width.rounded(.up))
        // Open at the picture's on-screen size, or smaller to fit the screen with the title bar.
        let visible = (screen ?? NSScreen.screens[0]).visibleFrame
        let room = window.contentRect(forFrameRect: visible).size
        show(zoom: layout.zoom(fitting: room))
        window.setContentSize(layout.contentSize(zoom: canvas.zoom))
        window.contentMinSize = layout.contentSize(zoom: layout.minimumZoom)
        window.center()
        canvas.style = Self.rememberedStyle
        showStyle(canvas.style)
        canvas.onChange = { [weak self] in self?.refresh() }
        canvas.onToolChange = { [weak self] tool in
            self?.tools.selectedSegment = tool.rawValue
            // Only a drawing tool is worth coming back to; select and crop are passing states.
            if tool != .select, tool != .crop { Self.rememberedTool = tool }
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public func present() {
        NSApp.activate(ignoringOtherApps: true) // see AreaSelection.show()
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
        tools.selectedSegment = Self.rememberedTool.rawValue
        canvas.tool = Self.rememberedTool
        tools.target = self
        tools.action = #selector(toolChanged)

        colorButton.bezelStyle = .texturedRounded
        colorButton.image = StylePopover.swatch(canvas.style.color, size: 18)
        colorButton.imagePosition = .imageOnly
        colorButton.target = self
        colorButton.action = #selector(showStylePopover)
        colorButton.toolTip = "Color and style"

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

        for choice in FontChoice.allCases {
            fonts.addItem(withTitle: choice.title)
            fonts.lastItem?.representedObject = choice.rawValue
        }
        fonts.target = self
        fonts.action = #selector(styleChanged)
        fonts.toolTip = "Text font"

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
        bar.addArrangedSubview(colorButton)
        bar.addArrangedSubview(widths)
        bar.addArrangedSubview(sizes)
        bar.addArrangedSubview(fonts)
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

        let height = canvas.heightAnchor.constraint(equalToConstant: canvas.frame.height)
        height.isActive = true
        canvasHeight = height
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

    private func refresh() {
        undoButton.isEnabled = canvas.history.canUndo
        redoButton.isEnabled = canvas.history.canRedo
        window?.isDocumentEdited = !canvas.document.isBlank
    }

    // MARK: - Actions

    @objc private func toolChanged() {
        canvas.tool = Tool(rawValue: tools.selectedSegment) ?? .callout
    }

    /// The drawing tool last used; a new capture starts with it.
    static var rememberedTool: Tool {
        get {
            // Nothing remembered yet reads as 0, which would be the select tool.
            guard UserDefaults.standard.object(forKey: "editor.tool") != nil else { return .callout }
            return Tool(rawValue: UserDefaults.standard.integer(forKey: "editor.tool")) ?? .callout
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "editor.tool") }
    }

    @objc private func styleChanged() {
        var style = canvas.style
        if let w = widths.selectedItem?.representedObject as? Double { style.strokeWidth = w }
        if let f = sizes.selectedItem?.representedObject as? Double { style.fontSize = f }
        if let raw = fonts.selectedItem?.representedObject as? String, let choice = FontChoice(rawValue: raw) { style.font = choice }
        apply(style)
    }

    @objc private func showStylePopover() {
        if popover.isShown { popover.close(); return }
        let content = StylePopover(style: canvas.style)
        content.onStyle = { [weak self] style in self?.apply(style) }
        stylePopover = content
        popover.contentViewController = content
        popover.behavior = .transient
        popover.show(relativeTo: colorButton.bounds, of: colorButton, preferredEdge: .minY)
    }

    private func apply(_ style: Style) {
        canvas.style = style
        Self.rememberedStyle = style
        showStyle(style)
    }

    /// Sets the bar's controls to show a style.
    private func showStyle(_ style: Style) {
        colorButton.image = StylePopover.swatch(style.color, size: 18)
        if let i = Style.strokeWidths.firstIndex(of: style.strokeWidth) { widths.selectItem(at: i) }
        if let i = Style.fontSizes.firstIndex(of: style.fontSize) { sizes.selectItem(at: i) }
        if let i = FontChoice.allCases.firstIndex(of: style.font) { fonts.selectItem(at: i) }
        stylePopover?.show(style)
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

    /// Command-P: the picture as it would export, scaled to fit one page, sideways when it is
    /// wider than tall. The editor stays open: printing is not a way of finishing.
    @objc public func printPressed() {
        canvas.endTextEntry(commit: true)
        guard let window, let (sheet, info) = Self.page(for: canvas.document, source: canvas.source) else { return }
        let operation = NSPrintOperation(view: sheet, printInfo: info)
        operation.jobTitle = Export.suggestedName().replacingOccurrences(of: ".png", with: "")
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// The page to print: the rendered picture and print settings that fit it to one sheet.
    private static func page(for document: Document, source: CGImage) -> (NSView, NSPrintInfo)? {
        guard let image = Renderer.image(of: document, source: source) else { return nil }
        let info = NSPrintInfo(dictionary: NSPrintInfo.shared.dictionary() as! [NSPrintInfo.AttributeKey: Any])
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        info.orientation = image.width > image.height ? .landscape : .portrait
        return (PrintSheet(image: image, scale: document.scale), info)
    }

    /// Developer check: the page as a PDF, exactly as printing would lay it out.
    public static func printPDF(_ document: Document, source: CGImage, to url: URL) -> Bool {
        guard let (sheet, info) = page(for: document, source: source) else { return false }
        let operation = NSPrintOperation.pdfOperation(with: sheet, inside: sheet.bounds, toPath: url.path, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        return operation.run()
    }

    /// Closes after a copy, save, or drag out.
    func finish() {
        closing = true
        close()
    }

    // MARK: - Resizing

    // Resizing changes only how big the picture is drawn, never the picture: the zoom, in points
    // per pixel, follows the window, up to the picture's on-screen size and down to a small one.
    // Annotations are in picture pixels, so they scale with it, old and new alike, stay editable,
    // and export exactly as before. The window keeps the picture's proportions (plus the bar).

    /// Draws the picture at this zoom, the canvas as tall as the picture and its field need.
    private func show(zoom: CGFloat) {
        canvas.endTextEntry(commit: true) // an entry is placed for one zoom
        canvas.zoom = zoom
        canvasHeight?.constant = CGFloat(canvas.document.height) * zoom + CanvasView.inset * 2
    }

    public func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let content = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let snug = layout.contentSize(zoom: layout.zoom(fitting: content))
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: snug)).size
    }

    public func windowDidResize(_ notification: Notification) {
        guard let window else { return }
        let zoom = layout.zoom(fitting: window.contentRect(forFrameRect: window.frame).size)
        if zoom != canvas.zoom { show(zoom: zoom) }
    }

    /// The green button: the picture at its on-screen size, or as large as the screen allows.
    public func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        let room = window.contentRect(forFrameRect: defaultFrame).size
        let content = layout.contentSize(zoom: layout.zoom(fitting: room))
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: defaultFrame.midX - frame.width / 2, y: defaultFrame.maxY - frame.height)
        return frame
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

/// The page's content: the rendered picture at its natural size in points, which pagination
/// scales to fit the paper.
private final class PrintSheet: NSView {
    private let image: CGImage

    init(image: CGImage, scale: Double) {
        self.image = image
        super.init(frame: NSRect(x: 0, y: 0, width: Double(image.width) / scale, height: Double(image.height) / scale))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.draw(image, in: bounds)
    }
}

/// The handle you drag to put the picture somewhere: a PNG file the drop target reads.
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
