import Testing
@testable import ShottsCore

@Suite struct SystemShortcutsTests {
    let two = SystemShortcuts.two
    let shiftCommand = SystemShortcuts.shift | SystemShortcuts.command
    let optionShiftCommand = SystemShortcuts.option | SystemShortcuts.shift | SystemShortcuts.command

    func entry(_ enabled: Int, _ keyCode: Int, _ modifiers: Int) -> [String: Any] {
        ["enabled": enabled, "value": ["parameters": [50, keyCode, modifiers], "type": "standard"]]
    }

    /// ⇧⌘2 and ⌥⇧⌘2 are no shortcuts of macOS's out of the box, so Shotts has them, whatever
    /// else is on, and when the list cannot be read.
    @Test func shiftCommand2IsFree() {
        let lists: [[String: Any]?] = [nil, [:], ["60": entry(1, 49, 262_144)], ["30": ["enabled": true]]]
        for shortcuts in lists {
            #expect(!SystemShortcuts.macOSAnswers(keyCode: two, modifiers: shiftCommand, in: shortcuts))
            #expect(!SystemShortcuts.macOSAnswers(keyCode: two, modifiers: optionShiftCommand, in: shortcuts))
        }
    }

    /// Made one of macOS's shortcuts by the user, it is macOS's, with exactly its modifiers:
    /// ⇧⌘2 taken leaves ⌥⇧⌘2 to Shotts, and the other way about.
    @Test func aShortcutTheUserSetIsMacOSs() {
        let shiftCommandTaken = ["30": entry(1, two, shiftCommand)]
        #expect(SystemShortcuts.macOSAnswers(keyCode: two, modifiers: shiftCommand, in: shiftCommandTaken))
        #expect(!SystemShortcuts.macOSAnswers(keyCode: two, modifiers: optionShiftCommand, in: shiftCommandTaken))
        let optionTaken = ["31": entry(1, two, optionShiftCommand)]
        #expect(SystemShortcuts.macOSAnswers(keyCode: two, modifiers: optionShiftCommand, in: optionTaken))
        #expect(!SystemShortcuts.macOSAnswers(keyCode: two, modifiers: shiftCommand, in: optionTaken))
    }

    /// Turned off in Keyboard Shortcuts, or moved to another key, it is Shotts'; another of
    /// macOS's shortcuts on and set to it keeps it macOS's.
    @Test func offOrMovedItIsShottss() {
        #expect(!SystemShortcuts.macOSAnswers(keyCode: two, modifiers: shiftCommand, in: ["30": entry(0, two, shiftCommand)]))
        #expect(!SystemShortcuts.macOSAnswers(keyCode: two, modifiers: shiftCommand, in: ["30": entry(1, 22, shiftCommand)]))
        #expect(SystemShortcuts.macOSAnswers(keyCode: two, modifiers: shiftCommand,
                                              in: ["30": entry(0, two, shiftCommand), "31": entry(1, two, shiftCommand)]))
    }
}
