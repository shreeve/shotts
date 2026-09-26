import AppKit
import ShottsCore

/// What one display looked like when the hot key fired: the picture the overlay shows, the
/// magnifier reads, and the selection is cut from. Held only while the user selects.
public struct DisplayImage {
    public var screen: NSScreen
    public var image: CGImage
    public var scale: CGFloat

    public init(screen: NSScreen, image: CGImage, scale: CGFloat) {
        self.screen = screen
        self.image = image
        self.scale = scale
    }
}

/// How the area picker looks. Kept in the defaults; the menu bar menu changes them.
public struct SelectionOptions: Equatable, Sendable {
    public enum Crosshair: String, CaseIterable, Sendable {
        case auto, light, dark
        public var title: String {
            switch self {
            case .auto: "Light and Dark"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    /// Dims everything but the selection and a small window at the crosshair.
    public var dims = false
    /// The magnifier beside the pointer, with the color under the crosshair.
    public var magnifies = true
    /// The short list of keys, until the first drag.
    public var showsHints = true
    public var crosshair = Crosshair.auto
    /// Puts the capture on the clipboard as soon as the area is selected, before any editing.
    public var copiesOnCapture = true

    public init() {}

    public static var current: SelectionOptions {
        get {
            let d = UserDefaults.standard
            var o = SelectionOptions()
            o.dims = d.bool(forKey: "selection.dims")
            o.magnifies = d.object(forKey: "selection.magnifies") == nil ? true : d.bool(forKey: "selection.magnifies")
            o.showsHints = d.object(forKey: "selection.hints") == nil ? true : d.bool(forKey: "selection.hints")
            o.crosshair = Crosshair(rawValue: d.string(forKey: "selection.crosshair") ?? "") ?? .auto
            o.copiesOnCapture = d.object(forKey: "capture.copies") == nil ? true : d.bool(forKey: "capture.copies")
            return o
        }
        set {
            let d = UserDefaults.standard
            d.set(newValue.dims, forKey: "selection.dims")
            d.set(newValue.magnifies, forKey: "selection.magnifies")
            d.set(newValue.showsHints, forKey: "selection.hints")
            d.set(newValue.crosshair.rawValue, forKey: "selection.crosshair")
            d.set(newValue.copiesOnCapture, forKey: "capture.copies")
        }
    }
}

/// The area picker: one full-screen window per display showing that display as it was, where
/// the user drags out a rectangle. Escape cancels, Shift squares the selection, Space moves it
/// while dragging, Command-C copies the color under the crosshair and cancels.
public final class AreaSelection {
    public enum Outcome {
        case cancelled
        /// `rect` is in points relative to the display's top-left corner, y downward.
        case selected(display: DisplayImage, rect: CGRect)
    }

    private var windows: [OverlayWindow] = []
    private var completion: ((Outcome) -> Void)?

    public init(displays: [DisplayImage], options: SelectionOptions = .current, completion: @escaping (Outcome) -> Void) {
        self.completion = completion
        windows = displays.map { display in
            let window = OverlayWindow(display: display, options: options)
            window.overlayView.onFinish = { [weak self] outcome in self?.finish(outcome) }
            return window
        }
    }

    public func show() {
        for window in windows {
            window.orderFrontRegardless()
        }
        // A menu bar app is not the active app when its hot key fires, and only the active
        // app's key window gets Escape. The plain `activate()` is refused here (measured on
        // macOS 27: the app stays inactive and Escape goes to whatever app was in front), so
        // this is the form that ignores other apps. Then the main display's overlay is made key.
        NSApp.activate(ignoringOtherApps: true)
        windows.first(where: { $0.screen == NSScreen.main })?.makeKeyAndOrderFront(nil)
        // The crosshair is the pointer while the picker is up; an arrow beside it would only
        // add a second, offset hotspot to look at.
        NSCursor.hide()
    }

    private func finish(_ outcome: Outcome) {
        guard let completion else { return }
        self.completion = nil
        NSCursor.unhide()
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll() // and with them the display images
        completion(outcome)
    }
}

final class OverlayWindow: NSWindow {
    let overlayView: OverlayView

    init(display: DisplayImage, options: SelectionOptions) {
        overlayView = OverlayView(display: display, options: options)
        // The four-argument initializer is the designated one; the variant taking a screen
        // calls it, which a subclass must therefore provide.
        super.init(contentRect: display.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(display.screen.frame, display: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = overlayView
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class OverlayView: NSView {
    let display: DisplayImage
    let options: SelectionOptions
    var onFinish: ((AreaSelection.Outcome) -> Void)?

    private var anchor: CGPoint?
    private var selection: CGRect?
    private var pointer: CGPoint = .zero
    private var moving = false
    private var lastPointer: CGPoint = .zero
    private var hasDragged = false
    private var tracking: NSTrackingArea?

    init(display: DisplayImage, options: SelectionOptions) {
        self.display = display
        self.options = options
        super.init(frame: CGRect(origin: .zero, size: display.screen.frame.size))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// For previews: the state a real session would reach with the pointer here after a drag.
    func preview(pointer: CGPoint, selection: CGRect?) {
        self.pointer = pointer
        self.selection = selection
        hasDragged = selection != nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        anchor = convert(event.locationInWindow, from: nil)
        pointer = anchor!
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let anchor else { return }
        hasDragged = true
        if moving, let current = selection {
            selection = SelectionRule.moved(current, by: p - lastPointer, within: bounds)
            // Keep the anchor with the moved rectangle so releasing Space continues the drag.
            self.anchor = CGPoint(x: anchor.x + (selection!.minX - current.minX), y: anchor.y + (selection!.minY - current.minY))
        } else {
            selection = SelectionRule.rect(anchor: anchor, pointer: p, square: event.modifierFlags.contains(.shift))
        }
        lastPointer = p
        pointer = p
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { anchor = nil }
        guard let rect = selection, SelectionRule.isUsable(rect) else {
            selection = nil
            needsDisplay = true
            return
        }
        onFinish?(.selected(display: display, rect: rect.intersection(bounds)))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            onFinish?(.cancelled)
        case 49: // Space
            if anchor != nil { moving = true; lastPointer = pointer }
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { moving = false }
    }

    override func flagsChanged(with event: NSEvent) {
        if let anchor, !moving {
            selection = SelectionRule.rect(anchor: anchor, pointer: pointer, square: event.modifierFlags.contains(.shift))
            needsDisplay = true
        }
    }

    /// Edit › Copy while selecting: the color under the crosshair, as `#RRGGBB`, and done.
    @objc func copy(_ sender: Any?) {
        guard let color = colorUnderPointer() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(color.hex, forType: .string)
        onFinish?(.cancelled)
    }

    // MARK: - Pixels

    /// The pixel under the pointer, in image pixels.
    private var pointerPixel: (x: Int, y: Int) {
        (Int(floor(pointer.x * display.scale)), Int(floor(pointer.y * display.scale)))
    }

    func colorUnderPointer() -> RGBA? {
        let p = pointerPixel
        return PixelSampler.color(at: p.x, p.y, in: display.image)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // The display as it was. The bitmap's rows are stored top-first; flip around it.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .none
        ctx.draw(display.image, in: bounds)
        ctx.restoreGState()

        if options.dims {
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.35))
            ctx.addRect(bounds)
            if let selection { ctx.addRect(selection) }
            // A small clear window at the crosshair, so the color there is never dimmed.
            ctx.addRect(CGRect(x: floor(pointer.x) - 2, y: floor(pointer.y) - 2, width: 5, height: 5))
            ctx.fillPath(using: .evenOdd)
        }

        if let selection {
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(1)
            ctx.stroke(selection.insetBy(dx: -0.5, dy: -0.5))
            drawSizeLabel(selection, in: ctx)
        } else {
            drawCrosshair(in: ctx)
        }
        if options.magnifies { drawMagnifier(in: ctx) }
        if options.showsHints, !hasDragged { drawHints(in: ctx) }
    }

    private func drawCrosshair(in ctx: CGContext) {
        let x = floor(pointer.x) + 0.5, y = floor(pointer.y) + 0.5
        func lines() {
            ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: bounds.height))
            ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: bounds.width, y: y))
            ctx.strokePath()
        }
        switch options.crosshair {
        case .auto:
            // A dark edge under a light line: visible on any background.
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.45)); ctx.setLineWidth(3); lines()
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9)); ctx.setLineWidth(1); lines()
        case .light:
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.85)); ctx.setLineWidth(1); lines()
        case .dark:
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.7)); ctx.setLineWidth(1); lines()
        }
    }

    static let magnifierCells = 15
    static let magnifierCell: CGFloat = 8

    /// The neighborhood of the pointer at 8 points per pixel, the pixel under it marked, its
    /// color below, and the selection's size while dragging. It sits below and right of the
    /// pointer, or on whichever side keeps it on screen.
    private func drawMagnifier(in ctx: CGContext) {
        let cells = Self.magnifierCells, cell = Self.magnifierCell
        let box = CGFloat(cells) * cell
        let labelHeight: CGFloat = 22
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        // The pointer's pixel while aiming (a comma pair, as coordinates are written), the
        // selection's size while dragging (with ×, as sizes are), and the color under the pointer.
        let color = colorUnderPointer()
        let hex = color?.hex ?? ""
        let text: String
        if let selection {
            text = "\(Int(selection.width * display.scale)) × \(Int(selection.height * display.scale))   " + hex
        } else {
            text = "\(pointerPixel.x),\(pointerPixel.y)   " + hex
        }
        let textSize = (text as NSString).size(withAttributes: attributes)
        // Wide enough for the label, which grows while dragging; the pixels stay centered.
        let width = max(box, ceil(textSize.width) + 16)
        let panel = Self.panelRect(size: CGSize(width: width, height: box + labelHeight), near: pointer, in: bounds, gap: 24)
        let pixels = CGRect(x: panel.minX + (width - box) / 2, y: panel.minY, width: box, height: box)

        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: panel, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.clip()
        // The pixels: a crop of the display around the pointer, scaled up with no smoothing.
        let center = pointerPixel
        let half = cells / 2
        let wanted = CGRect(x: center.x - half, y: center.y - half, width: cells, height: cells)
        let available = wanted.intersection(CGRect(x: 0, y: 0, width: display.image.width, height: display.image.height))
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fill(CGRect(x: panel.minX, y: panel.minY, width: width, height: box))
        if !available.isEmpty, let crop = display.image.cropping(to: available) {
            let dest = CGRect(x: pixels.minX + (available.minX - wanted.minX) * cell,
                              y: pixels.minY + (available.minY - wanted.minY) * cell,
                              width: available.width * cell, height: available.height * cell)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: dest.maxY + dest.minY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .none
            ctx.draw(crop, in: dest)
            ctx.restoreGState()
        }
        // Grid and the center pixel.
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.15))
        ctx.setLineWidth(1)
        for i in 1..<cells {
            let o = CGFloat(i) * cell
            ctx.move(to: CGPoint(x: pixels.minX + o + 0.5, y: pixels.minY)); ctx.addLine(to: CGPoint(x: pixels.minX + o + 0.5, y: pixels.maxY))
            ctx.move(to: CGPoint(x: pixels.minX, y: pixels.minY + o + 0.5)); ctx.addLine(to: CGPoint(x: pixels.maxX, y: pixels.minY + o + 0.5))
        }
        ctx.strokePath()
        // The crosshair, magnified with the pixels: one translucent white line each way, a
        // pixel wide, crossing on the pixel under the pointer. No dark edge here: it hid the
        // very pixels being looked at.
        let centerCell = CGRect(x: pixels.minX + CGFloat(half) * cell, y: pixels.minY + CGFloat(half) * cell, width: cell, height: cell)
        if selection == nil {
            // Four arms that stop two cells short of the center box, leaving it clear.
            let gap = cell * 2
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.5))
            ctx.fill(CGRect(x: centerCell.minX, y: pixels.minY, width: cell, height: centerCell.minY - gap - pixels.minY))
            ctx.fill(CGRect(x: centerCell.minX, y: centerCell.maxY + gap, width: cell, height: pixels.maxY - centerCell.maxY - gap))
            ctx.fill(CGRect(x: pixels.minX, y: centerCell.minY, width: centerCell.minX - gap - pixels.minX, height: cell))
            ctx.fill(CGRect(x: centerCell.maxX + gap, y: centerCell.minY, width: pixels.maxX - centerCell.maxX - gap, height: cell))
        }
        // The pixel under the pointer: a white box with a dark edge, like the crosshair itself.
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.8)); ctx.setLineWidth(3); ctx.stroke(centerCell.insetBy(dx: -1, dy: -1))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.setLineWidth(1); ctx.stroke(centerCell.insetBy(dx: -1, dy: -1))

        // The label: the color, and the selection size while dragging.
        let label = CGRect(x: panel.minX, y: pixels.maxY, width: width, height: labelHeight)
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 0.95))
        ctx.fill(label)
        (text as NSString).draw(at: CGPoint(x: label.midX - textSize.width / 2, y: label.minY + (labelHeight - textSize.height) / 2), withAttributes: attributes)
        ctx.restoreGState()

        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.6))
        ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.strokePath()
    }

    /// Where a panel of `size` goes near the pointer: below and to the right by `gap`, else
    /// flipped to the side that fits.
    static func panelRect(size: CGSize, near p: CGPoint, in bounds: CGRect, gap: CGFloat) -> CGRect {
        var x = p.x + gap
        var y = p.y + gap
        if x + size.width > bounds.maxX { x = p.x - gap - size.width }
        if y + size.height > bounds.maxY { y = p.y - gap - size.height }
        x = max(bounds.minX, x)
        y = max(bounds.minY, y)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    static let hints = [
        "Drag to capture an area",
        "⇧ keeps it square, Space moves it",
        "⌘C copies the color under the crosshair",
        "Esc cancels",
    ]

    /// The keys, in the corner above and left of the pointer, until the first drag.
    private func drawHints(in ctx: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white,
        ]
        let lineHeight: CGFloat = 17
        let width = Self.hints.map { ($0 as NSString).size(withAttributes: attributes).width }.max()! + 20
        let size = CGSize(width: width, height: CGFloat(Self.hints.count) * lineHeight + 10)
        // Above and left: the mirror of the magnifier's preferred corner.
        var origin = CGPoint(x: pointer.x - 24 - size.width, y: pointer.y - 24 - size.height)
        if origin.x < bounds.minX { origin.x = pointer.x + 24 }
        if origin.y < bounds.minY { origin.y = pointer.y + 24 }
        let box = CGRect(origin: origin, size: size)
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 0.85))
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
        for (i, line) in Self.hints.enumerated() {
            (line as NSString).draw(at: CGPoint(x: box.minX + 10, y: box.minY + 5 + CGFloat(i) * lineHeight), withAttributes: attributes)
        }
    }

    private func drawSizeLabel(_ rect: CGRect, in ctx: CGContext) {
        guard !options.magnifies else { return } // the magnifier's label shows it
        let text = "\(Int(rect.width * display.scale)) × \(Int(rect.height * display.scale))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        var origin = CGPoint(x: rect.maxX - size.width - 6, y: rect.maxY + 6)
        if origin.y + size.height + 4 > bounds.height { origin.y = rect.maxY - size.height - 10 }
        origin.x = max(4, origin.x)
        let box = CGRect(x: origin.x - 4, y: origin.y - 2, width: size.width + 8, height: size.height + 4)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.7))
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.fillPath()
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}

/// Reads one pixel of a bitmap by drawing it into a one-pixel context, so it works for any
/// pixel format the capture comes in.
public enum PixelSampler {
    public static func color(at x: Int, _ y: Int, in image: CGImage) -> RGBA? {
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        guard let data = ctx.data else { return nil }
        let p = data.bindMemory(to: UInt8.self, capacity: 4)
        return RGBA(red: Double(p[0]) / 255, green: Double(p[1]) / 255, blue: Double(p[2]) / 255)
    }
}

/// The picker's view alone, for drawing it off screen in a check.
public enum OverlayPreview {
    public static func make(display: DisplayImage, options: SelectionOptions, pointer: CGPoint, selection: CGRect?) -> NSView {
        let view = OverlayView(display: display, options: options)
        view.preview(pointer: pointer, selection: selection)
        return view
    }
}
