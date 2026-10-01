import AppKit
import ShottsCore

/// The recording window's timeline, under the video: play and pause, a playhead to click or
/// drag, a bracket at each end of the part kept that drags in to trim, and the time. What is
/// trimmed away is dimmed.
final class Timeline: NSView {
    let play = NSButton()
    let track: TrimTrack
    let time = NSTextField(labelWithString: "")

    init(duration: Double) {
        track = TrimTrack(duration: duration)
        super.init(frame: .zero)
        play.bezelStyle = .texturedRounded
        play.isBordered = false
        play.imagePosition = .imageOnly
        play.setAccessibilityLabel("Play")
        play.widthAnchor.constraint(equalToConstant: 28).isActive = true
        time.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        time.textColor = .secondaryLabelColor
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        track.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [play, track, time])
        row.orientation = .horizontal
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            track.heightAnchor.constraint(equalToConstant: 28),
        ])
        showPlaying(false)
        showTime()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func showPlaying(_ playing: Bool) {
        play.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        play.setAccessibilityLabel(playing ? "Pause" : "Play")
        play.toolTip = playing ? "Pause (Space)" : "Play (Space)"
    }

    var playhead: Double {
        get { track.playhead }
        set {
            track.playhead = newValue
            showTime()
        }
    }

    private func showTime() {
        time.stringValue = "\(RecordingRule.clock(track.playhead)) / \(RecordingRule.clock(track.duration))"
    }

}

/// The track: the whole recording across it, the part kept between two brackets, and the
/// playhead.
final class TrimTrack: NSView {
    let duration: Double
    var trim: Trim { didSet { needsDisplay = true } }
    var playhead: Double = 0 { didSet { needsDisplay = true } }
    /// The playhead moved by the user, to show that frame.
    var onSeek: ((Double) -> Void)?
    /// The trim changed; `done` once the drag ends, when a file is worth making.
    var onTrim: ((Trim, _ done: Bool) -> Void)?
    /// Space.
    var onToggle: (() -> Void)?

    private var dragging: TimelineLayout.Part?
    /// Room at each end for a bracket.
    private static let inset: CGFloat = 6

    init(duration: Double) {
        self.duration = duration
        trim = .whole(duration)
        super.init(frame: .zero)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Timeline: drag the brackets to trim")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var layout: TimelineLayout {
        TimelineLayout(width: max(bounds.width - Self.inset * 2, 1), duration: duration)
    }

    private func x(_ time: Double) -> CGFloat { Self.inset + layout.x(for: time) }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pressed(at: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseDragged(with event: NSEvent) {
        dragged(to: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        released()
    }

    /// `x` in the view's coordinates.
    func pressed(at x: CGFloat) {
        let part = layout.part(at: x - Self.inset, of: trim)
        dragging = part
        dragged(to: x)
    }

    func dragged(to x: CGFloat) {
        let time = layout.time(at: x - Self.inset)
        switch dragging {
        case .start?:
            trim = trim.movingStart(to: time)
            onTrim?(trim, false)
            onSeek?(trim.start)
        case .end?:
            trim = trim.movingEnd(to: time, duration: duration)
            onTrim?(trim, false)
            onSeek?(trim.end)
        case .track?:
            onSeek?(min(max(time, trim.start), trim.end))
        case nil:
            break
        }
    }

    func released() {
        if dragging == .start || dragging == .end { onTrim?(trim, true) }
        dragging = nil
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { onToggle?() } else { super.keyDown(with: event) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let mid = bounds.midY
        let full = CGRect(x: x(0), y: mid - 3, width: x(duration) - x(0), height: 6)
        NSColor(white: 1, alpha: 0.15).setFill()
        NSBezierPath(roundedRect: full, xRadius: 3, yRadius: 3).fill()
        let kept = CGRect(x: x(trim.start), y: mid - 3, width: x(trim.end) - x(trim.start), height: 6)
        NSColor(white: 1, alpha: 0.55).setFill()
        NSBezierPath(roundedRect: kept, xRadius: 3, yRadius: 3).fill()

        // Brackets, opening toward the part kept.
        NSColor.systemYellow.setStroke()
        for (time, facing) in [(trim.start, CGFloat(1)), (trim.end, CGFloat(-1))] {
            let hx = x(time)
            let bracket = NSBezierPath()
            bracket.move(to: CGPoint(x: hx + facing * 5, y: mid - 11))
            bracket.line(to: CGPoint(x: hx, y: mid - 11))
            bracket.line(to: CGPoint(x: hx, y: mid + 11))
            bracket.line(to: CGPoint(x: hx + facing * 5, y: mid + 11))
            bracket.lineWidth = 3
            bracket.lineCapStyle = .round
            bracket.lineJoinStyle = .round
            bracket.stroke()
        }

        // The playhead.
        let px = x(playhead)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: CGRect(x: px - 1, y: mid - 9, width: 2, height: 18), xRadius: 1, yRadius: 1).fill()
    }
}
