import AppKit
import ShottsCore

/// One display as the picker sees it: its picture, which the magnifier reads and the selection
/// is cut from, and the windows on it. Live, a stream keeps both current and the overlay lets the
/// real screen show through; a stand-in (the developer checks, the tests) has a fixed picture
/// that the overlay draws. Held only while the user selects; the cut-out shares none of its
/// pixels.
public final class DisplayImage {
    public let screen: NSScreen
    public let scale: CGFloat
    /// The display's pixels: the latest frame while live, nil until the first arrives.
    public var image: CGImage? { didSet { onChange?() } }
    /// The windows on this display, front to back. A click on one captures it.
    public var windows: [WindowInfo]
    /// Whether the real screen shows through the overlay, rather than `image` drawn on it.
    public let isLive: Bool
    /// The overlay's hook for a new picture: the magnifier shows it.
    var onChange: (() -> Void)?

    public init(screen: NSScreen, image: CGImage?, scale: CGFloat, windows: [WindowInfo] = [], isLive: Bool = false) {
        self.screen = screen
        self.image = image
        self.scale = scale
        self.windows = windows
        self.isLive = isLive
    }

    /// The whole display in pixels.
    public var pixelBounds: CGRect {
        if let image { return CGRect(x: 0, y: 0, width: image.width, height: image.height) }
        return CGRect(x: 0, y: 0, width: (screen.frame.width * scale).rounded(), height: (screen.frame.height * scale).rounded())
    }

    /// The picture's pixels under `rect` (points from the display's top-left), whole pixels,
    /// inside the picture: the one conversion from the picker's points, so the size the picker
    /// shows is the size cut.
    public func pixelRect(for rect: CGRect) -> CGRect {
        SelectionRule.pixelRect(rect, scale: scale, within: pixelBounds)
    }

    /// The area under `rect` as a picture of its own. `CGImage.cropping(to:)` alone would keep
    /// a reference to the whole display's pixels for as long as the editor holds the cut-out,
    /// so the crop is drawn into a bitmap of its own size, in the picture's own color space and
    /// pixel format so no color shifts.
    public func cut(_ rect: CGRect) -> CGImage? {
        let pixels = pixelRect(for: rect)
        guard let image, !pixels.isEmpty, let crop = image.cropping(to: pixels), let space = image.colorSpace else { return nil }
        let w = crop.width, h = crop.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: image.bitsPerComponent, bytesPerRow: 0,
                                  space: space, bitmapInfo: image.bitmapInfo.rawValue)
                ?? CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                             bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.setBlendMode(.copy)
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

/// One window the picker can capture: the window server's id, for capturing it on its own,
/// and its frame in points from its display's top-left corner.
public struct WindowInfo: Equatable, Sendable {
    public var id: CGWindowID
    public var frame: CGRect

    public init(id: CGWindowID, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

/// How the area picker looks. Kept in the defaults; the menu bar menu changes them.
public struct SelectionOptions: Equatable, Sendable {
    /// Dims everything outside the selection while it is being dragged out. Never before: a
    /// click on a window, or aiming, leaves the screen as it is.
    public var dims = true
    /// The magnifier beside the pointer, with the color under the crosshair.
    public var magnifies = true
    /// Puts the capture on the clipboard as soon as the area is selected, before any editing.
    public var copiesOnCapture = true
    /// A captured window keeps the shadow macOS draws around it, on a transparent margin.
    public var dropShadow = false
    /// Each capture opens an editor of its own; otherwise it takes the place of the open one.
    public var newWindows = false

    public init() {}

    /// The defaults, with the options that start on registered as on.
    private static let defaults: UserDefaults = {
        let d = UserDefaults.standard
        d.register(defaults: ["selection.dimsDrag": true, "selection.magnifies": true, "capture.copies": true])
        return d
    }()

    public static var current: SelectionOptions {
        get {
            let d = defaults
            var o = SelectionOptions()
            o.dims = d.bool(forKey: "selection.dimsDrag")
            o.magnifies = d.bool(forKey: "selection.magnifies")
            o.copiesOnCapture = d.bool(forKey: "capture.copies")
            o.dropShadow = d.bool(forKey: "export.shadow")
            o.newWindows = d.bool(forKey: "editor.newWindows")
            return o
        }
        set {
            let d = defaults
            d.set(newValue.dims, forKey: "selection.dimsDrag")
            d.set(newValue.magnifies, forKey: "selection.magnifies")
            d.set(newValue.copiesOnCapture, forKey: "capture.copies")
            d.set(newValue.dropShadow, forKey: "export.shadow")
            d.set(newValue.newWindows, forKey: "editor.newWindows")
        }
    }
}

/// The area picker: one full-screen window per display showing that display as it was, where
/// the user drags out a rectangle. Escape cancels, Shift squares the selection, Space moves it
/// while dragging, the arrow keys move the crosshair (or the corner being dragged) a pixel at a
/// time or ten with Shift, pressing Command during the drag records the area instead (pressing
/// it again goes back), and Command-C copies the color under the crosshair and cancels. A
/// click without a drag takes the window under it, or on the desktop the whole display; with
/// Command, it records that instead.
public final class AreaSelection {
    public enum Outcome {
        case cancelled
        /// `rect` is in points relative to the display's top-left corner, y downward.
        case selected(display: DisplayImage, rect: CGRect)
        /// A click on a window: capture that window on its own.
        case window(display: DisplayImage, window: WindowInfo)
        /// A drag ended, or a click came, with Command down: record the area (a window's, or the
        /// whole display's), in points like `selected`.
        case record(display: DisplayImage, rect: CGRect)
        /// An Option-click on a window (not Command): capture all of it as it is scrolled, its
        /// area in points like `selected`.
        case scroll(display: DisplayImage, rect: CGRect)
    }

    private var windows: [OverlayWindow] = []
    private var completion: ((Outcome) -> Void)?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    public init(displays: [DisplayImage], options: SelectionOptions = .current, completion: @escaping (Outcome) -> Void) {
        self.completion = completion
        windows = displays.map { display in
            let window = OverlayWindow(display: display, options: options)
            window.overlayView.onFinish = { [weak self] outcome in self?.finish(outcome) }
            return window
        }
        // A display added, removed, or re-moded leaves the overlays over screens that no longer
        // exist, and once the user switches to another app the picker gets no keys, not even
        // Escape: either way it cancels.
        let cancel: @Sendable (Notification) -> Void = { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.finish(.cancelled) }
        }
        observers = [
            (.default, NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: cancel)),
            (NSWorkspace.shared.notificationCenter,
             NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: cancel)),
        ]
    }

    /// The picker's own windows, which a live capture leaves out.
    public var windowNumbers: Set<Int> { Set(windows.map(\.windowNumber)) }

    public func show() {
        for window in windows {
            window.orderFrontRegardless()
        }
        // Shotts is not activated: activating an app brings all its windows forward, and an open
        // editor would jump in front of what is about to be captured. The overlays are
        // non-activating panels, which take keys and clicks while the app in front stays in
        // front. Keys go to the display the pointer is on.
        let mouse = NSEvent.mouseLocation
        for window in windows { window.makeFirstResponder(window.overlayView) }
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKeyAndOrderFront(nil)
        // Start with the crosshair where the pointer already is, not at a corner waiting for
        // the first movement.
        for window in windows {
            window.overlayView.pointerMoved(to: window.convertPoint(fromScreen: mouse))
        }
        // The crosshair is the pointer while the picker is up; an arrow beside it would only
        // add a second, offset hotspot to look at. An app that is not active may not hide the
        // pointer, so the overlays also show a blank one (`OverlayView.resetCursorRects`).
        NSCursor.hide()
    }

    /// Closes the picker, as Escape would.
    public func cancel() { finish(.cancelled) }

    private func finish(_ outcome: Outcome) {
        guard let completion else { return }
        self.completion = nil
        observers.forEach { $0.center.removeObserver($0.token) }
        observers = []
        NSCursor.unhide()
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll() // and with them the display images
        completion(outcome)
    }
}

/// A non-activating panel: it takes keys and clicks without making Shotts the active app, so
/// nothing on screen is reordered by pressing the hot key.
final class OverlayWindow: NSPanel {
    let overlayView: OverlayView

    init(display: DisplayImage, options: SelectionOptions) {
        overlayView = OverlayView(display: display, options: options)
        // The four-argument initializer is the designated one; the variant taking a screen
        // calls it, which a subclass must therefore provide.
        super.init(contentRect: display.screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        level = .screenSaver
        // Live, the real screen shows through, still updating, shadows and all.
        isOpaque = !display.isLive
        backgroundColor = display.isLive ? .clear : .black
        // A clear window lets clicks through to what is under it unless told otherwise.
        ignoresMouseEvents = false
        // No animation as the window appears: a pointer-entered event sent while it animates in
        // reports a position scaled away from the screen's center, and the crosshair follows it.
        animationBehavior = .none
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = overlayView
        // The view, not the window, gets the keys and the modifier changes: Command, Space,
        // Shift, the arrows, and Escape.
        initialFirstResponder = overlayView
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
    private(set) var selection: CGRect?
    /// Where the pointer is on this display. Nil while it is on another display, which then
    /// shows no crosshair, magnifier, hints, or window outline: there is one pointer.
    private(set) var pointer: CGPoint?
    private var moving = false
    /// The selection is red: letting go of the drag records the area rather than capturing it.
    /// Pressing Command turns it on, and pressing it again off; letting go of Command does
    /// neither, so a Command released a moment before the mouse, as happens when both are let
    /// go together, still records. What the selection shows is what letting go does.
    private(set) var records = false
    /// Whether Command is down, to tell a press from a key held.
    private var commandDown = false
    /// Whether Option is down: a click on a window then captures all of it as it is scrolled,
    /// the window's outline blue, unless Command's red says it records.
    private(set) var scrolls = false
    /// Whether the drag is squaring the selection, which the arrow keys keep doing.
    private var squaring = false
    /// Moves the real pointer to a point in global display coordinates (origin at the primary
    /// display's top-left), so a click or drag goes on from where the arrow keys put the
    /// crosshair. Tests replace it: they never move the pointer.
    var warp: (CGPoint) -> Void = { CGWarpMouseCursorPosition($0) }
    /// Where the drag is, on this display or past its edge.
    private var lastPointer: CGPoint = .zero
    private var hasDragged = false
    private var tracking: NSTrackingArea?
    /// Where the magnifier was last drawn: a new frame redraws only that.
    private var magnifierPanel: CGRect?

    /// What a click would take, while nothing is being dragged: the frontmost window under the
    /// pointer, or on the desktop the whole display.
    var hoveredTarget: (rect: CGRect, isWindow: Bool)? {
        guard anchor == nil, selection == nil, let pointer else { return nil }
        return SelectionRule.clickTarget(at: pointer, windows: display.windows.map(\.frame), bounds: bounds)
    }

    /// The window under the pointer, if a click would take one.
    var hoveredWindow: CGRect? { hoveredTarget.flatMap { $0.isWindow ? $0.rect : nil } }

    init(display: DisplayImage, options: SelectionOptions) {
        self.display = display
        self.options = options
        super.init(frame: CGRect(origin: .zero, size: display.screen.frame.size))
        wantsLayer = true
        display.onChange = { [weak self] in
            guard let self, let panel = magnifierPanel else { return }
            setNeedsDisplay(panel.insetBy(dx: -2, dy: -2))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// A blank pointer over the picker: the crosshair stands in for it, and an app that is not
    /// active may not hide the pointer outright.
    static let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: Self.blankCursor)
    }

    /// Command-C, whether or not the key reaches the main menu of an app that is not active.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers == "c" else { return super.performKeyEquivalent(with: event) }
        copy(nil)
        return true
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    #if DEBUG
    /// For previews: the state a real session would reach with the pointer here after a drag.
    func preview(pointer: CGPoint, selection: CGRect?) {
        self.pointer = pointer
        self.selection = selection
        hasDragged = selection != nil
    }
    #endif

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        takeKeys()
        pointerMoved(to: event.locationInWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        takeKeys()
        pointerMoved(to: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        pointer = nil
        needsDisplay = true
    }

    /// Keys follow the pointer, so Command-C, Space, and Escape act on the display the user is on.
    private func takeKeys() {
        if window?.isKeyWindow == false { window?.makeKey() }
    }

    /// `location` in the window's coordinates.
    func pointerMoved(to location: NSPoint) {
        let p = convert(location, from: nil)
        pointer = bounds.contains(p) ? p : nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        pressed(at: convert(event.locationInWindow, from: nil))
        // Command already down as the drag begins records from the start.
        commandDown = Self.held(event).contains(.command)
        records = commandDown
        scrolls = Self.held(event).contains(.option)
    }

    /// `p` in the view's coordinates.
    func pressed(at p: CGPoint) {
        anchor = p
        pointer = p
        lastPointer = p
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let held = Self.held(event)
        // A press seen first here, should the modifier change itself not have arrived; this only
        // ever turns recording on, so a late event cannot undo a second press.
        if held.contains(.command), !records { commandChanged(true) }
        dragged(to: convert(event.locationInWindow, from: nil), square: held.contains(.shift))
    }

    /// The modifier keys down at `event`. The picker belongs to an app kept in the background,
    /// and a mouse event reaching it may carry no modifier flags though a key is held, so the
    /// keyboard's own state counts too.
    static func held(_ event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.union(NSEvent.modifierFlags)
    }

    /// Command went down or up. Each press flips the selection between capturing and recording
    /// (red, reading "Record"); letting go of the key changes nothing.
    func commandChanged(_ down: Bool) {
        // Redrawn either way: the window or display a click would take is red while it is down.
        defer { commandDown = down; needsDisplay = true }
        guard down, !commandDown else { return }
        records.toggle()
    }

    /// `p` in the view's coordinates, which may be past the display's edge.
    func dragged(to p: CGPoint, square: Bool) {
        guard let anchor else { return }
        hasDragged = true
        squaring = square
        if moving, let current = selection {
            let moved = SelectionRule.moved(current, by: p - lastPointer, within: bounds)
            selection = moved
            // Keep the anchor with the moved rectangle so releasing Space continues the drag.
            self.anchor = CGPoint(x: anchor.x + (moved.minX - current.minX), y: anchor.y + (moved.minY - current.minY))
        } else {
            select(to: p, square: square)
        }
        lastPointer = p
        pointer = bounds.contains(p) ? p : nil
        needsDisplay = true
    }

    /// The selection from the anchor to `p`, clipped to this display as it is dragged: a
    /// selection stays on one display, and the size shown is the size cut.
    private func select(to p: CGPoint, square: Bool) {
        guard let anchor else { return }
        let rect = SelectionRule.rect(anchor: anchor, pointer: p, square: square).intersection(bounds)
        selection = rect.isNull ? nil : rect
    }

    /// Letting go records whenever the selection shows red: what the picker shows is what it does.
    override func mouseUp(with event: NSEvent) {
        released(at: convert(event.locationInWindow, from: nil), recording: records,
                 scrolling: Self.held(event).contains(.option))
    }

    /// `p` in the view's coordinates; `recording` when the selection is red as the drag ends;
    /// `scrolling` when Option is down then, which recording outranks and which matters only
    /// for a click on a window.
    func released(at p: CGPoint, recording: Bool, scrolling: Bool = false) {
        let scrolling = scrolling && !recording
        defer { anchor = nil }
        guard let rect = selection, SelectionRule.isUsable(rect) else {
            // A click without a drag takes the window under it, or on the desktop the whole
            // display: captured, or with Command recorded (a window's area, where it is now).
            selection = nil
            let target = SelectionRule.clickTarget(at: p, windows: display.windows.map(\.frame), bounds: bounds)
            if recording {
                onFinish?(.record(display: display, rect: target.rect))
            } else if scrolling, target.isWindow {
                onFinish?(.scroll(display: display, rect: target.rect))
            } else if target.isWindow, let window = display.windows.first(where: { $0.frame == target.rect }) {
                onFinish?(.window(display: display, window: window))
            } else {
                onFinish?(.selected(display: display, rect: target.rect))
            }
            return
        }
        onFinish?(recording ? .record(display: display, rect: rect) : .selected(display: display, rect: rect))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            onFinish?(.cancelled)
        case 49: // Space
            if anchor != nil { moving = true }
        case 123, 124, 125, 126:
            let far: Double = event.modifierFlags.contains(.shift) ? 10 : 1
            let direction = [123: CGPoint(x: -far, y: 0), 124: CGPoint(x: far, y: 0), 125: CGPoint(x: 0, y: far), 126: CGPoint(x: 0, y: -far)]
            nudge(by: direction[Int(event.keyCode)]!)
        default:
            super.keyDown(with: event)
        }
    }

    /// The crosshair, or the corner being dragged, `pixels` on, and the real pointer with it.
    func nudge(by pixels: CGPoint) {
        guard let from = anchor != nil ? lastPointer : pointer else { return }
        let to = SelectionRule.nudged(from, by: pixels, scale: display.scale, within: bounds)
        let screen = display.screen.frame, primary = NSScreen.screens.first?.frame.maxY ?? screen.maxY
        warp(CGPoint(x: screen.minX + to.x, y: primary - (screen.maxY - to.y)))
        if anchor != nil { dragged(to: to, square: squaring) } else { pointerMoved(to: convert(to, to: nil)) }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { moving = false }
    }

    override func flagsChanged(with event: NSEvent) {
        commandChanged(event.modifierFlags.contains(.command))
        if scrolls != event.modifierFlags.contains(.option) {
            scrolls = event.modifierFlags.contains(.option)
            needsDisplay = true
        }
        if anchor != nil, !moving {
            select(to: lastPointer, square: event.modifierFlags.contains(.shift))
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

    /// The picture's pixel under `p`.
    private func pixel(at p: CGPoint) -> (x: Int, y: Int) {
        (Int(floor(p.x * display.scale)), Int(floor(p.y * display.scale)))
    }

    /// The color under the crosshair; nil while the pointer is on another display.
    func colorUnderPointer() -> RGBA? {
        guard let pointer, let image = display.image else { return nil }
        let p = pixel(at: pointer)
        return PixelSampler.colors(in: CGRect(x: p.x, y: p.y, width: 1, height: 1), of: image)[0][0]
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if display.isLive {
            ctx.clear(dirtyRect)
        } else if let image = display.image {
            // A stand-in's picture. The bitmap's rows are stored top-first; flip around it.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .none
            ctx.draw(image, in: bounds)
            ctx.restoreGState()
        }

        // Everything outside a selection being dragged is dimmed, when the option is on.
        if let selection, options.dims {
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.35))
            ctx.addRect(bounds)
            ctx.addRect(selection)
            ctx.fillPath(using: .evenOdd)
        }

        if let selection {
            if records {
                // Red, and just outside the area, as the outline stays while it records.
                ctx.setStrokeColor(NSColor.systemRed.cgColor)
                ctx.setLineWidth(2)
                ctx.stroke(selection.insetBy(dx: -1, dy: -1))
            } else {
                ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
                ctx.setLineWidth(1)
                ctx.stroke(selection.insetBy(dx: -0.5, dy: -0.5))
            }
            // The magnifier's label shows the size, while it is on this display.
            if !options.magnifies || pointer == nil { drawSizeLabel(selection, in: ctx) }
        }

        // The rest follows the pointer, on the display it is on.
        guard let pointer else { return }
        if let target = hoveredTarget {
            // What a click would take, a window or the whole display; red while Command is
            // down, since the click would record it, and a window blue while Option is, since
            // the click would scroll it.
            let inset: CGFloat = target.isWindow ? 1 : 2
            let path = CGPath(roundedRect: target.rect.insetBy(dx: inset, dy: inset), cornerWidth: target.isWindow ? 10 : 6,
                              cornerHeight: target.isWindow ? 10 : 6, transform: nil)
            ctx.setStrokeColor(commandDown ? NSColor.systemRed.cgColor
                               : scrolls && target.isWindow ? NSColor.systemBlue.cgColor : NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(3)
            ctx.addPath(path)
            ctx.strokePath()
        }
        if selection == nil { drawCrosshair(at: pointer, in: ctx) }
        let magnifier = options.magnifies ? magnifier(at: pointer) : nil
        magnifierPanel = magnifier?.panel
        if let magnifier { drawMagnifier(magnifier, in: ctx) }
        if !hasDragged { drawHints(near: pointer, clearOf: magnifier?.panel, in: ctx) }
    }

    private func drawCrosshair(at p: CGPoint, in ctx: CGContext) {
        let x = floor(p.x) + 0.5, y = floor(p.y) + 0.5
        func lines() {
            ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: bounds.height))
            ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: bounds.width, y: y))
            ctx.strokePath()
        }
        // A dark edge under a light line: visible on any background.
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.45)); ctx.setLineWidth(3); lines()
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9)); ctx.setLineWidth(1); lines()
    }

    static let magnifierCells = 15
    static let magnifierCell: CGFloat = 8
    private static let labelHeight: CGFloat = 22
    /// The longest label (four-digit coordinates or size, and a color) fits the panel's fixed
    /// width; the digits are all one width.
    static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.white,
    ]

    /// One frame's magnifier, worked out once: drawing it and keeping the hints clear of it
    /// use the same panel, and the pixels around the pointer are sampled once.
    struct Magnifier {
        /// The whole panel: the pixel box in a frame two cells wide on the left, top, and right,
        /// and the label below it.
        var panel: CGRect
        /// The pixel box, inside the frame.
        var pixels: CGRect
        /// The picture's pixels shown, centered on the one under the pointer.
        var wanted: CGRect
        /// Their colors, row by row from the top; the center one is under the pointer.
        var colors: [[RGBA?]]
        var text: String
    }

    /// The neighborhood of `p` at 8 points per pixel, the pixel under it marked, its color
    /// below, and the selection's size while dragging. It sits below and right of the
    /// pointer, or on whichever side keeps it on screen.
    func magnifier(at p: CGPoint) -> Magnifier {
        let cells = Self.magnifierCells, half = cells / 2
        let box = CGFloat(cells) * Self.magnifierCell
        let center = pixel(at: p)
        let wanted = CGRect(x: center.x - half, y: center.y - half, width: cells, height: cells)
        let colors = display.image.map { PixelSampler.colors(in: wanted, of: $0) }
            ?? Array(repeating: Array(repeating: nil, count: cells), count: cells)
        let hex = colors[half][half]?.hex ?? ""
        // The pointer's pixel while aiming (a comma pair, as coordinates are written), the
        // selection's size while dragging (with ×, as sizes are), and the color under the pointer.
        let text: String
        if let selection, records {
            // The color matters little to a recording; the size it will have does.
            let size = display.pixelRect(for: selection).size
            text = "Record  \(Int(size.width)) × \(Int(size.height))"
        } else if let selection {
            let size = display.pixelRect(for: selection).size
            text = "\(Int(size.width)) × \(Int(size.height))   " + hex
        } else {
            text = "\(center.x),\(center.y)   " + hex
        }
        // One size always, whatever the label says: the pixels in a two-cell frame on three
        // sides, wide enough for the longest label, which goes below.
        let frame = Self.magnifierCell * 2
        let panel = Self.panelRect(size: CGSize(width: box + frame * 2, height: frame + box + Self.labelHeight), near: p, in: bounds, gap: 24)
        let pixels = CGRect(x: panel.minX + frame, y: panel.minY + frame, width: box, height: box)
        return Magnifier(panel: panel, pixels: pixels, wanted: wanted, colors: colors, text: text)
    }

    private func drawMagnifier(_ m: Magnifier, in ctx: CGContext) {
        let cells = Self.magnifierCells, cell = Self.magnifierCell, half = cells / 2
        let panel = m.panel, pixels = m.pixels

        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: panel, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.clip()
        // The pixels: a crop of the display around the pointer, scaled up with no smoothing.
        let available = m.wanted.intersection(display.pixelBounds)
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fill(CGRect(x: panel.minX, y: panel.minY, width: panel.width, height: pixels.maxY - panel.minY))
        if !available.isEmpty, let crop = display.image?.cropping(to: available) {
            let dest = CGRect(x: pixels.minX + (available.minX - m.wanted.minX) * cell,
                              y: pixels.minY + (available.minY - m.wanted.minY) * cell,
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
        // The crosshair, magnified with the pixels: four arms a cell wide that stop two cells
        // short of the pixel under the pointer, leaving it clear. Each cell of an arm is white
        // or black by the pixel under it, at half opacity either way, so the arms read on any
        // picture. No dark edge here: it hid the very pixels being looked at. They stay while
        // dragging, when the corner is being put on a pixel, though the crosshair across the
        // screen gives way to the selection's edges.
        let centerCell = CGRect(x: pixels.minX + CGFloat(half) * cell, y: pixels.minY + CGFloat(half) * cell, width: cell, height: cell)
        func arm(_ i: Int, _ j: Int) {
            let under = m.colors[j][i]
            ctx.setFillColor(CGColor(gray: under.map { $0.isLight ? 0 : 1 } ?? 1, alpha: 0.5))
            ctx.fill(CGRect(x: pixels.minX + CGFloat(i) * cell, y: pixels.minY + CGFloat(j) * cell, width: cell, height: cell))
        }
        for k in 0..<(half - 2) {
            arm(half, k); arm(half, cells - 1 - k)  // above and below
            arm(k, half); arm(cells - 1 - k, half)  // left and right
        }
        // The pixel under the pointer: a white box with a dark edge, like the crosshair itself.
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.8)); ctx.setLineWidth(3); ctx.stroke(centerCell.insetBy(dx: -1, dy: -1))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1)); ctx.setLineWidth(1); ctx.stroke(centerCell.insetBy(dx: -1, dy: -1))

        // The label: the color, and the selection size while dragging.
        let label = CGRect(x: panel.minX, y: pixels.maxY, width: panel.width, height: Self.labelHeight)
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 0.95))
        ctx.fill(label)
        let text = Self.label(m.text, recording: records)
        let textSize = text.size()
        text.draw(at: CGPoint(x: label.midX - textSize.width / 2, y: label.minY + (Self.labelHeight - textSize.height) / 2))
        ctx.restoreGState()

        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.6))
        ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.strokePath()
    }

    /// A label's words, behind a red dot while Command would record.
    static func label(_ text: String, recording: Bool) -> NSAttributedString {
        let label = NSMutableAttributedString(string: text, attributes: labelAttributes)
        if recording {
            var dot = labelAttributes
            dot[.foregroundColor] = NSColor.systemRed
            label.insert(NSAttributedString(string: "● ", attributes: dot), at: 0)
        }
        return label
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
        "Drag an area, or click a window or the desktop, to capture it",
        "⇧ keeps it square, Space moves it",
        "Arrow keys move a pixel, ⇧ ten",
        "⌘ while dragging or clicking records instead",
        "⌥-click a window to capture all of it, scrolled",
        "⌘C copies the color under the crosshair",
        "Esc cancels",
    ]
    private static let hintLineHeight: CGFloat = 17
    private static let hintAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12),
        .foregroundColor: NSColor.white,
    ]

    /// Where the keys go: in the corner above and left of `p`, the mirror of the magnifier's.
    private func hintsRect(near p: CGPoint) -> CGRect {
        let width = Self.hints.map { ($0 as NSString).size(withAttributes: Self.hintAttributes).width }.max()! + 20
        let size = CGSize(width: width, height: CGFloat(Self.hints.count) * Self.hintLineHeight + 10)
        var origin = CGPoint(x: p.x - 24 - size.width, y: p.y - 24 - size.height)
        if origin.x < bounds.minX { origin.x = p.x + 24 }
        if origin.y < bounds.minY { origin.y = p.y + 24 }
        return CGRect(origin: origin, size: size)
    }

    /// The keys, until the first drag. Near a corner the hints and the magnifier get pushed
    /// into the same quadrant; the magnifier wins, and the hints stay clear of its `panel`.
    private func drawHints(near p: CGPoint, clearOf panel: CGRect?, in ctx: CGContext) {
        let box = hintsRect(near: p)
        if let panel, box.intersects(panel) { return }
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 0.85))
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
        for (i, line) in Self.hints.enumerated() {
            (line as NSString).draw(at: CGPoint(x: box.minX + 10, y: box.minY + 5 + CGFloat(i) * Self.hintLineHeight), withAttributes: Self.hintAttributes)
        }
    }

    private func drawSizeLabel(_ rect: CGRect, in ctx: CGContext) {
        let size = display.pixelRect(for: rect).size
        let words = records ? "Record  " : ""
        let text = Self.label(words + "\(Int(size.width)) × \(Int(size.height))", recording: records)
        let textSize = text.size()
        var origin = CGPoint(x: rect.maxX - textSize.width - 6, y: rect.maxY + 6)
        if origin.y + textSize.height + 4 > bounds.height { origin.y = rect.maxY - textSize.height - 10 }
        origin.x = max(4, origin.x)
        let box = CGRect(x: origin.x - 4, y: origin.y - 2, width: textSize.width + 8, height: textSize.height + 4)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.7))
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.fillPath()
        text.draw(at: origin)
    }
}

/// Reads pixels of a bitmap by drawing them into a small context, so it works for any pixel
/// format the capture comes in.
public enum PixelSampler {
    /// The colors in a pixel rectangle, row by row from the top; `nil` outside the bitmap.
    public static func colors(in rect: CGRect, of image: CGImage) -> [[RGBA?]] {
        let w = Int(rect.width), h = Int(rect.height)
        var result = Array(repeating: Array(repeating: RGBA?.none, count: w), count: h)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return result }
        ctx.interpolationQuality = .none
        // Place the image so the rectangle's top-left lands at the context's top-left.
        ctx.draw(image, in: CGRect(x: -rect.minX, y: -(CGFloat(image.height) - rect.maxY), width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let data = ctx.data else { return result }
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for row in 0..<h {
            for col in 0..<w {
                let x = Int(rect.minX) + col, y = Int(rect.minY) + row
                guard x >= 0, y >= 0, x < image.width, y < image.height else { continue }
                let o = (row * w + col) * 4 // a bitmap context's first row in memory is its top
                result[row][col] = RGBA(red: Double(p[o]) / 255, green: Double(p[o + 1]) / 255, blue: Double(p[o + 2]) / 255)
            }
        }
        return result
    }
}

#if DEBUG
/// The picker's view alone, for drawing it off screen in a developer check.
public enum OverlayPreview {
    public static func make(display: DisplayImage, options: SelectionOptions, pointer: CGPoint, selection: CGRect?) -> NSView {
        let view = OverlayView(display: display, options: options)
        view.preview(pointer: pointer, selection: selection)
        return view
    }
}
#endif
