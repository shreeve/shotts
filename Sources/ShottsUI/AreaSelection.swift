import AppKit
import ShottsCore

/// The area picker: one full-screen window per display, dimmed, where the user drags out a
/// rectangle. Escape cancels, Shift squares the selection, Space moves it while dragging.
/// Nothing is captured here; the caller captures the rectangle after the windows are gone.
public final class AreaSelection {
    public enum Outcome {
        case cancelled
        /// `rect` is in points relative to the screen's top-left corner, y downward.
        case selected(screen: NSScreen, rect: CGRect)
    }

    private var windows: [OverlayWindow] = []
    private var completion: ((Outcome) -> Void)?

    public init(screens: [NSScreen] = NSScreen.screens, completion: @escaping (Outcome) -> Void) {
        self.completion = completion
        windows = screens.map { screen in
            let window = OverlayWindow(screen: screen)
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
        NSCursor.crosshair.push()
    }

    private func finish(_ outcome: Outcome) {
        guard let completion else { return }
        self.completion = nil
        NSCursor.pop()
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        completion(outcome)
    }
}

final class OverlayWindow: NSWindow {
    let overlayView: OverlayView

    init(screen: NSScreen) {
        overlayView = OverlayView(screen: screen)
        // The four-argument initializer is the designated one; the variant taking a screen
        // calls it, which a subclass must therefore provide.
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
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
    let screen: NSScreen
    var onFinish: ((AreaSelection.Outcome) -> Void)?

    private var anchor: CGPoint?
    private var selection: CGRect?
    private var pointer: CGPoint = .zero
    private var moving = false
    private var lastPointer: CGPoint = .zero
    private var tracking: NSTrackingArea?

    init(screen: NSScreen) {
        self.screen = screen
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        onFinish?(.selected(screen: screen, rect: rect.intersection(bounds)))
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

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Dim everything but the selection.
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.35))
        if let selection {
            ctx.addRect(bounds)
            ctx.addRect(selection)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(1)
            ctx.stroke(selection.insetBy(dx: -0.5, dy: -0.5))
            drawSizeLabel(selection, in: ctx)
        } else {
            ctx.fill(bounds)
            // Crosshair while nothing is selected yet.
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.6))
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: pointer.x + 0.5, y: 0)); ctx.addLine(to: CGPoint(x: pointer.x + 0.5, y: bounds.height))
            ctx.move(to: CGPoint(x: 0, y: pointer.y + 0.5)); ctx.addLine(to: CGPoint(x: bounds.width, y: pointer.y + 0.5))
            ctx.strokePath()
        }
    }

    private func drawSizeLabel(_ rect: CGRect, in ctx: CGContext) {
        let scale = screen.backingScaleFactor
        let text = "\(Int(rect.width * scale)) × \(Int(rect.height * scale))"
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
