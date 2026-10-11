import Testing
@testable import ShottsCore

@Suite struct AutoScrollTests {
    /// Steps a sixth of the area, up to 120 points: never more than the stitching can match,
    /// however short the area.
    @Test func stepsFitTheArea() {
        #expect(AutoScroll(areaHeight: 600, now: 0).step == 100)
        #expect(AutoScroll(areaHeight: 2000, now: 0).step == 120)
        #expect(AutoScroll(areaHeight: 48, now: 0).step == 8)
        #expect(AutoScroll(areaHeight: AutoScroll.shortest, now: 0).step == 4)
    }

    /// An area too short for any frame's move to be matched: it gives up at once.
    @Test func tooShortGivesUpAtOnce() {
        var auto = AutoScroll(areaHeight: AutoScroll.shortest - 1, now: 0)
        #expect(auto.next(height: 0, lost: false, full: false, now: 0.05) == .giveUp)
    }

    /// It scrolls while the picture grows, and finishes once it has not grown for `settle`.
    @Test func theBottomIsWhereItStopsGrowing() {
        var auto = AutoScroll(areaHeight: 600, now: 0)
        var height = 840, t = 0.0
        // Growing: scroll on.
        for _ in 0..<10 {
            t += AutoScroll.tick
            height += 120
            #expect(auto.next(height: height, lost: false, full: false, now: t) == .scroll(100))
        }
        // At the bottom: nothing new, so scrolling goes on for a moment, then it finishes.
        var action = AutoScroll.Action.scroll(0)
        var still = 0.0
        while action != .finish {
            t += AutoScroll.tick
            still += AutoScroll.tick
            action = auto.next(height: height, lost: false, full: false, now: t)
        }
        #expect(abs(still - AutoScroll.settle) < AutoScroll.tick * 1.5)
    }

    /// A page that goes on growing still stops at `limit`, with what it has.
    @Test func itStopsAtTheLimit() {
        var auto = AutoScroll(areaHeight: 600, now: 10)
        var height = 840
        var t = 10.0
        while t < 10 + AutoScroll.limit - AutoScroll.tick / 2 {
            height += 120
            #expect(auto.next(height: height, lost: false, full: false, now: t) == .scroll(100))
            t += AutoScroll.tick
        }
        #expect(auto.next(height: height + 120, lost: false, full: false, now: 10 + AutoScroll.limit) == .finish)
    }

    /// Nothing is scrolled before the first frame, so the picture starts where the area did,
    /// and the wait does not count toward the bottom.
    @Test func itWaitsForTheFirstFrame() {
        var auto = AutoScroll(areaHeight: 600, now: 0)
        #expect(auto.next(height: 0, lost: false, full: false, now: 0.05) == .wait)
        #expect(auto.next(height: 0, lost: false, full: false, now: 1.9) == .wait)
        #expect(auto.next(height: 840, lost: false, full: false, now: 1.95) == .scroll(100))
        #expect(auto.next(height: 940, lost: false, full: false, now: 2.0) == .scroll(100))
    }

    /// No frame at all: it gives up rather than hold the mouse for nothing.
    @Test func noFrameGivesUp() {
        var auto = AutoScroll(areaHeight: 600, now: 10)
        var t = 10.0, actions: [AutoScroll.Action] = []
        while actions.last != .giveUp, t < 20 {
            t += AutoScroll.tick
            actions.append(auto.next(height: 0, lost: false, full: false, now: t))
        }
        #expect(actions.dropLast().allSatisfy { $0 == .wait } && actions.last == .giveUp)
        #expect(abs(t - 10 - AutoScroll.firstFrameWithin) < AutoScroll.tick * 1.5)
    }

    /// Nothing new after the first frame: the other way once, then the frame is all there is.
    @Test func nothingNewTriesTheOtherWayOnce() {
        var auto = AutoScroll(areaHeight: 600, now: 0)
        var t = 0.0
        var actions: [AutoScroll.Action] = []
        while actions.last != .finish, t < 5 {
            t += AutoScroll.tick
            actions.append(auto.next(height: 840, lost: false, full: false, now: t))
        }
        #expect(actions.contains(.scroll(100)) && actions.contains(.scroll(-100)) && actions.last == .finish)
        #expect(t > AutoScroll.settle * 2 - AutoScroll.tick && t < AutoScroll.settle * 2 + AutoScroll.tick * 2)
        // The other way works: it goes on that way.
        var turned = AutoScroll(areaHeight: 600, now: 0)
        var u = 0.0, h = 840
        while turned.direction == 1, u < 5 { u += AutoScroll.tick; _ = turned.next(height: h, lost: false, full: false, now: u) }
        h += 200
        #expect(turned.next(height: h, lost: false, full: false, now: u + AutoScroll.tick) == .scroll(-100))
    }

    /// A frame not matched: back a step, then half the speed, never below the slowest.
    @Test func tooFastBacksUpAndSlows() {
        var auto = AutoScroll(areaHeight: 600, now: 0)
        #expect(auto.next(height: 840, lost: false, full: false, now: 0.05) == .scroll(100))
        #expect(auto.next(height: 840, lost: true, full: false, now: 0.1) == .scroll(-100))
        #expect(auto.next(height: 900, lost: false, full: false, now: 0.15) == .scroll(50))
        for i in 0..<10 { _ = auto.next(height: 900, lost: true, full: false, now: 0.2 + Double(i) * 0.05) }
        #expect(auto.step == AutoScroll.slowest)
    }

    /// A frame not matched right after a back-up was on its way before it: it is not counted,
    /// and the speed is not halved again.
    @Test func aMissRightAfterABackUpIsNotCounted() {
        var auto = AutoScroll(areaHeight: 600, now: 0)
        #expect(auto.next(height: 840, lost: false, full: false, now: 0.05) == .scroll(100))
        #expect(auto.next(height: 840, lost: true, full: false, now: 0.1) == .scroll(-100))
        #expect(auto.next(height: 840, lost: true, full: false, now: 0.15) == .scroll(50))
        #expect(auto.step == 50)
    }

    /// After a back-up, the speed comes back as frames match again, up to the first.
    @Test func theSpeedComesBack() {
        var auto = AutoScroll(areaHeight: 600, now: 0)
        var h = 840, t = 0.05
        _ = auto.next(height: h, lost: false, full: false, now: t)
        t += AutoScroll.tick
        #expect(auto.next(height: h, lost: true, full: false, now: t) == .scroll(-100))
        var actions: [AutoScroll.Action] = []
        for _ in 0..<6 {
            t += AutoScroll.tick
            h += 100
            actions.append(auto.next(height: h, lost: false, full: false, now: t))
        }
        #expect(actions == [.scroll(50), .scroll(62.5), .scroll(78.125), .scroll(97.65625), .scroll(100), .scroll(100)])
    }

    /// Frames that keep not matching, nothing added between: it gives up rather than bob,
    /// after `giveUpAfter` back-ups, each miss in flight after one not counted.
    @Test func endlessMissesGiveUp() {
        var auto = AutoScroll(areaHeight: 600, now: 0)
        _ = auto.next(height: 840, lost: false, full: false, now: 0.05)
        var actions: [AutoScroll.Action] = []
        while actions.last != .giveUp, actions.count < 100 {
            actions.append(auto.next(height: 840, lost: true, full: false, now: 0.1 + Double(actions.count) * 0.05))
        }
        #expect(actions.dropLast().allSatisfy { if case .scroll = $0 { true } else { false } })
        #expect(actions.last == .giveUp && actions.count == AutoScroll.giveUpAfter * 2 - 1)
        #expect(actions.count { if case let .scroll(points) = $0 { points < 0 } else { false } } == AutoScroll.giveUpAfter - 1)
        // Misses with rows added between them never add up.
        var steady = AutoScroll(areaHeight: 600, now: 0)
        var h = 840
        for i in 0..<20 {
            h += 50
            _ = steady.next(height: h, lost: false, full: false, now: Double(i) * 0.1)
            #expect(steady.next(height: h, lost: true, full: false, now: Double(i) * 0.1 + 0.05) != .giveUp)
        }
    }

    /// As tall as it may be: done.
    @Test func fullFinishes() {
        var auto = AutoScroll(areaHeight: 600, now: 0)
        #expect(auto.next(height: 30000, lost: false, full: true, now: 1) == .finish)
    }
}
