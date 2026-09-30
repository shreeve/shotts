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

@MainActor @Suite struct RecordingWindowLayoutTests {
    /// The player fills the window below the bar, edge to edge, however the window is sized.
    @Test(arguments: [(320, 200), (1898, 948)]) func thePlayerFillsTheWindowBelowTheBar(_ size: (Int, Int)) async throws {
        let recording = try await testRecording(width: size.0, height: size.1)
        let controller = RecordingWindowController(recording: recording, contents: try await RecordingExport.contents(of: recording))
        defer { controller.close() }
        let window = try #require(controller.window)
        // With the video loaded, as it is by the time anyone looks.
        for _ in 0..<200 where controller.player.player?.currentItem?.status != .readyToPlay {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(controller.player.player?.currentItem?.status == .readyToPlay)
        for size in [nil, CGSize(width: 900, height: 600), CGSize(width: 1400, height: 700)] {
            if let size { window.setContentSize(size) } // first, as it opens
            window.contentView?.layoutSubtreeIfNeeded()
            let content = try #require(window.contentView).bounds
            let player = controller.player.convert(controller.player.bounds, to: nil)
            #expect(player.minX == 0 && player.width == content.width, "player \(player) in \(content)")
            let timeline = controller.timeline.convert(controller.timeline.bounds, to: nil)
            #expect(timeline.minY == 0 && timeline.width == content.width)
            #expect(player.minY == timeline.maxY && player.height > content.height - 100)
        }
    }
}

@MainActor @Suite struct TrimmingTests {
    /// Dragging a bracket trims what every format's file keeps once the drag ends, and makes
    /// the file again; dragging it back to the end keeps all of it.
    @Test func dragsTrimEveryFormat() async throws {
        let recording = try await testRecording()
        let controller = RecordingWindowController(recording: recording, contents: try await RecordingExport.contents(of: recording))
        defer { controller.close() }
        let track = controller.timeline.track
        track.frame = CGRect(x: 0, y: 0, width: 212, height: 28) // 200 points of track for 1 s
        track.pressed(at: 6)
        track.dragged(to: 56)
        #expect(controller.current.trim == nil) // not while dragging
        track.released()
        let trim = try #require(controller.current.trim)
        #expect(abs(trim.start - 0.25) < 0.001 && trim.end > 0.99)
        controller.formats.selectItem(at: 1)
        controller.formatChanged()
        #expect(controller.current.trim == trim)
        track.pressed(at: 56)
        track.dragged(to: 0)
        track.released()
        #expect(controller.current.trim == nil)
    }

    /// A press on the track away from the brackets moves the playhead there.
    @Test func aPressOnTheTrackMovesThePlayhead() async throws {
        let recording = try await testRecording()
        let controller = RecordingWindowController(recording: recording, contents: try await RecordingExport.contents(of: recording))
        defer { controller.close() }
        let track = controller.timeline.track
        track.frame = CGRect(x: 0, y: 0, width: 212, height: 28)
        track.pressed(at: 106)
        track.released()
        #expect(abs(controller.timeline.playhead - 0.5) < 0.001)
        #expect(controller.current.trim == nil)
        #expect(controller.timeline.time.stringValue == "0:00 / 0:01")
    }
}

@MainActor @Suite struct RecordingBarTests {
    private func setup() throws -> RecordingSetup {
        let screen = try #require(NSScreen.screens.first)
        return RecordingSetup(screen: screen, rect: CGRect(x: 100, y: 100, width: 300, height: 200), microphone: false) { _ in }
    }

    /// Once recording, the panel is the recording bar: one drawing tool at a time, which the
    /// drawing layer takes; Escape turns it off; Pause and Stop reach the recording.
    @Test func theBarDrawsPausesAndStops() throws {
        let setup = try setup()
        defer { setup.close() }
        let panel = try #require(setup.setupPanel)
        #expect(!setup.windowNumbers.contains(setup.drawing.windowNumber))
        #expect(setup.keptNumbers == [setup.drawing.windowNumber])
        setup.recording()
        #expect(panel.recording)
        panel.arrow.performClick(nil)
        #expect(setup.drawing.tool == .arrow && !setup.drawing.ignoresMouseEvents)
        panel.rectangle.performClick(nil)
        #expect(setup.drawing.tool == .rectangle && panel.arrow.state == .off && panel.rectangle.state == .on)
        panel.cancelOperation(nil)
        #expect(setup.drawing.tool == nil && setup.drawing.ignoresMouseEvents && panel.rectangle.state == .off)

        var controls: [RecordingSetup.Control] = []
        setup.onControl = { controls.append($0) }
        panel.pause.performClick(nil)
        panel.pause.performClick(nil)
        panel.stop.performClick(nil)
        #expect(controls == [.pause, .resume, .stop])
    }
}

@MainActor @Suite struct DrawingCanvasTests {
    /// A drag with a tool on leaves the shape; one too small to see, or with no tool, leaves
    /// nothing.
    @Test func dragsDrawShapes() {
        let canvas = DrawingCanvas(size: CGSize(width: 300, height: 200), scale: 2)
        canvas.pressed(at: CGPoint(x: 10, y: 10))
        canvas.dragged(to: CGPoint(x: 100, y: 100))
        canvas.released()
        #expect(canvas.shapes.isEmpty)
        canvas.tool = .arrow
        canvas.pressed(at: CGPoint(x: 10, y: 10))
        canvas.dragged(to: CGPoint(x: 100, y: 100))
        canvas.released()
        guard case let .arrow(from, to)? = canvas.shapes.first?.annotation.shape else { Issue.record("no arrow"); return }
        #expect(from == CGPoint(x: 20, y: 20) && to == CGPoint(x: 200, y: 200)) // in the area's pixels
        canvas.tool = .rectangle
        canvas.pressed(at: CGPoint(x: 50, y: 50))
        canvas.dragged(to: CGPoint(x: 50.5, y: 50.5))
        canvas.released()
        #expect(canvas.shapes.count == 1)
    }

    /// A shape shows fully for four seconds, then fades out over one.
    @Test func shapesFadeAfterFourSeconds() {
        let drawn = Date(timeIntervalSinceReferenceDate: 0)
        #expect(DrawingCanvas.opacity(drawn: drawn, now: drawn.addingTimeInterval(3.9)) == 1)
        #expect(abs(DrawingCanvas.opacity(drawn: drawn, now: drawn.addingTimeInterval(4.5)) - 0.5) < 1e-9)
        #expect(DrawingCanvas.opacity(drawn: drawn, now: drawn.addingTimeInterval(5)) == 0)
    }
}
