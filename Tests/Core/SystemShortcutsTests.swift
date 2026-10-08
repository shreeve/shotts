import Testing
@testable import ShottsCore

@Suite struct SystemShortcutsTests {
    let shiftCommand = SystemShortcuts.shift | SystemShortcuts.command
    let four = SystemShortcuts.four

    func entry(_ enabled: Int, _ keyCode: Int, _ modifiers: Int) -> [String: Any] {
        ["enabled": enabled, "value": ["parameters": [52, keyCode, modifiers], "type": "standard"]]
    }

    /// Never changed, macOS's ⇧⌘4 is on: macOS answers it, and Shotts does not.
    @Test func untouchedItIsMacOSs() {
        #expect(SystemShortcuts.macOSAnswers(keyCode: four, modifiers: shiftCommand, in: nil))
        #expect(SystemShortcuts.macOSAnswers(keyCode: four, modifiers: shiftCommand, in: ["60": entry(0, 49, 262_144)]))
        #expect(!SystemShortcuts.macOSAnswers(keyCode: four, modifiers: shiftCommand | SystemShortcuts.option, in: nil))
    }

    /// Turned off in Keyboard Shortcuts, it is Shotts'; moved to another key, too; another of
    /// macOS's shortcuts set to it keeps it macOS's.
    @Test func offOrMovedItIsShottss() {
        #expect(!SystemShortcuts.macOSAnswers(keyCode: four, modifiers: shiftCommand, in: ["30": entry(0, four, shiftCommand)]))
        #expect(!SystemShortcuts.macOSAnswers(keyCode: four, modifiers: shiftCommand, in: ["30": entry(1, 22, shiftCommand)]))
        #expect(SystemShortcuts.macOSAnswers(keyCode: four, modifiers: shiftCommand,
                                              in: ["30": entry(0, four, shiftCommand), "31": entry(1, four, shiftCommand)]))
        #expect(SystemShortcuts.macOSAnswers(keyCode: four, modifiers: shiftCommand, in: ["30": ["enabled": true]]))
    }
}
