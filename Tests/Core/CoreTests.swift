import Foundation
import Testing
@testable import ShottsCore

@Suite struct SelectionRuleTests {
    @Test func dragInAnyDirectionNormalizes() {
        let r = SelectionRule.rect(anchor: CGPoint(x: 100, y: 100), pointer: CGPoint(x: 40, y: 70))
        #expect(r == CGRect(x: 40, y: 70, width: 60, height: 30))
    }

    @Test func shiftMakesASquareAwayFromTheAnchor() {
        let r = SelectionRule.rect(anchor: CGPoint(x: 100, y: 100), pointer: CGPoint(x: 40, y: 130), square: true)
        #expect(r == CGRect(x: 40, y: 100, width: 60, height: 60))
    }

    @Test func movingStaysInsideBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let r = CGRect(x: 80, y: 10, width: 30, height: 30)
        #expect(SelectionRule.moved(r, by: CGPoint(x: 50, y: -50), within: bounds) == CGRect(x: 70, y: 0, width: 30, height: 30))
    }

    @Test func shiftSnapsALineTo45Degrees() {
        let a = CGPoint(x: 100, y: 100)
        #expect(SelectionRule.lineEnd(anchor: a, pointer: CGPoint(x: 200, y: 110), snapped: false) == CGPoint(x: 200, y: 110))
        let flat = SelectionRule.lineEnd(anchor: a, pointer: CGPoint(x: 200, y: 110), snapped: true)
        #expect(abs(flat.y - 100) < 1e-9 && abs(flat.x - 200) < 1e-9)
        let diagonal = SelectionRule.lineEnd(anchor: a, pointer: CGPoint(x: 190, y: 210), snapped: true)
        #expect(abs((diagonal.x - 100) - (diagonal.y - 100)) < 1e-9)
        let up = SelectionRule.lineEnd(anchor: a, pointer: CGPoint(x: 105, y: 20), snapped: true)
        #expect(abs(up.x - 100) < 1e-9 && abs(up.y - 20) < 1e-9)
    }

    /// The picker's arrow keys move a whole pixel, landing in its middle, and stop at the edges.
    @Test func nudgingMovesWholePixels() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 50)
        #expect(SelectionRule.nudged(CGPoint(x: 10.2, y: 5.9), by: CGPoint(x: 1, y: 0), scale: 2, within: bounds) == CGPoint(x: 10.75, y: 5.75))
        #expect(SelectionRule.nudged(CGPoint(x: 10.2, y: 5.9), by: CGPoint(x: -10, y: 10), scale: 2, within: bounds) == CGPoint(x: 5.25, y: 10.75))
        #expect(SelectionRule.nudged(CGPoint(x: 0.1, y: 49.9), by: CGPoint(x: -10, y: 10), scale: 2, within: bounds) == CGPoint(x: 0.25, y: 49.75))
        #expect(SelectionRule.nudged(CGPoint(x: 3, y: 3), by: CGPoint(x: 1, y: 1), scale: 1, within: bounds) == CGPoint(x: 4.5, y: 4.5))
    }

    @Test func pixelRectSnapsAndClips() {
        let r = SelectionRule.pixelRect(CGRect(x: 10.3, y: 5.6, width: 20.2, height: 4), scale: 2, within: CGRect(x: 0, y: 0, width: 50, height: 50))
        #expect(r == CGRect(x: 20, y: 11, width: 30, height: 9)) // 20.6…61 by 11.2…19.2, snapped outward, clipped at 50
        #expect(!SelectionRule.isUsable(CGRect(x: 0, y: 0, width: 3, height: 40)))
    }
}

@Suite struct HistoryTests {
    @Test func undoRedoRoundTrip() {
        var h = History(1)
        h.push(2); h.push(3)
        #expect(h.undo() == 2)
        #expect(h.undo() == 1)
        #expect(h.undo() == nil)
        #expect(h.redo() == 2)
        h.push(9)
        #expect(!h.canRedo)
        #expect(h.current == 9)
    }

    @Test func pushingTheSameStateIsNotAStep() {
        var h = History(1)
        h.push(1)
        #expect(!h.canUndo)
    }

    @Test func aChangeMadeInPlaceIsOneStep() {
        var h = History(1)
        h.push(2)
        let base = h.current
        h.replaceCurrent(3); h.replaceCurrent(4); h.replaceCurrent(5)
        h.record(since: base)
        #expect(h.current == 5)
        #expect(h.undo() == 2)
        #expect(h.undo() == 1)
        #expect(h.redo() == 2 && h.redo() == 5)
    }

    @Test func aChangeThatEndsWhereItBeganIsNoStep() {
        var h = History(1)
        h.push(2)
        h.replaceCurrent(7)
        h.replaceCurrent(2)
        h.record(since: 2)
        #expect(h.current == 2 && h.undo() == 1 && !h.canUndo)
    }
}

@Suite struct DocumentTests {
    let style = Style.standard

    @Test func cropClampsAndWholeImageClears() {
        var d = Document(width: 100, height: 50, scale: 1)
        d.setCrop(CGRect(x: -10, y: 10, width: 200, height: 20))
        #expect(d.crop == CGRect(x: 0, y: 10, width: 100, height: 20))
        d.setCrop(CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(d.crop == nil)
        #expect(d.visibleRect == d.pixelBounds)
    }

    @Test func degenerateShapesAreDropped() {
        let picture = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(Annotation(shape: .arrow(from: .zero, to: CGPoint(x: 1, y: 1)), style: style).isDegenerate(in: picture))
        #expect(!Annotation(shape: .arrow(from: .zero, to: CGPoint(x: 40, y: 0)), style: style).isDegenerate(in: picture))
        #expect(Annotation(shape: .text(origin: .zero, string: "", size: .zero), style: style).isDegenerate(in: picture))
        #expect(Annotation(shape: .text(origin: .zero, string: " \n ", size: CGSize(width: 9, height: 9)), style: style).isDegenerate(in: picture))
        #expect(Annotation(shape: .pen([CGPoint(x: 5, y: 5)]), style: style).isDegenerate(in: picture))
        #expect(Annotation(shape: .rectangle(CGRect(x: 10, y: 10, width: -40, height: 2)), style: style).isDegenerate(in: picture))
        #expect(!Annotation(shape: .rectangle(CGRect(x: 50, y: 50, width: -40, height: -40)), style: style).isDegenerate(in: picture))
        // Drawn wholly in the field around the picture: it would never show or export.
        #expect(Annotation(shape: .rectangle(CGRect(x: -80, y: 10, width: 40, height: 40)), style: style).isDegenerate(in: picture))
        #expect(!Annotation(shape: .rectangle(CGRect(x: -20, y: 10, width: 40, height: 40)), style: style).isDegenerate(in: picture))
    }

    @Test func documentEditsById() {
        let a = Annotation(shape: .pen([.zero, CGPoint(x: 5, y: 5)]), style: style)
        var d = Document(width: 10, height: 10, scale: 1)
        #expect(d.isBlank)
        d.add(a)
        #expect(!d.isBlank && d.annotation(a.id) == a)
        var b = a
        b.style.color = .blue
        d.replace(b)
        #expect(d.annotations == [b])
        d.remove(a.id)
        #expect(d.isBlank)
        d.setCrop(CGRect(x: 2.4, y: 2.6, width: 3.2, height: 3))
        #expect(d.crop == CGRect(x: 2, y: 2, width: 4, height: 4) && !d.isBlank)
        d.setCrop(CGRect(x: 40, y: 40, width: 5, height: 5))
        #expect(d.crop == nil)
        #expect(Document(width: 10, height: 10, scale: 1, crop: CGRect(x: -5, y: 0, width: 8, height: 10)).crop == CGRect(x: 0, y: 0, width: 3, height: 10))
    }

    @Test func translateMovesEveryKind() {
        let d = CGPoint(x: 5, y: -5)
        let pen = Annotation(shape: .pen([.zero, CGPoint(x: 10, y: 10)]), style: style).translated(by: d)
        #expect(pen.bounds == CGRect(x: 5, y: -5, width: 10, height: 10))
        let text = Annotation(shape: .text(origin: CGPoint(x: 1, y: 1), string: "a", size: CGSize(width: 8, height: 8), alignment: .right), style: style).translated(by: d)
        #expect(text.bounds.origin == CGPoint(x: 6, y: -4))
        if case let .text(_, _, _, alignment) = text.shape { #expect(alignment == .right) }
    }
}

@Suite struct HitTestTests {
    let style = Style(color: .red, strokeWidth: 4, fontSize: 20)

    @Test func topmostWins() {
        let a = Annotation(shape: .rectangle(CGRect(x: 0, y: 0, width: 100, height: 100)), style: style)
        let b = Annotation(shape: .obscure(CGRect(x: 0, y: 0, width: 100, height: 100)), style: style)
        let doc = Document(width: 200, height: 200, scale: 1, annotations: [a, b])
        #expect(HitTest.annotation(at: CGPoint(x: 50, y: 50), in: doc, tolerance: 4) == b.id)
        #expect(HitTest.annotation(at: CGPoint(x: 150, y: 150), in: doc, tolerance: 4) == nil)
    }

    @Test func strokesHitNearTheLineNotInsideTheBox() {
        let rect = Annotation(shape: .rectangle(CGRect(x: 10, y: 10, width: 100, height: 100)), style: style)
        let arrow = Annotation(shape: .arrow(from: CGPoint(x: 0, y: 200), to: CGPoint(x: 100, y: 200)), style: style)
        let doc = Document(width: 300, height: 300, scale: 1, annotations: [rect, arrow])
        #expect(HitTest.annotation(at: CGPoint(x: 10, y: 60), in: doc, tolerance: 4) == rect.id)
        #expect(HitTest.annotation(at: CGPoint(x: 60, y: 60), in: doc, tolerance: 4) == nil)
        #expect(HitTest.annotation(at: CGPoint(x: 50, y: 203), in: doc, tolerance: 4) == arrow.id)
        #expect(HitTest.annotation(at: CGPoint(x: 90, y: 196), in: doc, tolerance: 1) == arrow.id) // inside the head, 4 px off the shaft
    }

    @Test func aCalloutIsHitOnItsWordsOrItsArrow() {
        let words = Annotation.TextBox(origin: CGPoint(x: 0, y: 80), string: "hi", size: CGSize(width: 60, height: 30), alignment: .right)
        let c = Annotation(shape: .callout(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 100), text: words), style: style)
        #expect(HitTest.arrowPart(at: CGPoint(x: 30, y: 95), of: c, scale: 1, tolerance: 4) == .text)
        #expect(HitTest.arrowPart(at: CGPoint(x: 103, y: 98), of: c, scale: 1, tolerance: 4) == .tail)
        #expect(HitTest.arrowPart(at: CGPoint(x: 200, y: 102), of: c, scale: 1, tolerance: 4) == .shaft)
        #expect(HitTest.arrowPart(at: CGPoint(x: 295, y: 100), of: c, scale: 1, tolerance: 4) == .head)
        #expect(HitTest.arrowPart(at: CGPoint(x: 200, y: 200), of: c, scale: 1, tolerance: 4) == nil)
        #expect(c.bounds == CGRect(x: 0, y: 80, width: 300, height: 30))
        let moved = c.translated(by: CGPoint(x: 10, y: 10))
        if case let .callout(from, _, text) = moved.shape { #expect(from == CGPoint(x: 110, y: 110) && text.origin == CGPoint(x: 10, y: 90)) }
    }

    @Test func solidShapesAreHitInside() {
        let box = Annotation(shape: .rectangle(CGRect(x: 10, y: 10, width: 100, height: 100), filled: true), style: style)
        let disc = Annotation(shape: .ellipse(CGRect(x: 200, y: 10, width: 100, height: 100), filled: true), style: style)
        let doc = Document(width: 400, height: 200, scale: 1, annotations: [box, disc])
        #expect(HitTest.annotation(at: CGPoint(x: 60, y: 60), in: doc, tolerance: 4) == box.id)
        #expect(HitTest.annotation(at: CGPoint(x: 250, y: 60), in: doc, tolerance: 4) == disc.id)
        #expect(HitTest.annotation(at: CGPoint(x: 205, y: 15), in: doc, tolerance: 4) == nil) // the disc's corner, outside the ellipse
    }

    @Test func arrowOutlineRunsFromTailToTipAndScalesWithStroke() {
        let long = ArrowGeometry(from: .zero, to: CGPoint(x: 100, y: 0), width: 4)
        #expect(long.outline[3] == CGPoint(x: 100, y: 0))
        #expect(long.contains(CGPoint(x: 99, y: 0)))               // the tip
        #expect(long.contains(CGPoint(x: 85, y: 6)))               // inside the head
        #expect(!long.contains(CGPoint(x: 50, y: 6)))              // beside the shaft
        #expect(long.outline.map(\.x).max()! == 100 && long.outline.map(\.x).min()! >= 0)
        let thick = ArrowGeometry(from: .zero, to: CGPoint(x: 100, y: 0), width: 10)
        #expect(thick.outline.map(\.y).max()! > long.outline.map(\.y).max()!)
        let tiny = ArrowGeometry(from: .zero, to: CGPoint(x: 10, y: 0), width: 10)
        #expect(tiny.outline.map(\.x).min()! >= -1)                 // the head never overshoots the tail
        let even = ArrowGeometry(from: .zero, to: CGPoint(x: 100, y: 0), width: 4, tapered: false)
        #expect(even.outline[0].y == 2 && even.outline[1].y == 2)  // the shaft is 4 wide at both ends
        #expect(long.outline[0].y < 1)                              // the tapered tail is a point
        let stubby = ArrowGeometry(from: .zero, to: CGPoint(x: 20, y: 0), width: 20)
        #expect(stubby.outline[2].y > stubby.outline[1].y)          // a short thick arrow still has barbs
    }

    @Test func retinaHitsFollowTheInkDrawn() {
        // A 10-point arrow on a 2x capture is 20 pixels wide; its barbs reach about 74 pixels out.
        let thick = Style(color: .red, strokeWidth: 10, fontSize: 20)
        let arrow = Annotation(shape: .arrow(from: CGPoint(x: 0, y: 300), to: CGPoint(x: 500, y: 300)), style: thick)
        let marker = Annotation(shape: .highlighter([CGPoint(x: 0, y: 100), CGPoint(x: 500, y: 100)]), style: thick)
        let doc = Document(width: 600, height: 400, scale: 2, annotations: [arrow, marker])
        #expect(HitTest.annotation(at: CGPoint(x: 430, y: 335), in: doc, tolerance: 2) == arrow.id) // in a barb, 35 px off the shaft
        #expect(HitTest.annotation(at: CGPoint(x: 250, y: 125), in: doc, tolerance: 2) == marker.id) // 25 px off a 60 px band
        #expect(HitTest.annotation(at: CGPoint(x: 250, y: 140), in: doc, tolerance: 2) == nil)
    }

    @Test func strokedEllipsesAreHitOnTheirLine() {
        let thin = Annotation(shape: .ellipse(CGRect(x: 0, y: 0, width: 400, height: 20)), style: style)
        let round = Annotation(shape: .ellipse(CGRect(x: 0, y: 100, width: 200, height: 100)), style: style)
        let doc = Document(width: 1000, height: 400, scale: 1, annotations: [thin, round])
        #expect(HitTest.annotation(at: CGPoint(x: 200, y: 2), in: doc, tolerance: 4) == thin.id)  // on the line
        #expect(HitTest.annotation(at: CGPoint(x: 600, y: 10), in: doc, tolerance: 4) == nil)     // far past its end
        #expect(HitTest.annotation(at: CGPoint(x: 100, y: 150), in: doc, tolerance: 4) == nil)    // the round one's middle
        #expect(HitTest.annotation(at: CGPoint(x: 2, y: 150), in: doc, tolerance: 4) == round.id) // its left edge
        #expect(HitTest.annotation(at: CGPoint(x: 225, y: 150), in: doc, tolerance: 4) == nil)    // 25 px past its right edge
    }

    @Test func aShapeThinnerThanItsStrokeIsHitWhereItIsDrawn() {
        // The renderer fills it: its whole area, not an outline, is ink.
        let thick = Style(color: .red, strokeWidth: 10, fontSize: 20)
        let sliver = Annotation(shape: .rectangle(CGRect(x: 100, y: 100, width: 6, height: 30)), style: thick)
        let doc = Document(width: 300, height: 300, scale: 2, annotations: [sliver])
        #expect(HitTest.annotation(at: CGPoint(x: 103, y: 115), in: doc, tolerance: 2) == sliver.id)
        #expect(HitTest.annotation(at: CGPoint(x: 140, y: 115), in: doc, tolerance: 2) == nil)
    }

    @Test func aLineIsHitOnItselfAndGrabbedByItsEnds() {
        let line = Annotation(shape: .line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 100)), style: style)
        let doc = Document(width: 500, height: 300, scale: 1, annotations: [line])
        #expect(HitTest.annotation(at: CGPoint(x: 250, y: 103), in: doc, tolerance: 4) == line.id)
        #expect(HitTest.annotation(at: CGPoint(x: 250, y: 130), in: doc, tolerance: 4) == nil)
        #expect(HitTest.arrowPart(at: CGPoint(x: 101, y: 100), of: line, scale: 1, tolerance: 4) == .tail)
        #expect(HitTest.arrowPart(at: CGPoint(x: 399, y: 100), of: line, scale: 1, tolerance: 4) == .head)
        #expect(HitTest.arrowPart(at: CGPoint(x: 250, y: 100), of: line, scale: 1, tolerance: 4) == .shaft)
        let d = CGPoint(x: 0, y: 50)
        #expect(line.dragged(.head, by: d).shape == .line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 150)))
        #expect(line.dragged(.shaft, by: d).shape == .line(from: CGPoint(x: 100, y: 150), to: CGPoint(x: 400, y: 150)))
        #expect(Annotation(shape: .line(from: .zero, to: CGPoint(x: 2, y: 1)), style: style).isDegenerate(in: doc.pixelBounds))
    }

    /// Shift while dragging a line's end snaps it to 45° around the other end, as while drawing.
    @Test func aLineEndSnapsWithShift() {
        let line = Annotation(shape: .line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 100)), style: style)
        // The head pulled to (390, 120): nearly level, so it lands level, as far along as the pointer.
        #expect(line.dragged(.head, by: CGPoint(x: -10, y: 20), snapped: true).shape
            == .line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 390, y: 100)))
        // Without Shift it goes where it is pulled.
        #expect(line.dragged(.head, by: CGPoint(x: -10, y: 20)).shape == .line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 390, y: 120)))
        // The tail pulled near the diagonal through the head snaps onto it.
        guard case let .line(tail, head) = line.dragged(.tail, by: CGPoint(x: 0, y: -290), snapped: true).shape else { Issue.record(); return }
        #expect(head == CGPoint(x: 400, y: 100))
        #expect(abs(abs(tail.x - head.x) - abs(tail.y - head.y)) < 1e-9)
        // Moving the whole line is not snapped.
        #expect(line.dragged(.shaft, by: CGPoint(x: 3, y: 7), snapped: true).shape == .line(from: CGPoint(x: 103, y: 107), to: CGPoint(x: 403, y: 107)))
    }

    @Test func emptyStrokesHitNothing() {
        let doc = Document(width: 100, height: 100, scale: 1, annotations: [Annotation(shape: .pen([]), style: style)])
        #expect(HitTest.annotation(at: .zero, in: doc, tolerance: 4) == nil)
    }

    @Test func aShortCalloutKeepsAShaftToMoveItBy() {
        let words = Annotation.TextBox(origin: CGPoint(x: 0, y: 90), string: "hi", size: CGSize(width: 40, height: 20), alignment: .right)
        let c = Annotation(shape: .callout(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 160, y: 100), text: words), style: style)
        let parts = stride(from: 100, through: 160, by: 5).compactMap { HitTest.arrowPart(at: CGPoint(x: Double($0), y: 100), of: c, scale: 2, tolerance: 12) }
        #expect(parts.first == .tail && parts.last == .head && parts.contains(.shaft))
    }

    @Test func dragsMoveThePartGrabbed() {
        let tail = CGPoint(x: 10, y: 10), tip = CGPoint(x: 100, y: 10), d = CGPoint(x: 5, y: 7)
        let arrow = Annotation(shape: .arrow(from: tail, to: tip), style: style)
        #expect(arrow.dragged(.tail, by: d).shape == .arrow(from: tail + d, to: tip))
        #expect(arrow.dragged(.head, by: d).shape == .arrow(from: tail, to: tip + d))
        #expect(arrow.dragged(.shaft, by: d).shape == .arrow(from: tail + d, to: tip + d))
        let words = Annotation.TextBox(origin: .zero, string: "a", size: CGSize(width: 9, height: 9), alignment: .left)
        let callout = Annotation(shape: .callout(from: tail, to: tip, text: words), style: style)
        #expect(callout.dragged(.text, by: d).shape == .callout(from: tail + d, to: tip, text: words))
        #expect(callout.dragged(.head, by: d).shape == .callout(from: tail, to: tip + d, text: words))
        guard case let .callout(_, _, moved) = callout.dragged(nil, by: d).shape else { Issue.record("not a callout"); return }
        #expect(moved.origin == d)
    }
}

@Suite struct StyleTests {
    @Test func hexIsUppercaseRRGGBB() {
        #expect(RGBA.red.hex == "#FF3B30")
        #expect(RGBA(red: 0, green: 0.5, blue: 1).hex == "#0080FF")
        #expect(RGBA.yellow.isLight && !RGBA.blue.isLight)
    }

    @Test func decodesOlderSettings() throws {
        let old = Data(#"{"color":{"red":0,"green":0,"blue":1,"alpha":1},"strokeWidth":6,"fontSize":24,"shadow":false,"outline":true}"#.utf8)
        let style = try JSONDecoder().decode(Style.self, from: old)
        #expect(style.strokeWidth == 6 && style.shadow == false && style.taperedArrows == true && style.font == .rounded)
    }

    @Test func openSansIsRemembered() throws {
        var style = Style.standard
        style.font = .openSans
        #expect(try JSONDecoder().decode(Style.self, from: JSONEncoder().encode(style)).font == .openSans)
    }

    /// Trebuchet was a font choice until 0.2.4; a style remembered with it comes back Rounded.
    @Test func aRememberedTrebuchetBecomesRounded() throws {
        let saved = Data(#"{"color":{"red":0,"green":0,"blue":1,"alpha":1},"strokeWidth":6,"fontSize":36,"font":"trebuchet"}"#.utf8)
        let style = try JSONDecoder().decode(Style.self, from: saved)
        #expect(style.font == .rounded && style.fontSize == 36 && style.strokeWidth == 6)
    }

    @Test func anUnknownFontKeepsTheRest() throws {
        let newer = Data(#"{"color":{"red":0,"green":0,"blue":1,"alpha":1},"strokeWidth":10,"font":"serif"}"#.utf8)
        let style = try JSONDecoder().decode(Style.self, from: newer)
        #expect(style.font == .rounded && style.strokeWidth == 10 && style.color == RGBA(red: 0, green: 0, blue: 1))
        let again = try JSONDecoder().decode(Style.self, from: JSONEncoder().encode(style))
        #expect(again == style)
    }

    @Test func applyingChangesOnlyWhatChanged() {
        var thick = Style.standard
        thick.strokeWidth = 10
        var bar = Style.standard
        bar.color = .blue
        #expect(thick.applying(from: .standard, to: bar) == Style(color: .blue, strokeWidth: 10, fontSize: 28))
        #expect(thick.applying(from: bar, to: bar) == thick)
    }
}

@Suite struct AppLocationTests {
    let home = "/Users/brother"

    @Test func applicationsFoldersAreHome() {
        #expect(!AppLocation.offersMove(bundlePath: "/Applications/Shotts.app", home: home))
        #expect(!AppLocation.offersMove(bundlePath: "/Users/brother/Applications/Shotts.app", home: home))
        #expect(!AppLocation.offersMove(bundlePath: "/Applications/Utilities/Shotts.app", home: home))
    }

    @Test func downloadsAndTranslocationOfferAMove() {
        #expect(AppLocation.offersMove(bundlePath: "/Users/brother/Downloads/Shotts.app", home: home))
        #expect(AppLocation.offersMove(bundlePath: "/Users/brother/Desktop/Shotts.app", home: home))
        #expect(AppLocation.offersMove(bundlePath: "/private/var/folders/xy/T/AppTranslocation/1234/d/Shotts.app", home: home))
        // A folder that merely starts the same way is not Applications.
        #expect(AppLocation.offersMove(bundlePath: "/Applications Old/Shotts.app", home: home))
    }

    @Test func movesIntoTheSharedFolderWhenItCan() {
        #expect(AppLocation.destinationFolder(canWriteShared: true, home: home) == "/Applications")
        #expect(AppLocation.destinationFolder(canWriteShared: false, home: home) == "/Users/brother/Applications")
    }
}

@Suite struct EditorLayoutTests {
    let layout = EditorLayout(picture: CGSize(width: 1600, height: 1000), scale: 2, barHeight: 44, minimumWidth: 880, inset: 28, minimumPicture: 160)

    @Test func aBigWindowShowsThePictureAtItsOnScreenSize() {
        #expect(layout.zoom(fitting: CGSize(width: 3000, height: 2000)) == 0.5)
        #expect(layout.contentSize(zoom: 0.5) == CGSize(width: 880, height: 600)) // 856 wide, floored at the bar's 880
    }

    @Test func aShortWindowShrinksThePictureKeepingTheBarsWidth() {
        let zoom = layout.zoom(fitting: CGSize(width: 1000, height: 400))
        #expect(zoom == 0.3)
        #expect(layout.contentSize(zoom: zoom) == CGSize(width: 880, height: 400))
    }

    @Test func thePictureNeverGetsTiny() {
        #expect(layout.minimumZoom == 0.1)
        #expect(layout.zoom(fitting: CGSize(width: 10, height: 10)) == 0.1)
        let icon = EditorLayout(picture: CGSize(width: 64, height: 64), scale: 2, barHeight: 44, minimumWidth: 880, inset: 28, minimumPicture: 160)
        #expect(icon.minimumZoom == 0.5)
    }
}

@Suite struct CalloutLayoutTests {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)

    @Test func textSitsLeftOfATailWhoseArrowPointsRight() {
        let l = CalloutLayout(tail: CGPoint(x: 500, y: 300), tip: CGPoint(x: 800, y: 200), lineHeight: 40, maxWidth: 300, in: bounds)
        #expect(l.side == .left && l.alignment == .right)
        #expect(l.anchor == CGPoint(x: 490, y: 300))     // a quarter line short of the tail
        #expect(l.width == 300)
        #expect(l.origin(for: CGSize(width: 100, height: 40)) == CGPoint(x: 390, y: 280))  // right edge on the anchor, centered on the tail
        #expect(l.origin(for: CGSize(width: 300, height: 120)) == CGPoint(x: 190, y: 240)) // taller: still centered
    }

    @Test func textSitsRightOfATailWhoseArrowPointsLeft() {
        let l = CalloutLayout(tail: CGPoint(x: 500, y: 300), tip: CGPoint(x: 100, y: 300), lineHeight: 40, maxWidth: 300, in: bounds)
        #expect(l.side == .right && l.alignment == .left)
        #expect(l.origin(for: CGSize(width: 100, height: 40)) == CGPoint(x: 510, y: 280))
        #expect(l.width == 300)
    }

    @Test func noRoomOnTheFarSideFlipsIt() {
        let l = CalloutLayout(tail: CGPoint(x: 30, y: 300), tip: CGPoint(x: 400, y: 300), lineHeight: 40, maxWidth: 300, in: bounds)
        #expect(l.side == .right && l.origin.x == 40)
    }

    @Test func widthAndPositionStayInsideThePicture() {
        let l = CalloutLayout(tail: CGPoint(x: 900, y: 590), tip: CGPoint(x: 1000, y: 560), lineHeight: 40, maxWidth: 300, in: bounds)
        #expect(l.side == .left && l.anchor.x == 890 && l.width == 300)
        #expect(l.origin.y == 560)                                          // clamped to the bottom
        #expect(l.origin(for: CGSize(width: 300, height: 120)) == CGPoint(x: 590, y: 480)) // taller: moved up
    }

    @Test func anArrowPointingUpPutsCenteredTextBelowTheTailGrowingDown() {
        let l = CalloutLayout(tail: CGPoint(x: 500, y: 300), tip: CGPoint(x: 520, y: 100), lineHeight: 40, maxWidth: 300, in: bounds)
        #expect(l.side == .below && l.alignment == .center)
        #expect(l.origin(for: CGSize(width: 100, height: 40)) == CGPoint(x: 450, y: 310))  // centered on the tail, a quarter line below it
        #expect(l.origin(for: CGSize(width: 300, height: 120)) == CGPoint(x: 350, y: 310)) // taller: grows downward
    }

    @Test func anArrowPointingDownPutsCenteredTextAboveTheTailGrowingUp() {
        let l = CalloutLayout(tail: CGPoint(x: 500, y: 300), tip: CGPoint(x: 480, y: 500), lineHeight: 40, maxWidth: 300, in: bounds)
        #expect(l.side == .above && l.alignment == .center)
        #expect(l.anchor == CGPoint(x: 500, y: 290))                        // a quarter line above the tail
        #expect(l.origin(for: CGSize(width: 100, height: 40)) == CGPoint(x: 450, y: 250))
        #expect(l.origin(for: CGSize(width: 300, height: 120)) == CGPoint(x: 350, y: 170)) // taller: grows upward
    }

    @Test func centeredTextCentersOnTheTailNotThePicture() {
        // The words may wrap at the picture's full width, but a short line sits under the tail.
        let l = CalloutLayout(tail: CGPoint(x: 200, y: 300), tip: CGPoint(x: 200, y: 100), lineHeight: 40, maxWidth: 1000, in: bounds)
        #expect(l.width == 1000)
        #expect(l.origin(for: CGSize(width: 100, height: 40)).x == 150)
    }

    @Test func aPictureSmallerThanTheMarginStillPlacesTheWords() {
        let tiny = CGRect(x: 0, y: 0, width: 28, height: 60)
        let l = CalloutLayout(tail: CGPoint(x: 20, y: 30), tip: CGPoint(x: 26, y: 50), lineHeight: 40, maxWidth: 28, in: tiny, margin: 16)
        let o = l.origin(for: CGSize(width: 10, height: 40))
        #expect(o.x.isFinite && o.y.isFinite && l.width > 0)
        #expect(tiny.contains(o))
    }

    @Test func aCenteredBoxStaysInsideThePictureSideways() {
        let l = CalloutLayout(tail: CGPoint(x: 40, y: 300), tip: CGPoint(x: 40, y: 100), lineHeight: 40, maxWidth: 300, in: bounds)
        #expect(l.origin(for: CGSize(width: 300, height: 40)).x == 0)
    }
}

@Suite struct LastCaptureTests {
    private let blank = Document(width: 10, height: 10, scale: 1)
    private var annotated: Document {
        Document(width: 10, height: 10, scale: 1, annotations: [Annotation(shape: .rectangle(CGRect(x: 1, y: 1, width: 5, height: 5)), style: .standard)])
    }

    /// Option-F10's one closed capture: the latest closed, unless that would put annotated work
    /// out for a capture with none.
    @Test func annotatedWorkKeepsItsPlace() {
        #expect(Document.keepsAsLast(blank, over: nil))
        #expect(Document.keepsAsLast(blank, over: blank))
        #expect(!Document.keepsAsLast(blank, over: annotated))
        #expect(Document.keepsAsLast(annotated, over: annotated))
        #expect(Document.keepsAsLast(annotated, over: blank))
        // A crop is work too.
        #expect(!Document.keepsAsLast(blank, over: Document(width: 10, height: 10, scale: 1, crop: CGRect(x: 0, y: 0, width: 5, height: 5))))
    }
}

@Suite struct OpenedFileScaleTests {
    /// A file's DPI says its scale when it says more than 1x; else a picture wider than the
    /// screen is taken for a capture from that screen.
    @Test func dpiThenWidth() {
        #expect(Document.scale(ofFile: 2000, pointWidth: 1000, screenWidth: 1512, screenScale: 2) == 2)
        #expect(Document.scale(ofFile: 3000, pointWidth: 3000, screenWidth: 1512, screenScale: 2) == 2)
        #expect(Document.scale(ofFile: 800, pointWidth: 800, screenWidth: 1512, screenScale: 2) == 1)
        #expect(Document.scale(ofFile: 3000, pointWidth: 3000, screenWidth: nil, screenScale: 2) == 1)
        #expect(Document.scale(ofFile: 3000, pointWidth: 3000, screenWidth: 1920, screenScale: 1) == 1)
    }
}

@Suite struct ClickTargetTests {
    let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let windows = [CGRect(x: 100, y: 100, width: 400, height: 300), CGRect(x: 50, y: 50, width: 900, height: 700)]

    /// A click takes the frontmost window under it, or on the desktop the whole display.
    @Test func windowOrDesktop() {
        #expect(SelectionRule.clickTarget(at: CGPoint(x: 200, y: 200), windows: windows, bounds: bounds) == (windows[0], true))
        #expect(SelectionRule.clickTarget(at: CGPoint(x: 900, y: 600), windows: windows, bounds: bounds) == (windows[1], true))
        #expect(SelectionRule.clickTarget(at: CGPoint(x: 1300, y: 900), windows: windows, bounds: bounds) == (bounds, false))
    }
}

@Suite struct KeystrokeTests {
    typealias Line = KeystrokeLine
    func key(_ code: UInt16, _ base: String, _ modifiers: Line.Modifiers = []) -> String? {
        Line.key(code: code, base: base, modifiers: modifiers)
    }

    /// Shortcuts show, their modifiers in the Mac's order; keys that act on their own show their
    /// symbol; typing shows nothing, letters, numbers, space, and the Delete keys alike.
    @Test func onlyShortcutsShow() {
        #expect(key(21, "4", [.command, .shift]) == "⇧⌘4")
        #expect(key(8, "c", [.command]) == "⌘C")
        #expect(key(8, "c", [.control, .option, .shift, .command]) == "⌃⌥⇧⌘C")
        #expect(key(36, "\r") == "↩" && key(53, "\u{1b}") == "⎋" && key(123, "") == "←" && key(109, "") == "F10")
        #expect(key(48, "\t", [.shift]) == "⇧⇥" && key(36, "\r", [.command]) == "⌘↩")
        #expect(key(51, "\u{7f}", [.command]) == "⌘⌫" && key(49, " ", [.control]) == "⌃␣")
        for typing in [key(4, "h"), key(4, "h", [.shift]), key(25, "9"), key(49, " "), key(51, "\u{7f}"), key(117, "")] {
            #expect(typing == nil)
        }
    }

    /// Shortcuts within two seconds of each other join one line; a pause of two starts afresh;
    /// a line shows for five seconds after its last key.
    @Test func aSequenceReadsAsOne() {
        var line = Line()
        line.add("⌘I", at: 0)
        line.add("⌃K", at: 0.8)
        line.add("↩", at: 2.4)
        #expect(line.text == "⌘I  ⌃K  ↩")
        line.add("⌘S", at: 2.4 + Line.joinGap)
        #expect(line.text == "⌘S")
        let last = 2.4 + Line.joinGap
        #expect(line.visible(at: last + 4.9) == "⌘S" && line.visible(at: last + Line.linger) == nil)
    }

    @Test func aLongLineShowsItsEnd() {
        var line = Line()
        for i in 0..<30 { line.add("⌘\(i % 10)", at: Double(i) * 0.1) }
        #expect(line.text.count == Line.longest && line.text.hasPrefix("…") && line.text.hasSuffix("⌘9"))
    }
}
