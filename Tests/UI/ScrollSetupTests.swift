import AppKit
import Testing
@testable import ShottsUI

@MainActor @Suite struct ScrollSetupTests {
    /// The panel says where the capture stands, with Done (Return) and Cancel (Escape), once.
    @Test func itSaysWhereItStands() throws {
        let screen = try #require(NSScreen.screens.first)
        var outcomes: [ScrollSetup.Outcome] = []
        let setup = ScrollSetup(screen: screen, rect: CGRect(x: 100, y: 100, width: 300, height: 200)) { outcomes.append($0) }
        defer { setup.close() }
        #expect(setup.windowNumbers.count == 2)
        let panel = setup.scrollPanel
        #expect(panel.done.keyEquivalent == "\r" && panel.cancel.keyEquivalent == "\u{1b}")
        setup.show(.scrolling)
        setup.showProgress(height: 2480, lost: false, full: false)
        #expect(panel.message.stringValue.hasPrefix("Scrolling") && panel.message.stringValue.contains("2,480"))
        for (state, words) in [(ScrollSetup.State.capturing, "Scroll down, then press F10"), (.gaveUp, "Couldn't follow it"),
                               (.needsPermission, "Scroll down, then press F10 (allow Accessibility")] {
            setup.show(state)
            #expect(panel.message.stringValue.hasPrefix(words))
        }
        setup.show(.capturing)
        setup.showProgress(height: 2480, lost: true, full: false)
        #expect(panel.message.stringValue.hasPrefix("Scroll a little slower"))
        setup.showProgress(height: 9000, lost: false, full: true)
        #expect(panel.message.stringValue.hasPrefix("As tall as it can be"))
        panel.done.performClick(nil)
        panel.cancelOperation(nil)
        #expect(outcomes.count == 1)
        guard case .done? = outcomes.first else { Issue.record("not done"); return }

        var cancelled = false
        let other = ScrollSetup(screen: screen, rect: CGRect(x: 100, y: 100, width: 300, height: 200)) { if case .cancelled = $0 { cancelled = true } }
        other.scrollPanel.cancelOperation(nil)
        #expect(cancelled)
    }
    /// With keyboard navigation on, a focused button's ring goes around the whole pill, not
    /// around its title, where it blurred the "D" of Done.
    @Test func theFocusRingIsThePill() throws {
        let screen = try #require(NSScreen.screens.first)
        let setup = ScrollSetup(screen: screen, rect: CGRect(x: 100, y: 100, width: 300, height: 200)) { _ in }
        defer { setup.close() }
        let done = setup.scrollPanel.done
        setup.scrollPanel.layoutIfNeeded()
        #expect(done.bounds.width > 40 && done.focusRingMaskBounds == done.bounds)
    }
}
