import Testing
@testable import ShottsCore

@Suite struct QuittingTests {
    /// Nothing to lose: no question. Otherwise one sentence naming what would go.
    @Test func itSaysWhatWouldBeLost() {
        #expect(Quitting.warning(captures: 0, recordings: 0) == nil)
        #expect(Quitting.warning(captures: 1, recordings: 0) == "An annotated capture will be lost.")
        #expect(Quitting.warning(captures: 0, recordings: 3) == "3 unsaved recordings will be lost.")
        #expect(Quitting.warning(captures: 2, recordings: 1) == "2 annotated captures and an unsaved recording will be lost.")
    }

    /// The user quitting: what is under way stops first, then Shotts asks only about what would
    /// be lost, and with nothing to lose it quits.
    @Test func quittingStopsThenAsks() {
        #expect(Quitting.reply(poweringOff: false, underWay: true, captures: 2, recordings: 1) == .stop)
        #expect(Quitting.reply(poweringOff: false, underWay: false, captures: 0, recordings: 1)
            == .ask("An unsaved recording will be lost."))
        #expect(Quitting.reply(poweringOff: false, underWay: false, captures: 0, recordings: 0) == .now)
    }

    /// A log-out, restart, or shut-down is never held up, by a question or by a recording.
    @Test func poweringOffQuitsAtOnce() {
        #expect(Quitting.reply(poweringOff: true, underWay: true, captures: 2, recordings: 1) == .now)
        #expect(Quitting.reply(poweringOff: true, underWay: false, captures: 1, recordings: 0) == .now)
    }
}
