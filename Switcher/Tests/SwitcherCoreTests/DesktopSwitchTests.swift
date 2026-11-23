import Testing
@testable import SwitcherCore

@Suite struct DesktopSwitchTests {
    /// macOS 26.6 and later; 26.0-26.5 land on blank desktops.
    @Test func availableFrom26Point6() {
        #expect(!DesktopSwitch.isAvailable(major: 14, minor: 0))
        #expect(!DesktopSwitch.isAvailable(major: 26, minor: 5))
        #expect(DesktopSwitch.isAvailable(major: 26, minor: 6))
        #expect(DesktopSwitch.isAvailable(major: 27, minor: 0))
        #expect(!DesktopSwitch.needsPayload(major: 26) && DesktopSwitch.needsPayload(major: 27))
    }

    /// No switch past the first or last desktop.
    @Test func clampedAtTheEnds() {
        #expect(DesktopSwitch.target(from: 0, of: 3, right: true) == 1)
        #expect(DesktopSwitch.target(from: 0, of: 3, right: false) == nil)
        #expect(DesktopSwitch.target(from: 2, of: 3, right: true) == nil)
        #expect(DesktopSwitch.target(from: 2, of: 3, right: false) == 1)
    }

    /// The measured numbers: macOS 26 tiny throughout; macOS 27 tiny until the fling, rightward
    /// negative, flipped again with Natural scrolling off.
    @Test func theSwipesNumbers() {
        typealias S = DesktopSwitch.Swipe
        #expect(DesktopSwitch.swipe(.changed, right: true, payload: false, naturalScrolling: true) == S(progress: 1e-4, velocity: 2000))
        #expect(DesktopSwitch.swipe(.ended, right: false, payload: false, naturalScrolling: false) == S(progress: -1e-4, velocity: -2000))
        #expect(DesktopSwitch.swipe(.began, right: true, payload: true, naturalScrolling: true) == S(progress: -1e-4, velocity: 0))
        #expect(DesktopSwitch.swipe(.ended, right: true, payload: true, naturalScrolling: true) == S(progress: -0.1, velocity: -9999))
        #expect(DesktopSwitch.swipe(.ended, right: true, payload: true, naturalScrolling: false) == S(progress: 0.1, velocity: 9999))
        #expect(DesktopSwitch.isRight(0.65) && !DesktopSwitch.isRight(-0.57))
    }

    /// The payload's layout: 28-byte header, 40-byte gesture record, and on the fling a
    /// 28-byte velocity record; a tiny progress keeps its sign in 16.16.
    @Test func thePayloadsLayout() {
        let began = DesktopSwitch.payload(timestamp: 7, phase: .began, swipe: .init(progress: -1e-4, velocity: 0))
        #expect(began.count == 68)
        #expect(began[0] == 7 && began[24] == 1)                        // timestamp, one event
        #expect(Array(began[28..<36]) == [40, 0, 0, 0, 23, 0, 0, 0])     // size 40, fluid touch
        #expect(began[39] == 1)                                           // phase in the top byte
        #expect(Array(began[60..<64]) == [1, 0, 3, 0])                   // horizontal, Dock flavor
        #expect(Array(began[64..<68]) == [0xFA, 0xFF, 0xFF, 0xFF])       // -1e-4 as -6
        let ended = DesktopSwitch.payload(timestamp: 7, phase: .ended, swipe: .init(progress: -0.1, velocity: -9999))
        #expect(ended.count == 96 && ended[24] == 2 && ended[39] == 4)
        #expect(Array(ended[68..<76]) == [28, 0, 0, 0, 9, 0, 0, 0])      // velocity record
        #expect(DesktopSwitch.fixed1616(1e-9) == 1 && DesktopSwitch.fixed1616(-1e-9) == -1 && DesktopSwitch.fixed1616(0) == 0)
    }

    /// The payload rides in a serialized event under field 4205, length first, big-endian.
    @Test func thePayloadIsAppendedUnderItsField() {
        #expect(DesktopSwitch.appending([9, 9], to: [0, 0, 0, 2, 5]) == [0, 0, 0, 2, 5, 0, 2, 0x10, 0x6D, 9, 9])
        #expect(DesktopSwitch.appending([9], to: [0, 0, 0, 1]) == nil)
    }
}
