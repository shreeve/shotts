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
        #expect(Annotation(shape: .arrow(from: .zero, to: CGPoint(x: 1, y: 1)), style: style).isDegenerate)
        #expect(!Annotation(shape: .arrow(from: .zero, to: CGPoint(x: 40, y: 0)), style: style).isDegenerate)
        #expect(Annotation(shape: .text(origin: .zero, string: "", size: .zero), style: style).isDegenerate)
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

    @Test func arrowOutlineRunsFromTailToTipAndScalesWithStroke() {
        let long = ArrowGeometry(from: .zero, to: CGPoint(x: 100, y: 0), width: 4)
        #expect(long.tip == CGPoint(x: 100, y: 0))
        #expect(long.outline.contains(CGPoint(x: 99, y: 0)))       // the tip
        #expect(long.outline.contains(CGPoint(x: 85, y: 6)))       // inside the head
        #expect(!long.outline.contains(CGPoint(x: 50, y: 6)))      // beside the shaft
        #expect(long.outline.map(\.x).max()! == 100 && long.outline.map(\.x).min()! >= 0)
        let thick = ArrowGeometry(from: .zero, to: CGPoint(x: 100, y: 0), width: 10)
        #expect(thick.outline.map(\.y).max()! > long.outline.map(\.y).max()!)
        let tiny = ArrowGeometry(from: .zero, to: CGPoint(x: 10, y: 0), width: 10)
        #expect(tiny.outline.map(\.x).min()! >= -1)                 // the head never overshoots the tail
        let even = ArrowGeometry(from: .zero, to: CGPoint(x: 100, y: 0), width: 4, tapered: false)
        #expect(even.outline[0].y == 2 && even.outline[1].y == 2)  // the shaft is 4 wide at both ends
        #expect(long.outline[0].y < 1)                              // the tapered tail is a point
    }

    @Test func hexIsUppercaseRRGGBB() {
        #expect(RGBA.red.hex == "#FF3B30")
        #expect(RGBA(red: 0, green: 0.5, blue: 1).hex == "#0080FF")
    }

    @Test func styleDecodesOlderSettings() throws {
        let old = Data(#"{"color":{"red":0,"green":0,"blue":1,"alpha":1},"strokeWidth":6,"fontSize":24,"shadow":false,"outline":true}"#.utf8)
        let style = try JSONDecoder().decode(Style.self, from: old)
        #expect(style.strokeWidth == 6 && style.shadow == false && style.taperedArrows == true)
    }
}

@Suite struct CalloutLayoutTests {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)

    @Test func textSitsLeftOfATailWhoseArrowPointsRight() {
        let l = CalloutLayout(tail: CGPoint(x: 500, y: 300), tip: CGPoint(x: 800, y: 200), lineHeight: 40, maxWidth: 300, in: bounds)
        #expect(l.anchorsRight)
        #expect(l.rightEdge == 480)          // half a line short of the tail
        #expect(l.width == 300)
        #expect(l.origin.y == 280)           // first line centered on the tail
        #expect(l.alignment == .right)
        #expect(l.origin(for: CGSize(width: 300, height: 40), in: bounds) == CGPoint(x: 180, y: 280))
    }

    @Test func textSitsRightOfATailWhoseArrowPointsLeft() {
        let l = CalloutLayout(tail: CGPoint(x: 500, y: 300), tip: CGPoint(x: 100, y: 300), lineHeight: 40, maxWidth: 300, in: bounds)
        #expect(!l.anchorsRight)
        #expect(l.origin.x == 520)
        #expect(l.width == 300)
    }

    @Test func noRoomOnTheFarSideFlipsIt() {
        let l = CalloutLayout(tail: CGPoint(x: 30, y: 300), tip: CGPoint(x: 400, y: 300), lineHeight: 40, maxWidth: 300, in: bounds)
        #expect(!l.anchorsRight && l.origin.x == 50)
    }

    @Test func widthAndPositionStayInsideThePicture() {
        let l = CalloutLayout(tail: CGPoint(x: 900, y: 590), tip: CGPoint(x: 950, y: 500), lineHeight: 40, maxWidth: 300, in: bounds)
        #expect(l.rightEdge == 880 && l.width == 300)
        #expect(l.origin.y == 560)           // clamped to the bottom
        #expect(l.origin(for: CGSize(width: 200, height: 120), in: bounds).y == 480) // grew, so moved up
    }
}
