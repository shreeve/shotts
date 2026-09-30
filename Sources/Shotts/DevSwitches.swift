#if DEBUG
import AppKit
import AVFoundation
import ShottsCore
import ShottsUI

/// The developer switches, for checking by eye what tests cannot show. Compiled into debug
/// builds only: a release app that took `--capture-window` would let any local process capture
/// any window under Shotts' Screen Recording grant, and the file switches would read and write
/// wherever Shotts may.
enum DevSwitches {
    /// Keeps the `--select` picker alive; it calls back once, to nothing, without an owner.
    private static var selection: AreaSelection?

    /// Acts on the switches in `arguments`; `open` puts a file in the editor as Open Image… does.
    static func run(_ arguments: [String], open: (URL) -> Void) {
        func value(after flag: String, _ n: Int = 1) -> [String]? {
            guard let i = arguments.firstIndex(of: flag), i + n < arguments.count else { return nil }
            return Array(arguments[(i + 1)...(i + n)])
        }
        if let v = value(after: "--edit") {
            open(URL(fileURLWithPath: v[0]))
        }
        if let v = value(after: "--select") {
            // The area selection alone, on a drawn stand-in for each display (no Screen
            // Recording needed): writes the outcome to the file and quits.
            let out = URL(fileURLWithPath: v[0])
            selection = AreaSelection(displays: NSScreen.screens.map(standIn)) { outcome in
                let line: String
                switch outcome {
                case .cancelled: line = "cancelled"
                case let .selected(display, rect): line = "selected \(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height)) on \(display.screen.localizedName)"
                case let .window(display, window): line = "window \(window.id) at \(Int(window.frame.minX)),\(Int(window.frame.minY)) on \(display.screen.localizedName)"
                case let .record(display, rect): line = "record \(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height)) on \(display.screen.localizedName)"
                }
                try? line.write(to: out, atomically: true, encoding: .utf8)
                exit(0)
            }
            selection?.show()
        }
        if let v = value(after: "--preview-overlay") {
            // The picker's drawing, off screen: the stand-in display with the pointer and a
            // selection placed, written as a PNG.
            exit(previewOverlay(to: URL(fileURLWithPath: v[0]), selected: arguments.contains("--dragged"),
                                dimmed: arguments.contains("--dim"), corner: arguments.contains("--corner")) ? 0 : 1)
        }
        if let v = value(after: "--print-pdf", 2) {
            // Printing: the sample's page written as a PDF.
            guard let (document, cg) = sample(from: URL(fileURLWithPath: v[0]), crop: arguments.contains("--crop")) else { exit(1) }
            exit(EditorWindowController.printPDF(document, source: cg, to: URL(fileURLWithPath: v[1])) ? 0 : 1)
        }
        if let v = value(after: "--preview-style") {
            // The style popover's layout, drawn off screen.
            exit(StylePopoverPreview.write(to: URL(fileURLWithPath: v[0])) ? 0 : 1)
        }
        if let v = value(after: "--export-recording", 2) {
            // A recording's export, from any movie standing in for one (its sound as the Mac's,
            // and `--microphone file` as the microphone), as the recording window makes it:
            // `--width`, `--fps`, and `--sound none|system|microphone|both`; the format by the
            // output's extension.
            let out = URL(fileURLWithPath: v[1])
            let microphone = value(after: "--microphone").map { URL(fileURLWithPath: $0[0]) }
            let width = value(after: "--width").flatMap { Int($0[0]) }
            let rate = value(after: "--fps").flatMap { Int($0[0]) }
            let sound = value(after: "--sound").flatMap { RecordingSettings.Sound(rawValue: $0[0]) }
            Task {
                exit(await exportRecording(URL(fileURLWithPath: v[0]), microphone: microphone, to: out, width: width, rate: rate, sound: sound) ? 0 : 1)
            }
        }
        if let v = value(after: "--capture-window", 2), let id = CGWindowID(v[0]) {
            // Window capture: the window with that id, with its shadow unless --no-shadow,
            // written as a PNG.
            let out = URL(fileURLWithPath: v[1])
            let shadow = !arguments.contains("--no-shadow")
            Task {
                do {
                    let (image, scale) = try await ScreenCapture.captureWindow(id, shadow: shadow)
                    try Export.write(Document(width: image.width, height: image.height, scale: scale), source: image, to: out)
                    exit(0)
                } catch {
                    fputs("capture failed: \(error)\n", stderr)
                    exit(1)
                }
            }
            return
        }
        if let v = value(after: "--render", 2) {
            // The renderer: every kind of annotation on the given picture, written as a PNG,
            // no window.
            exit(renderSample(from: URL(fileURLWithPath: v[0]), to: URL(fileURLWithPath: v[1]), crop: arguments.contains("--crop")) ? 0 : 1)
        }
    }

    /// A picture standing in for a display: a gradient with a few marks, so the magnifier and
    /// the color readout have something to show.
    static func standIn(for screen: NSScreen) -> DisplayImage {
        let scale = screen.backingScaleFactor
        let w = Int(screen.frame.width * scale), h = Int(screen.frame.height * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let colors = [CGColor(srgbRed: 0.34, green: 0.63, blue: 0.81, alpha: 1), CGColor(srgbRed: 0.1, green: 0.2, blue: 0.4, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.8, blue: 0.2, alpha: 1))
        // The context's y runs upward; place each square so it lands at (i, i) from the top.
        for i in stride(from: 100, to: min(w, h), by: 300) {
            ctx.fill(CGRect(x: i, y: h - i - 40, width: 40, height: 40))
        }
        // One "window" for the picker to outline, at 700,700 points, 600 by 400.
        return DisplayImage(screen: screen, image: ctx.makeImage()!, scale: scale,
                            windows: [WindowInfo(id: 0, frame: CGRect(x: 700, y: 700, width: 600, height: 400))])
    }

    static func exportRecording(_ movie: URL, microphone: URL?, to out: URL, width: Int?, rate: Int?, sound: RecordingSettings.Sound?) async -> Bool {
        do {
            let asset = AVURLAsset(url: movie)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return false }
            let size = try await track.load(.naturalSize)
            let recording = Recording(folder: out.deletingLastPathComponent(), movie: movie, microphone: microphone,
                                      width: Int(size.width), height: Int(size.height), scale: 2, started: .now)
            let format: RecordingSettings.Format = out.pathExtension.lowercased() == "gif" ? .gif : .mp4
            let contents = try await RecordingExport.contents(of: recording)
            var settings = RecordingRule.defaults(for: format, recorded: (recording.width, recording.height), scale: 2,
                                                  hasMicrophone: contents.hasMicrophone)
            if let width { settings.width = width }
            if let rate { settings.frameRate = rate }
            if let sound { settings.sound = sound }
            let started = Date.now
            try await RecordingExport.write(recording, settings: settings, to: out)
            print("\(settings) in \(String(format: "%.2f", Date.now.timeIntervalSince(started))) s")
            return true
        } catch {
            print(error.localizedDescription)
            return false
        }
    }

    static func previewOverlay(to output: URL, selected: Bool, dimmed: Bool, corner: Bool) -> Bool {
        guard let screen = NSScreen.main else { return false }
        let display = standIn(for: screen)
        var options = SelectionOptions()
        options.dims = dimmed
        // The pointer lands 3 pixels inside the corner of the stand-in's square at 1600,1600,
        // so the magnifier must show that corner 6 cells up and left of its center. With
        // --corner it sits near the display's top-left instead, where the panels collide.
        let pointer = corner ? CGPoint(x: 30, y: 40)
            : CGPoint(x: (1600 + 3) / display.scale + 0.25, y: (1600 + 3) / display.scale + 0.25) // inside the stand-in window too
        let view = OverlayPreview.make(display: display, options: options, pointer: pointer,
                                       selection: selected ? CGRect(x: pointer.x - 320, y: pointer.y - 200, width: 320, height: 200) : nil)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: output); return true } catch { return false }
    }

    private static func renderSample(from input: URL, to output: URL, crop: Bool) -> Bool {
        guard let (document, cg) = sample(from: input, crop: crop) else { return false }
        do {
            try Export.write(document, source: cg, to: output)
            return true
        } catch {
            fputs("render failed: \(error)\n", stderr)
            return false
        }
    }

    /// The picture with one of every annotation on it, cropped with `crop`.
    private static func sample(from input: URL, crop: Bool) -> (Document, CGImage)? {
        guard let image = NSImage(contentsOf: input),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = Double(cg.width), h = Double(cg.height)
        var document = Document(width: cg.width, height: cg.height, scale: 2)
        let style = Style.standard
        var blue = style; blue.color = .blue
        var yellow = style; yellow.color = .yellow
        var big = style; big.fontSize = 36; big.font = .openSans
        var even = style; even.taperedArrows = false
        document.add(Annotation(shape: .arrow(from: CGPoint(x: w * 0.15, y: h * 0.75), to: CGPoint(x: w * 0.4, y: h * 0.45)), style: style))
        document.add(Annotation(shape: .arrow(from: CGPoint(x: w * 0.4, y: h * 0.75), to: CGPoint(x: w * 0.2, y: h * 0.55)), style: even))
        document.add(Annotation(shape: .rectangle(CGRect(x: w * 0.45, y: h * 0.2, width: w * 0.3, height: h * 0.25)), style: blue))
        document.add(Annotation(shape: .ellipse(CGRect(x: w * 0.6, y: h * 0.55, width: w * 0.25, height: h * 0.2)), style: style))
        document.add(Annotation(shape: .ellipse(CGRect(x: w * 0.88, y: h * 0.3, width: h * 0.1, height: h * 0.1), filled: true), style: yellow))
        document.add(Annotation(shape: .line(from: CGPoint(x: w * 0.45, y: h * 0.52), to: CGPoint(x: w * 0.8, y: h * 0.52)), style: blue))
        document.add(Annotation(shape: .highlighter([CGPoint(x: w * 0.1, y: h * 0.15), CGPoint(x: w * 0.4, y: h * 0.16)]), style: yellow))
        document.add(Annotation(shape: .pen((0...20).map { i in CGPoint(x: w * 0.1 + Double(i) * w * 0.015, y: h * 0.9 + sin(Double(i) / 2) * h * 0.03) }), style: blue))
        document.add(Annotation(shape: .obscure(CGRect(x: w * 0.7, y: h * 0.8, width: w * 0.2, height: h * 0.12)), style: style))
        let text = "This is impossible to use!"
        document.add(Annotation(shape: .text(origin: CGPoint(x: w * 0.15, y: h * 0.3), string: text, size: Renderer.textSize(text, style: big, scale: 2)), style: big))
        // Callouts: an arrow with its words wrapped beside the tail on the side away from the tip.
        func callout(_ tail: CGPoint, _ tip: CGPoint, _ words: String, _ style: Style, maxWidth: Double) -> Annotation {
            let layout = CalloutLayout(tail: tail, tip: tip, lineHeight: Renderer.lineHeight(style: style, scale: 2), maxWidth: maxWidth, in: document.pixelBounds)
            let size = Renderer.textSize(words, style: style, scale: 2, width: layout.width)
            let box = Annotation.TextBox(origin: layout.origin(for: size), string: words, size: size, alignment: layout.alignment)
            return Annotation(shape: .callout(from: tail, to: tip, text: box), style: style)
        }
        document.add(callout(CGPoint(x: w * 0.55, y: h * 0.9), CGPoint(x: w * 0.85, y: h * 0.7),
                             "A callout wraps its words beside the tail and stays inside the picture", style, maxWidth: w * 0.3))
        // And a vertical one: text centered above the tail of an arrow pointing down.
        document.add(callout(CGPoint(x: w * 0.3, y: h * 0.6), CGPoint(x: w * 0.32, y: h * 0.85), "centered above, growing up", blue, maxWidth: w * 0.25))
        if crop {
            document.setCrop(CGRect(x: w * 0.1, y: h * 0.1, width: w * 0.6, height: h * 0.5))
        }
        return (document, cg)
    }
}
#endif
