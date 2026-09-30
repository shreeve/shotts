import AppKit
import ShottsCore
import Testing
@testable import ShottsUI

@MainActor @Suite struct RecordingSetupTests {
    private let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)

    /// The panel goes below the area, centered; above when there is no room below; inside
    /// when there is room on neither side; and always on screen.
    @Test func thePanelSitsBesideTheArea() {
        let size = CGSize(width: 300, height: 44)
        #expect(RecordingSetup.panelOrigin(size: size, beside: CGRect(x: 300, y: 400, width: 400, height: 200), on: visible)
            == CGPoint(x: 350, y: 344))
        #expect(RecordingSetup.panelOrigin(size: size, beside: CGRect(x: 300, y: 20, width: 400, height: 200), on: visible)
            == CGPoint(x: 350, y: 232))
        #expect(RecordingSetup.panelOrigin(size: size, beside: CGRect(x: 0, y: 0, width: 1000, height: 800), on: visible)
            == CGPoint(x: 350, y: 12))
        #expect(RecordingSetup.panelOrigin(size: size, beside: CGRect(x: 900, y: 400, width: 100, height: 100), on: visible).x == 700)
    }

    /// Return records, with the microphone as the switch says; Escape cancels; either once.
    @Test func returnRecordsAndEscapeCancels() throws {
        let screen = try #require(NSScreen.screens.first)
        var outcomes: [RecordingSetup.Outcome] = []
        let setup = RecordingSetup(screen: screen, rect: CGRect(x: 100, y: 100, width: 300, height: 200), microphone: true) { outcomes.append($0) }
        defer { setup.close() }
        let panel = try #require(setup.setupPanel)
        #expect(setup.windowNumbers.count == 2)
        panel.microphone.state = .off
        panel.record.performClick(nil)
        panel.cancelOperation(nil)
        #expect(outcomes.count == 1)
        guard case let .record(microphone)? = outcomes.first else { Issue.record("did not record"); return }
        #expect(!microphone)

        var cancelled = false
        let other = RecordingSetup(screen: screen, rect: CGRect(x: 100, y: 100, width: 300, height: 200), microphone: false) {
            if case .cancelled = $0 { cancelled = true }
        }
        try #require(other.setupPanel).cancelOperation(nil)
        #expect(cancelled)
    }

    /// The area is where the picker put it, flipped into screen coordinates.
    @Test func theAreaIsInScreenCoordinates() throws {
        let screen = try #require(NSScreen.screens.first)
        let setup = RecordingSetup(screen: screen, rect: CGRect(x: 10, y: 20, width: 300, height: 200), microphone: false) { _ in }
        defer { setup.close() }
        #expect(setup.area == CGRect(x: screen.frame.minX + 10, y: screen.frame.maxY - 220, width: 300, height: 200))
    }
}

@MainActor @Suite struct RecordingWindowTests {
    private func window(for recording: Recording) async throws -> RecordingWindowController {
        let contents = try await RecordingExport.contents(of: recording)
        return RecordingWindowController(recording: recording, contents: contents)
    }

    private func waitForFile(_ controller: RecordingWindowController) async throws -> URL {
        for _ in 0..<400 {
            if let file = controller.file { return file }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw CancellationError()
    }

    /// It opens on an MP4 at the recording's size and 30 frames a second, with the microphone,
    /// and makes that file, whose size it shows.
    @Test func itMakesTheFileItsSettingsSay() async throws {
        let controller = try await window(for: try await testRecording())
        defer { controller.close() }
        #expect(controller.current == RecordingSettings(format: .mp4, width: 320, frameRate: 30, sound: .microphone))
        #expect(controller.widthField.integerValue == 320 && controller.heightLabel.stringValue == "× 200")
        #expect(!controller.sounds.isHidden && controller.sounds.numberOfItems == 4)
        let file = try await waitForFile(controller)
        #expect(file.pathExtension == "mp4" && file.lastPathComponent.hasPrefix("Shotts Recording "))
        #expect(controller.status.stringValue.contains("KB") || controller.status.stringValue.contains("MB"))
    }

    /// A GIF has no sound and stops at 30 frames a second, and it starts at the area's size on
    /// screen; switching back finds the MP4's settings as they were.
    @Test func eachFormatKeepsItsOwnSettings() async throws {
        let controller = try await window(for: try await testRecording())
        defer { controller.close() }
        controller.rates.selectItem(withTag: 60)
        controller.rateChanged()
        controller.formats.selectItem(at: 1)
        controller.formatChanged()
        #expect(controller.current == RecordingSettings(format: .gif, width: 160, frameRate: 15, sound: .none))
        #expect(controller.sounds.isHidden)
        #expect(controller.rates.itemArray.map(\.tag) == [30, 20, 15, 12, 10])
        let gif = try await waitForFile(controller)
        #expect(gif.pathExtension == "gif")
        controller.formats.selectItem(at: 0)
        controller.formatChanged()
        #expect(controller.current.frameRate == 60)
    }

    /// A width is kept even and within the recording, and the height follows.
    @Test func aTypedWidthIsKeptInBounds() async throws {
        let controller = try await window(for: try await testRecording())
        defer { controller.close() }
        controller.widthField.integerValue = 9999
        controller.widthChanged()
        #expect(controller.current.width == 320)
        controller.widthField.integerValue = 161
        controller.widthChanged()
        #expect(controller.current.width == 160 && controller.heightLabel.stringValue == "× 100")
    }

    /// Copy puts the file itself on the pasteboard, as the Finder does.
    @Test func copyPutsTheFileOnThePasteboard() async throws {
        let controller = try await window(for: try await testRecording())
        defer { controller.close() }
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        controller.pasteboard = pasteboard
        controller.copyPressed()
        let file = try await waitForFile(controller)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        #expect(urls == [file])
    }

    /// Closing the window takes the recording and every file made from it.
    @Test func closingDeletesTheRecording() async throws {
        let recording = try await testRecording()
        let controller = try await window(for: recording)
        _ = try await waitForFile(controller)
        controller.window?.close()
        #expect(!FileManager.default.fileExists(atPath: recording.folder.path))
    }
}
