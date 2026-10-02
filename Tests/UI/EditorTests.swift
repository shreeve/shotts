import AppKit
import ShottsCore
import Testing
@testable import ShottsUI

@MainActor @Suite struct TextEntryTests {
    @Test func typedTextLandsAsOneAnnotation() {
        let canvas = canvasInWindow()
        canvas.beginTextEntry(at: CGPoint(x: 40, y: 40), initial: "Hello", style: canvas.style)
        canvas.typeText("Hello there")
        canvas.endTextEntry()
        #expect(canvas.document.annotations.count == 1)
        guard case let .text(_, string, size, _)? = canvas.document.annotations.first?.shape else { Issue.record("no text"); return }
        #expect(string == "Hello there" && size.width > 0 && size.height > 0)
    }

    /// Return, Shift-Return, and Option-Return start a new line; only Command-Return finishes.
    @Test func onlyCommandReturnFinishes() throws {
        let canvas = canvasInWindow()
        canvas.beginTextEntry(at: CGPoint(x: 40, y: 40), initial: "", style: canvas.style)
        let entry = try #require(canvas.textField)
        func key(_ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: canvas.window!.windowNumber,
                             context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        }
        for (words, flags) in [("one", NSEvent.ModifierFlags()), ("two", .shift), ("three", .option)] {
            entry.insertText(words, replacementRange: NSRange(location: NSNotFound, length: 0))
            entry.keyDown(with: key(flags))
            #expect(canvas.textField != nil)
        }
        entry.insertText("four", replacementRange: NSRange(location: NSNotFound, length: 0))
        entry.keyDown(with: key(.command))
        #expect(canvas.textField == nil)
        guard case let .text(_, words, _, _)? = canvas.document.annotations.first?.shape else { Issue.record("no text"); return }
        #expect(words == "one\ntwo\nthree\nfour")
    }

    /// Escape cancels typing whole: a new text is never added.
    @Test func escapeDropsANewText() {
        let canvas = canvasInWindow()
        canvas.beginTextEntry(at: CGPoint(x: 40, y: 40), initial: "", style: canvas.style)
        canvas.typeText("never mind")
        #expect(canvas.cancelCurrent())
        #expect(canvas.textField == nil && canvas.document.annotations.isEmpty && !canvas.history.canUndo)
    }

    /// Escape on a new arrow with text removes the arrow too: "I didn't mean to start this."
    @Test func escapeDropsANewCalloutWithItsArrow() {
        let canvas = canvasInWindow()
        canvas.tool = .callout
        Mouse(canvas: canvas).stroke(CGPoint(x: 100, y: 150), CGPoint(x: 300, y: 100))
        canvas.typeText("oops")
        #expect(canvas.cancelCurrent())
        #expect(canvas.document.annotations.isEmpty && !canvas.history.canUndo)
    }

    /// Escape while re-editing words puts them back as they were, the text still in its place.
    @Test func escapePutsEditedWordsBack() throws {
        let canvas = canvasInWindow()
        canvas.beginTextEntry(at: CGPoint(x: 40, y: 40), initial: "", style: canvas.style)
        canvas.typeText("first")
        canvas.endTextEntry()
        let before = canvas.document
        let text = try #require(before.annotations.first)
        canvas.tool = .select
        Mouse(canvas: canvas).doubleClick(CGPoint(x: text.bounds.midX, y: text.bounds.midY))
        canvas.typeText("second")
        #expect(canvas.cancelCurrent())
        #expect(canvas.document == before)
    }

    @Test func calloutWordsLandRightJustifiedAgainstTheTail() {
        let canvas = canvasInWindow()
        let tail = CGPoint(x: 300, y: 150), tip = CGPoint(x: 380, y: 100)
        let callout = Annotation(shape: .callout(from: tail, to: tip, text: Annotation.TextBox(origin: .zero, string: "", size: .zero, alignment: .left)),
                                 style: canvas.style)
        var d = canvas.document
        d.add(callout)
        canvas.commit(d)
        canvas.editText(callout.id)
        canvas.typeText("wrapped words beside the tail of the arrow")
        canvas.endTextEntry()
        guard case let .callout(from, _, text)? = canvas.document.annotations.last?.shape else { Issue.record("no callout"); return }
        #expect(from == tail)
        #expect(text.string.hasPrefix("wrapped") && text.alignment == .right && text.size.width > 0)
        #expect(text.frame.maxX <= tail.x)
    }
}

/// Mouse events at picture pixels, for a canvas in a window that is never shown.
@MainActor struct Mouse {
    let canvas: CanvasView

    func event(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let picture = canvas.pictureRect
        let inView = CGPoint(x: picture.minX + p.x * canvas.zoom, y: picture.minY + p.y * canvas.zoom)
        return NSEvent.mouseEvent(with: type, location: canvas.convert(inView, to: nil), modifierFlags: flags, timestamp: 0,
                                  windowNumber: canvas.window!.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    func down(_ p: CGPoint, clicks: Int = 1) { canvas.mouseDown(with: event(.leftMouseDown, p, clicks: clicks)) }
    func drag(_ p: CGPoint) { canvas.mouseDragged(with: event(.leftMouseDragged, p)) }
    func up(_ p: CGPoint, clicks: Int = 1) { canvas.mouseUp(with: event(.leftMouseUp, p, clicks: clicks)) }

    func stroke(_ from: CGPoint, _ to: CGPoint) {
        down(from); drag(CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)); drag(to); up(to)
    }

    func doubleClick(_ p: CGPoint) { down(p); up(p); down(p, clicks: 2); up(p, clicks: 2) }
}

@MainActor @Suite struct EditingTests {
    @Test func aNewCalloutIsOneUndoStep() {
        let canvas = canvasInWindow()
        canvas.tool = .callout
        Mouse(canvas: canvas).stroke(CGPoint(x: 100, y: 150), CGPoint(x: 300, y: 100))
        canvas.typeText("look here")
        canvas.endTextEntry()
        guard case let .callout(_, _, text)? = canvas.document.annotations.first?.shape else { Issue.record("no callout"); return }
        #expect(text.string == "look here")
        canvas.undo(nil)
        #expect(canvas.document.annotations.isEmpty)
        #expect(!canvas.history.canUndo)
    }

    @Test func aCalloutLeftWithoutWordsIsAnArrowInOneStep() {
        let canvas = canvasInWindow()
        canvas.tool = .callout
        Mouse(canvas: canvas).stroke(CGPoint(x: 100, y: 150), CGPoint(x: 300, y: 100))
        canvas.endTextEntry()
        guard case .arrow? = canvas.document.annotations.first?.shape else { Issue.record("not an arrow"); return }
        canvas.undo(nil)
        #expect(canvas.document.annotations.isEmpty)
    }

    @Test func editingTextKeepsItsPlaceAndIsOneStep() throws {
        let canvas = canvasInWindow()
        let mouse = Mouse(canvas: canvas)
        canvas.beginTextEntry(at: CGPoint(x: 40, y: 40), initial: "", style: canvas.style)
        canvas.typeText("first")
        canvas.endTextEntry()
        canvas.tool = .rectangle
        mouse.stroke(CGPoint(x: 200, y: 200), CGPoint(x: 300, y: 280))
        let text = try #require(canvas.document.annotations.first)
        canvas.tool = .select
        let inside = CGPoint(x: text.bounds.midX, y: text.bounds.midY)
        mouse.doubleClick(inside)
        // The words stay visible while the entry is open.
        #expect(canvas.textField?.preview != nil)
        canvas.typeText("second")
        canvas.endTextEntry()
        #expect(canvas.document.annotations.count == 2)
        #expect(canvas.document.annotations.first?.id == text.id)
        guard case let .text(_, string, _, _)? = canvas.document.annotations.first?.shape else { Issue.record("no text"); return }
        #expect(string == "second")
        canvas.undo(nil)
        guard case let .text(_, before, _, _)? = canvas.document.annotations.first?.shape else { Issue.record("no text"); return }
        #expect(before == "first" && canvas.document.annotations.count == 2)
    }

    @Test func escapePutsAMoveBack() throws {
        let canvas = canvasInWindow()
        let mouse = Mouse(canvas: canvas)
        canvas.tool = .rectangle
        mouse.stroke(CGPoint(x: 40, y: 40), CGPoint(x: 140, y: 140))
        let before = canvas.document
        canvas.tool = .select
        mouse.down(CGPoint(x: 40, y: 90))
        mouse.drag(CGPoint(x: 100, y: 90))
        #expect(canvas.document != before)
        #expect(canvas.cancelCurrent())
        mouse.drag(CGPoint(x: 120, y: 90))
        mouse.up(CGPoint(x: 120, y: 90))
        #expect(canvas.document == before)
        canvas.undo(nil)
        #expect(canvas.document.annotations.isEmpty)
    }

    @Test func aDragWithoutItsMouseUpIsPutBackByTheNextClick() {
        let canvas = canvasInWindow()
        let mouse = Mouse(canvas: canvas)
        canvas.tool = .rectangle
        mouse.stroke(CGPoint(x: 40, y: 40), CGPoint(x: 140, y: 140))
        let before = canvas.document
        canvas.tool = .select
        mouse.down(CGPoint(x: 40, y: 90))
        mouse.drag(CGPoint(x: 100, y: 90)) // and the mouse-up never arrives
        mouse.down(CGPoint(x: 300, y: 250)); mouse.up(CGPoint(x: 300, y: 250))
        #expect(canvas.document == before)
        canvas.undo(nil)
        #expect(canvas.document.annotations.isEmpty)
    }

    @Test func aTextBeingEditedIsNotShownSelected() throws {
        let canvas = canvasInWindow()
        let mouse = Mouse(canvas: canvas)
        canvas.beginTextEntry(at: CGPoint(x: 40, y: 40), initial: "", style: canvas.style)
        canvas.typeText("Hi")
        canvas.endTextEntry()
        let text = try #require(canvas.document.annotations.first)
        canvas.tool = .select
        mouse.doubleClick(CGPoint(x: text.bounds.midX, y: text.bounds.midY))
        #expect(canvas.textField != nil && canvas.selectedID == nil)
    }

    /// The arrow keys nudge the selection a pixel, ten with Shift, each press one undo step.
    @Test func arrowKeysNudgeTheSelection() throws {
        let canvas = canvasInWindow()
        let mouse = Mouse(canvas: canvas)
        canvas.tool = .rectangle
        mouse.stroke(CGPoint(x: 40, y: 40), CGPoint(x: 140, y: 140))
        canvas.tool = .select
        mouse.down(CGPoint(x: 40, y: 90)); mouse.up(CGPoint(x: 40, y: 90))
        func arrow(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: canvas.window!.windowNumber,
                             context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        canvas.keyDown(with: arrow(124))              // right a pixel
        canvas.keyDown(with: arrow(125, .shift))      // down ten
        let moved = try #require(canvas.document.annotations.first).bounds
        #expect(moved.origin == CGPoint(x: 41, y: 50))
        canvas.undo(nil)
        #expect(try #require(canvas.document.annotations.first).bounds.origin == CGPoint(x: 41, y: 40))
    }

    private func space(_ type: NSEvent.EventType, in canvas: CanvasView) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: canvas.window!.windowNumber,
                         context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
    }

    /// Space held while drawing moves the shape with the pointer instead of growing it; let go,
    /// and the drag goes on resizing from where it was moved to.
    @Test func spaceMovesTheShapeBeingDrawn() throws {
        for tool in [Tool.rectangle, .ellipse, .obscure, .arrow, .line] {
            let canvas = canvasInWindow()
            let mouse = Mouse(canvas: canvas)
            canvas.tool = tool
            mouse.down(CGPoint(x: 40, y: 40))
            mouse.drag(CGPoint(x: 140, y: 140))
            canvas.keyDown(with: space(.keyDown, in: canvas))
            mouse.drag(CGPoint(x: 160, y: 150))
            canvas.keyUp(with: space(.keyUp, in: canvas))
            mouse.drag(CGPoint(x: 170, y: 150))
            mouse.up(CGPoint(x: 170, y: 150))
            let shape = try #require(canvas.document.annotations.first).shape
            switch shape {
            case let .rectangle(r, _), let .ellipse(r, _), let .obscure(r):
                #expect(r == CGRect(x: 60, y: 50, width: 110, height: 100), "\(tool)")
            case let .arrow(from, to), let .line(from, to):
                #expect(from == CGPoint(x: 60, y: 50) && to == CGPoint(x: 170, y: 150), "\(tool)")
            default:
                Issue.record("unexpected \(shape)")
            }
        }
    }

    /// A drawing tool pressed on what is already there selects it, and a drag moves it, rather
    /// than drawing a new one on top.
    @Test func drawingToolsSelectWhatTheyPress() throws {
        let canvas = canvasInWindow()
        let mouse = Mouse(canvas: canvas)
        canvas.tool = .rectangle
        mouse.stroke(CGPoint(x: 40, y: 40), CGPoint(x: 140, y: 140))
        let id = try #require(canvas.document.annotations.first).id
        for tool in [Tool.ellipse, .callout, .text, .obscure] {
            canvas.tool = tool
            mouse.down(CGPoint(x: 40, y: 90))
            #expect(canvas.selectedID == id, "\(tool)")
            mouse.drag(CGPoint(x: 50, y: 90))
            mouse.up(CGPoint(x: 50, y: 90))
            canvas.undo(nil)
            #expect(canvas.document.annotations.count == 1 && canvas.textField == nil, "\(tool)")
        }
    }

    /// The pen and highlighter mark over anything, and every tool but obscure draws over an
    /// obscured area.
    @Test func someToolsDrawOverWhatIsThere() throws {
        let canvas = canvasInWindow()
        let mouse = Mouse(canvas: canvas)
        canvas.tool = .obscure
        mouse.stroke(CGPoint(x: 40, y: 40), CGPoint(x: 140, y: 140))
        canvas.tool = .arrow
        mouse.stroke(CGPoint(x: 90, y: 90), CGPoint(x: 200, y: 200))
        canvas.tool = .pen
        mouse.stroke(CGPoint(x: 200, y: 200), CGPoint(x: 250, y: 220))
        #expect(canvas.document.annotations.count == 3)
    }

    @Test func aMoveIsOneStep() {
        let canvas = canvasInWindow()
        let mouse = Mouse(canvas: canvas)
        canvas.tool = .rectangle
        mouse.stroke(CGPoint(x: 40, y: 40), CGPoint(x: 140, y: 140))
        canvas.tool = .select
        mouse.down(CGPoint(x: 40, y: 90))
        for x in stride(from: 45, through: 100, by: 5) { mouse.drag(CGPoint(x: Double(x), y: 90)) }
        mouse.up(CGPoint(x: 100, y: 90))
        #expect(canvas.document.annotations.first?.bounds.minX == 100)
        canvas.undo(nil)
        #expect(canvas.document.annotations.first?.bounds.minX == 40)
    }

    @Test func restylingTextMeasuresItAgain() throws {
        let canvas = canvasInWindow()
        let mouse = Mouse(canvas: canvas)
        canvas.beginTextEntry(at: CGPoint(x: 20, y: 20), initial: "", style: canvas.style)
        canvas.typeText("grow")
        canvas.endTextEntry()
        let small = try #require(canvas.document.annotations.first).bounds
        canvas.tool = .select
        mouse.down(CGPoint(x: small.midX, y: small.midY)); mouse.up(CGPoint(x: small.midX, y: small.midY))
        var bigger = canvas.style
        bigger.fontSize = 48
        canvas.style = bigger
        let big = try #require(canvas.document.annotations.first).bounds
        #expect(big.width > small.width * 1.4 && big.height > small.height * 1.4)
    }

    @Test func aColorChangeLeavesTheOtherStylesAlone() throws {
        let canvas = canvasInWindow()
        let mouse = Mouse(canvas: canvas)
        var thick = canvas.style
        thick.strokeWidth = 10
        canvas.style = thick
        canvas.tool = .arrow
        mouse.stroke(CGPoint(x: 40, y: 40), CGPoint(x: 300, y: 200))
        var bar = thick
        bar.strokeWidth = 2
        canvas.style = bar // the bar moves on to a thin line for the next shape
        canvas.tool = .select
        mouse.down(CGPoint(x: 170, y: 120)); mouse.up(CGPoint(x: 170, y: 120))
        var blue = bar
        blue.color = .blue
        canvas.style = blue
        let arrow = try #require(canvas.document.annotations.first)
        #expect(arrow.style.color == .blue && arrow.style.strokeWidth == 10)
    }

    @Test func aStyleChangeWhileTypingStylesTheWords() throws {
        let canvas = canvasInWindow()
        canvas.beginTextEntry(at: CGPoint(x: 20, y: 20), initial: "", style: canvas.style)
        canvas.typeText("blue")
        var blue = canvas.style
        blue.color = .blue
        canvas.style = blue
        canvas.endTextEntry()
        #expect(try #require(canvas.document.annotations.first).style.color == .blue)
    }

    @Test func undoWhileTypingUndoesTypingNotTheDocument() {
        let canvas = canvasInWindow()
        canvas.tool = .rectangle
        Mouse(canvas: canvas).stroke(CGPoint(x: 40, y: 40), CGPoint(x: 140, y: 140))
        canvas.beginTextEntry(at: CGPoint(x: 200, y: 20), initial: "", style: canvas.style)
        canvas.textField?.insertText("ab", replacementRange: NSRange(location: NSNotFound, length: 0))
        canvas.undo(nil)
        #expect(canvas.textField != nil)
        #expect(canvas.document.annotations.count == 1)
    }

    @Test func clicksBesideCalloutWordsReachTheCanvas() throws {
        let canvas = canvasInWindow()
        canvas.tool = .callout
        Mouse(canvas: canvas).stroke(CGPoint(x: 200, y: 250), CGPoint(x: 200, y: 50)) // vertical: a wide wrap
        canvas.typeText("hi")
        let entry = try #require(canvas.textField)
        // Inside the entry's frame, which spans the wrap width, but well beside the short words.
        let beside = CGPoint(x: entry.frame.minX + 4, y: entry.frame.midY)
        #expect(canvas.hitTest(canvas.convert(beside, to: canvas.superview)) === canvas)
    }

    @Test func aCropToolClickClearsTheCrop() {
        let canvas = canvasInWindow()
        let mouse = Mouse(canvas: canvas)
        canvas.tool = .crop
        mouse.stroke(CGPoint(x: 40, y: 40), CGPoint(x: 200, y: 200))
        #expect(canvas.document.crop != nil)
        mouse.down(CGPoint(x: 100, y: 100)); mouse.up(CGPoint(x: 100, y: 100))
        #expect(canvas.document.crop == nil)
    }

    /// The line tool draws a straight line, Shift snaps it to 45°, and the tool clicked on a line
    /// selects it rather than drawing over it.
    @Test func theLineToolDrawsAndSnaps() throws {
        let canvas = canvasInWindow()
        let mouse = Mouse(canvas: canvas)
        canvas.tool = .line
        mouse.stroke(CGPoint(x: 40, y: 40), CGPoint(x: 200, y: 60))
        #expect(try #require(canvas.document.annotations.first).shape == .line(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 200, y: 60)))
        mouse.down(CGPoint(x: 40, y: 200))
        canvas.mouseDragged(with: mouse.event(.leftMouseDragged, CGPoint(x: 200, y: 212), flags: .shift))
        mouse.up(CGPoint(x: 200, y: 212))
        guard case let .line(from, to)? = canvas.document.annotations.last?.shape else { Issue.record("no line"); return }
        #expect(from == CGPoint(x: 40, y: 200) && abs(to.y - 200) < 1e-9)
        mouse.down(CGPoint(x: 120, y: 50)); mouse.up(CGPoint(x: 120, y: 50))
        #expect(canvas.document.annotations.count == 2 && canvas.selectedID == canvas.document.annotations.first?.id)
    }

    /// The defaults remember the last tool by raw value: a new tool must not renumber the others.
    @Test func toolNumbersNeverChange() {
        let remembered: [Tool: Int] = [.select: 0, .callout: 1, .arrow: 2, .text: 3, .rectangle: 4, .ellipse: 5, .pen: 6,
                                       .highlighter: 7, .obscure: 8, .crop: 9, .line: 10]
        for (tool, number) in remembered { #expect(tool.rawValue == number) }
        #expect(Tool.allCases.firstIndex(of: .line) == Tool.allCases.firstIndex(of: .arrow)! + 1)
    }

    @Test func thePlainArrowHasGripsToo() throws {
        let canvas = canvasInWindow()
        let mouse = Mouse(canvas: canvas)
        canvas.tool = .arrow
        mouse.stroke(CGPoint(x: 40, y: 150), CGPoint(x: 340, y: 150))
        mouse.down(CGPoint(x: 340, y: 150)) // the arrow tool grabs the head
        mouse.drag(CGPoint(x: 340, y: 60)); mouse.up(CGPoint(x: 340, y: 60))
        #expect(try #require(canvas.document.annotations.first).shape == .arrow(from: CGPoint(x: 40, y: 150), to: CGPoint(x: 340, y: 60)))
    }
}

@MainActor @Suite struct ClosingTests {
    func editor(annotated: Bool) -> EditorWindowController {
        let controller = EditorWindowController(document: Document(width: 400, height: 300, scale: 2), source: blankImage(400, 300))
        if annotated {
            var d = controller.canvas.document
            d.add(Annotation(shape: .rectangle(CGRect(x: 10, y: 10, width: 50, height: 50)), style: .standard))
            controller.canvas.commit(d)
        }
        return controller
    }

    /// The editor closes like any window, annotations or not, with no question: Option-F10
    /// brings the one closed last back. What it closes with is what comes back.
    @Test func escapeClosesLikeAnyWindowKeepingTheAnnotations() {
        let controller = editor(annotated: true)
        var closedWith: Document?
        controller.onClose = { [unowned controller] in closedWith = controller.canvas.document }
        controller.cancelOperation(nil)
        #expect(closedWith?.annotations.count == 1)
    }

    /// Copy leaves the editor open, like any other window.
    @Test func copyKeepsTheEditorOpen() {
        let controller = editor(annotated: true)
        controller.pasteboard = NSPasteboard(name: NSPasteboard.Name("shotts-test-\(UUID().uuidString)"))
        defer { controller.pasteboard.releaseGlobally() }
        var closed = false
        controller.onClose = { closed = true }
        controller.copyPressed()
        #expect(!closed)
        #expect(controller.pasteboard.data(forType: .png) != nil)
    }

    @Test func closingMidDragPutsTheDragBack() {
        let controller = editor(annotated: true)
        let canvas = controller.canvas
        let before = canvas.document
        let mouse = Mouse(canvas: canvas)
        canvas.tool = .select
        mouse.down(CGPoint(x: 10, y: 35))
        mouse.drag(CGPoint(x: 80, y: 35))
        // As a new capture replacing the editor closes it: without asking windowShouldClose.
        controller.close()
        #expect(canvas.document == before)
    }

    /// Words still being typed are part of what closes, and so of what Option-F10 brings back,
    /// however the editor closes: a new capture replacing it closes it without asking.
    @Test func wordsBeingTypedAreKeptWhenClosing() {
        for replaced in [false, true] {
            let controller = editor(annotated: false)
            var kept: Document?
            controller.onClose = { kept = controller.canvas.document }
            controller.canvas.beginTextEntry(at: CGPoint(x: 20, y: 20), initial: "", style: .standard)
            controller.canvas.typeText("kept")
            if replaced { controller.close() } else { controller.window?.performClose(nil) }
            guard case let .text(_, words, _, _)? = kept?.annotations.first?.shape else { Issue.record("no text"); return }
            #expect(words == "kept")
        }
    }
}

@MainActor @Suite struct BarTests {
    /// The canvas sits under the bar and must not paint over it: the bar's area, drawn with the
    /// window's content, is not the canvas's dark field.
    @Test func theCanvasLeavesTheBarVisible() throws {
        let controller = EditorWindowController(document: Document(width: 1600, height: 1000, scale: 2), source: blankImage(1600, 1000))
        let content = try #require(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let rep = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let image = try #require(rep.cgImage)
        let pixels = rgba(image)
        let bar = controller.layout.barHeight * CGFloat(image.height) / content.bounds.height
        // Rows are top-first. The field's color is read just below the bar, at the left edge;
        // then the middle row of the bar is compared with it.
        let sample = (Int(bar) + 8) * image.width * 4 + 8
        let row = Int(bar / 2)
        let field = (0..<image.width).filter { x in
            let o = (row * image.width + x) * 4
            return (0..<3).allSatisfy { abs(Int(pixels[o + $0]) - Int(pixels[sample + $0])) < 4 }
        }.count
        #expect(Double(field) / Double(image.width) < 0.5, "the bar's row is \(field) of \(image.width) pixels of the canvas's field")
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
