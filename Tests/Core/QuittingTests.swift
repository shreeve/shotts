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
}
