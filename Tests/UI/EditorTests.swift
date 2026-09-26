import AppKit
import ShottsCore
import Testing
@testable import ShottsUI

@MainActor @Suite struct TextEntryTests {
    @Test func typedTextLandsAsOneAnnotation() {
        let canvas = canvasInWindow()
        canvas.beginTextEntry(at: CGPoint(x: 40, y: 40), initial: "Hello", style: canvas.style)
        canvas.typeText("Hello there")
        canvas.endTextEntry(commit: true)
        #expect(canvas.document.annotations.count == 1)
        guard case let .text(_, string, size, _)? = canvas.document.annotations.first?.shape else { Issue.record("no text"); return }
        #expect(string == "Hello there" && size.width > 0 && size.height > 0)
    }

    @Test func calloutWordsLandRightJustifiedAgainstTheTail() {
        let canvas = canvasInWindow()
        let tail = CGPoint(x: 300, y: 150), tip = CGPoint(x: 380, y: 100)
        let callout = Annotation(shape: .callout(from: tail, to: tip, text: Annotation.TextBox(origin: .zero, string: "", size: .zero, alignment: .left)),
                                 style: canvas.style)
        var d = canvas.document
        d.add(callout)
        canvas.commit(d)
        canvas.editCalloutText(callout.id, from: tail, to: tip, initial: "", style: canvas.style)
        canvas.typeText("wrapped words beside the tail of the arrow")
        canvas.endTextEntry(commit: true)
        guard case let .callout(from, _, text)? = canvas.document.annotations.last?.shape else { Issue.record("no callout"); return }
        #expect(from == tail)
        #expect(text.string.hasPrefix("wrapped") && text.alignment == .right && text.size.width > 0)
        #expect(text.frame.maxX <= tail.x)
    }
}

@MainActor @Suite struct ResizeTests {
    /// A 1600 by 1000 Retina capture opens at its on-screen size, shrinks with its window keeping
    /// its proportions, and never grows past its on-screen size.
    @Test func zoomFollowsTheWindow() throws {
        let controller = EditorWindowController(document: Document(width: 1600, height: 1000, scale: 2), source: blankImage(1600, 1000))
        let window = try #require(controller.window)
        let natural = controller.canvas.zoom
        #expect(natural == 0.5)

        // A drag to a content area of 1000 by 400: the height limits, the width floor holds.
        let asked = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 1000, height: 400)).size
        let snug = window.contentRect(forFrameRect: NSRect(origin: .zero, size: controller.windowWillResize(window, to: asked))).size
        let zoom = (snug.height - controller.layout.barHeight - CanvasView.inset * 2) / 1000
        #expect(zoom < natural)
        #expect(abs(snug.width - controller.layout.minimumWidth) < 0.5)
        #expect(abs(snug.height - (controller.layout.barHeight + 1000 * zoom + CanvasView.inset * 2)) < 1)
        window.setContentSize(snug)
        #expect(abs(controller.canvas.zoom - zoom) < 0.001)
        #expect(controller.canvas.pictureRect.width < 1600 * natural)

        window.setContentSize(NSSize(width: 3000, height: 2000))
        #expect(controller.canvas.zoom == natural)
    }

    /// A capture as big as the screen opens smaller, inside the screen's visible frame.
    @Test func aScreenSizedCaptureOpensInsideTheScreen() throws {
        let screen = try #require(NSScreen.main)
        let scale = screen.backingScaleFactor
        let w = Int(screen.frame.width * scale), h = Int(screen.frame.height * scale)
        let controller = EditorWindowController(document: Document(width: w, height: h, scale: scale), source: blankImage(w, h), on: screen)
        let frame = try #require(controller.window?.frame)
        #expect(frame.width <= screen.visibleFrame.width + 0.5 && frame.height <= screen.visibleFrame.height + 0.5)
        #expect(controller.canvas.zoom < 1 / scale)
    }
}
