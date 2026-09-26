import AppKit
import ShottsCore

/// The popover behind the editor's color swatch: a grid of colors, a custom color, and the
/// switches for how annotations are drawn.
final class StylePopover: NSViewController {
    var style: Style
    var onStyle: ((Style) -> Void)?

    private var swatches: [NSButton] = []
    private let shadow = NSButton(checkboxWithTitle: "Shadow", target: nil, action: nil)
    private let outline = NSButton(checkboxWithTitle: "Outline on text", target: nil, action: nil)
    private let tapered = NSButton(checkboxWithTitle: "Tapered arrows", target: nil, action: nil)
    private static let names = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Pink", "Gray", "White", "Black"]

    init(style: Style) {
        self.style = style
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let grid = NSGridView()
        grid.rowSpacing = 6
        grid.columnSpacing = 6
        grid.xPlacement = .center
        let perRow = 5
        var row: [NSView] = []
        for (i, color) in RGBA.palette.enumerated() {
            let button = NSButton(image: Self.swatch(color, size: 26), target: self, action: #selector(swatchPicked(_:)))
            button.isBordered = false
            button.tag = i
            button.toolTip = Self.names[i]
            button.setAccessibilityLabel(Self.names[i])
            button.setButtonType(.momentaryChange)
            swatches.append(button)
            row.append(button)
            if row.count == perRow {
                grid.addRow(with: row)
                row = []
            }
        }
        for i in 0..<perRow { grid.column(at: i).width = 30 }
        let custom = NSButton(title: "Custom…", target: self, action: #selector(customColor))
        custom.bezelStyle = .texturedRounded
        custom.controlSize = .small

        for box in [shadow, outline, tapered] {
            box.target = self
            box.action = #selector(switchesChanged)
        }
        show(style)

        let line = separator()
        let column = NSStackView(views: [grid, custom, line, shadow, outline, tapered])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        column.setCustomSpacing(10, after: grid)
        // The separator spans whatever the widest row needs.
        line.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -24).isActive = true
        view = column
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    func show(_ style: Style) {
        self.style = style
        for (i, button) in swatches.enumerated() {
            button.image = Self.swatch(RGBA.palette[i], size: 26, selected: RGBA.palette[i] == style.color)
        }
        shadow.state = style.shadow ? .on : .off
        outline.state = style.outline ? .on : .off
        tapered.state = style.taperedArrows ? .on : .off
    }

    @objc private func swatchPicked(_ sender: NSButton) {
        style.color = RGBA.palette[sender.tag]
        show(style)
        onStyle?(style)
    }

    @objc private func customColor() {
        let panel = NSColorPanel.shared
        panel.color = NSColor(srgbRed: style.color.red, green: style.color.green, blue: style.color.blue, alpha: 1)
        panel.showsAlpha = false
        // One change when the pointer is released, not one per step of a drag across the wheel:
        // each change restyles the selection, and each restyle is an undo step.
        panel.isContinuous = false
        panel.setTarget(self)
        panel.setAction(#selector(panelColorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func panelColorChanged(_ panel: NSColorPanel) {
        guard let c = panel.color.usingColorSpace(.sRGB) else { return }
        style.color = RGBA(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
        show(style)
        onStyle?(style)
    }

    @objc private func switchesChanged() {
        style.shadow = shadow.state == .on
        style.outline = outline.state == .on
        style.taperedArrows = tapered.state == .on
        onStyle?(style)
    }

    /// A round swatch; the selected one has a ring.
    static func swatch(_ c: RGBA, size: CGFloat, selected: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset = rect.insetBy(dx: 3, dy: 3)
            NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1).setFill()
            NSBezierPath(ovalIn: inset).fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            NSBezierPath(ovalIn: inset).stroke()
            if selected {
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                NSColor.controlAccentColor.setStroke()
                ring.stroke()
            }
            return true
        }
    }
}

#if DEBUG
/// The popover's content alone, for drawing it off screen in a check.
public enum StylePopoverPreview {
    public static func write(to output: URL) -> Bool {
        // Controls draw their titles only inside a window; this one is never ordered in.
        let controller = StylePopover(style: .standard)
        let window = NSWindow(contentViewController: controller)
        window.appearance = NSAppearance(named: .darkAqua)
        let view = controller.view
        view.layoutSubtreeIfNeeded()
        window.setContentSize(view.fittingSize)
        view.frame = CGRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        // Drawn over the popover's dark background, so white text is visible in the PNG.
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        rep.size = view.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.scaleBy(x: scale, y: scale)
        NSColor(white: 0.17, alpha: 1).setFill()
        view.bounds.fill()
        view.displayIgnoringOpacity(view.bounds, in: ctx)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: output); return true } catch { return false }
    }
}
#endif
