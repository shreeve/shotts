import Testing
@testable import SwitcherCore

@Suite struct SwipeTrackerTests {
    typealias V = SwipeTracker.Verdict

    /// A swipe is held back, switches once on its first move, and its companions go with it.
    @Test func aSwipeSwitchesOnce() {
        var t = SwipeTracker()
        #expect(t.passesCompanion)
        #expect(t.swipe(phase: 1, progress: 0, velocity: 0, passEnd: false) == V(passes: false))
        #expect(!t.passesCompanion)
        #expect(t.swipe(phase: 2, progress: 0, velocity: 0, passEnd: false) == V(passes: false))
        #expect(t.swipe(phase: 2, progress: 0.4, velocity: 0, passEnd: false) == V(passes: false, switchRight: true))
        #expect(t.swipe(phase: 2, progress: 0.8, velocity: 0, passEnd: false) == V(passes: false))
        #expect(t.swipe(phase: 4, progress: 0, velocity: 7, passEnd: false) == V(passes: false))
        #expect(t.passesCompanion)
    }

    /// A flick with no middle switches at its end, by its velocity.
    @Test func aFlickSwitchesAtTheEnd() {
        var t = SwipeTracker()
        _ = t.swipe(phase: 1, progress: 0, velocity: 0, passEnd: false)
        #expect(t.swipe(phase: 4, progress: 0, velocity: -7.2, passEnd: false) == V(passes: false, switchRight: false))
    }

    /// On macOS 27 a held-back swipe's end goes on, emptied.
    @Test func onMacOS27TheEndGoesOnEmptied() {
        var t = SwipeTracker()
        _ = t.swipe(phase: 1, progress: 0, velocity: 0, passEnd: true)
        _ = t.swipe(phase: 2, progress: -0.6, velocity: 0, passEnd: true)
        #expect(t.swipe(phase: 4, progress: -0.6, velocity: -7, passEnd: true) == V(passes: true, emptied: true))
    }

    /// Nothing held back, everything passes; a cancel drops and forgets.
    @Test func untrackedPassesAndCancelForgets() {
        var t = SwipeTracker()
        #expect(t.swipe(phase: 2, progress: 0.3, velocity: 0, passEnd: false) == V(passes: true))
        #expect(t.swipe(phase: 4, progress: 0, velocity: 3, passEnd: false) == V(passes: true))
        _ = t.swipe(phase: 1, progress: 0, velocity: 0, passEnd: false)
        #expect(t.swipe(phase: 8, progress: 0, velocity: 0, passEnd: false) == V(passes: false))
        #expect(t.passesCompanion)
        _ = t.swipe(phase: 1, progress: 0, velocity: 0, passEnd: false)
        t.reset()
        #expect(t.passesCompanion)
    }
}
