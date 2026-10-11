import AppKit
import ShottsCore
import ShottsUI

/// What `shotts` asks of Shotts, done: listing what can be captured, taking a still, and
/// recording. It answers only while Allow Command-Line Capture is on, which is off until the
/// user turns it on in the menu: Shotts' Screen Recording permission is not lent to any program
/// that asks without that. A recording made this way shows in the menu bar like any other, and
/// F10 or the timer stops it; its files are made before the answer goes back.
final class ScriptRunner {
    static var isAllowed: Bool {
        get { ScriptServer.isAllowed(in: .standard, domain: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName) }
        set { UserDefaults.standard.set(newValue, forKey: ScriptServer.allowedKey) }
    }

    private var server: ScriptServer?
    /// Whether a recording from the picker is being set up, made, or finished: one at a time.
    var isRecordingElsewhere: () -> Bool = { false }
    /// Tells the menu bar item when a recording starts, with its recorder, and stops, with nil.
    var onRecording: ((Recorder?) -> Void)?
    /// Whole seconds left before a delayed capture, for the menu bar item; nil when done.
    var onCountdown: ((Int?) -> Void)?
    /// The recording asked for, from its request until its files are made.
    private var session: Session?
    /// The last recording's answer, which `stop` gives when nothing is recording.
    private var last: ScriptResult?
    /// Stills being taken, from their countdown until their files are placed.
    private var stills = 0

    private final class Session {
        let request: ScriptRequest
        let aim: ScriptAim
        let outputs: [ScriptFiles.Output]
        /// The tool that asked: `record` until the files are made, `start` until it is recording.
        var asker: ScriptConnection?
        /// Those waiting on `stop` for the files.
        var stoppers: [ScriptConnection] = []
        var recorder: Recorder?
        var started: Date?
        var limit: Timer?
        /// Stopped or aborted before it began recording.
        var ended = false
        var finishing = false
        /// The files being made, which `abort` cancels.
        var saving: Task<Void, Never>?
        var aborted = false

        init(request: ScriptRequest, aim: ScriptAim, outputs: [ScriptFiles.Output], asker: ScriptConnection) {
            self.request = request
            self.aim = aim
            self.outputs = outputs
            self.asker = asker
        }
    }

    func start() {
        let server = ScriptServer(path: ScriptSocket.path(home: NSHomeDirectory())) { [weak self] request, connection in
            self?.handle(request, from: connection)
        }
        do {
            try server.start()
            self.server = server
        } catch {
            // Another Shotts answers, or the folder is not safe to listen in: this one stays quiet.
        }
    }

    func stopListening() { server?.stop() }

    /// Whether a recording asked for by `shotts` is under way, which F10 and quitting stop.
    var isRecording: Bool { session?.recorder != nil && session?.finishing == false }

    /// Whether a request is being carried out, from its countdown until its files are placed:
    /// the picker opened now would be in its capture, and a recording started now a second one.
    var isBusy: Bool { session != nil || stills > 0 }

    /// Recordings asked for by `shotts` whose files are not yet placed, which quitting would
    /// lose: at most one, since one records at a time.
    var unsavedRecordings: Int { session?.recorder != nil ? 1 : 0 }

    /// F10, the menu bar timer, or quitting: the recording ends and its files are made.
    func stopRecording() {
        guard let session, session.recorder != nil else { return }
        end(session, keeping: true)
    }

    // MARK: - Requests

    private func handle(_ request: ScriptRequest, from connection: ScriptConnection) {
        // Checked as the tool checks it: anything of the user's can write to the socket.
        do {
            try ScriptParser.check(request)
        } catch {
            return answer(connection, .failure(request.command, ScriptError(.usage, error.message)))
        }
        guard request.command.isTaken(allowed: Self.isAllowed, recording: session != nil) else {
            return answer(connection, .failure(request.command, ScriptError(.notAllowed,
                "Shotts does not take requests from the command line until Allow Command-Line Capture is on in its menu")))
        }
        if request.command == .stop || request.command == .abort { return stop(request, from: connection) }
        guard ScreenCapture.hasPermission else {
            let asked = "capture.askedPermission"
            if !UserDefaults.standard.bool(forKey: asked) {
                UserDefaults.standard.set(true, forKey: asked)
                ScreenCapture.requestPermission()
            }
            return answer(connection, .failure(request.command, ScriptError(.permission,
                "Shotts needs to record the screen: turn it on under System Settings › Privacy & Security › Screen & System Audio Recording")))
        }
        let displays = ScreenCapture.numberedDisplays()
        let numbered = displays.map {
            ScriptDisplay(number: $0.number, frame: [$0.bounds.minX, $0.bounds.minY, $0.bounds.width, $0.bounds.height], scale: $0.scale)
        }
        let windows = ScreenCapture.scriptWindows(on: displays)
        if request.command == .list {
            var result = ScriptResult(command: .list)
            result.windows = windows
            result.displays = numbered
            return answer(connection, result)
        }
        let aim: ScriptAim
        switch ScriptAim.of(request.target, windows: windows, displays: numbered) {
        case let .success(a): aim = a
        case let .failure(error): return answer(connection, .failure(request.command, error))
        }
        if request.command == .shot {
            Task { await shot(request, aim: aim, displays: displays, connection: connection) }
        } else {
            record(request, aim: aim, displays: displays, connection: connection)
        }
    }

    private func answer(_ connection: ScriptConnection, _ result: ScriptResult) {
        connection.send(result)
        connection.close()
    }

    private static func timestamp(_ date: Date) -> String {
        date.ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .colon))
    }

    /// Counts down `request.delay` in the menu bar; false if the wait was given up.
    private func wait(_ request: ScriptRequest, while going: () -> Bool) async -> Bool {
        guard request.delay > 0 else { return true }
        let end = Date.now.addingTimeInterval(request.delay)
        defer { onCountdown?(nil) }
        while case let left = end.timeIntervalSinceNow, left > 0 {
            guard going() else { return false }
            onCountdown?(Int(exactly: left.rounded(.up)) ?? 0)
            try? await Task.sleep(for: .seconds(min(left, 0.1)))
        }
        return going()
    }

    // MARK: - Stills

    private func shot(_ request: ScriptRequest, aim: ScriptAim, displays: [ScreenCapture.NumberedDisplay], connection: ScriptConnection) async {
        stills += 1
        defer { stills -= 1 }
        guard await wait(request, while: { !connection.isGone }) else { return }
        let image: CGImage, scale: Double
        let started = Date.now
        do {
            switch aim.source {
            case let .window(id):
                let captured = try await ScreenCapture.captureWindow(id, shadow: false)
                (image, scale) = (captured.image, Double(captured.scale))
            case let .area(number, rect):
                guard let display = displays.first(where: { $0.number == number }) else { throw ScreenCapture.Failure.noDisplay }
                image = try await ScreenCapture.captureArea(display: display.id, rect: rect, scale: display.scale)
                scale = display.scale
            }
        } catch {
            return answer(connection, .failure(.shot, ScriptError(.captureFailed, error.localizedDescription)))
        }
        var info = aim.info
        info.scale = scale
        var made: [ScriptFiles.Made] = []
        let files: [ScriptFile]
        do {
            for output in ScriptFiles.outputs(for: request, date: started) {
                made.append(try await ScriptFiles.make(output) { url in
                    try ScriptFiles.writeStill(image, scale: scale, width: request.width, format: output.format, to: url)
                })
            }
            files = try ScriptFiles.place(made)
        } catch {
            ScriptFiles.discard(made)
            return answer(connection, .failure(.shot, ScriptError(.encodeFailed, error.localizedDescription)))
        }
        answer(connection, ScriptResult(command: .shot, state: "done", target: info, started: Self.timestamp(started), files: files))
    }

    // MARK: - Recordings

    private func record(_ request: ScriptRequest, aim: ScriptAim, displays: [ScreenCapture.NumberedDisplay], connection: ScriptConnection) {
        guard session == nil, !isRecordingElsewhere() else {
            return answer(connection, .failure(request.command, ScriptError(.busy, "Shotts is already recording; `shotts stop` ends it")))
        }
        let session = Session(request: request, aim: aim, outputs: ScriptFiles.outputs(for: request), asker: connection)
        self.session = session
        // The tool gone (a Control-C, a closed terminal): a recording ends and keeps its files;
        // one not yet recording ends there. `start` has its answer and has gone by design.
        connection.onClose { [weak self, weak session] in
            guard let self, let session, self.session === session, session.asker != nil else { return }
            session.asker = nil
            end(session, keeping: session.recorder != nil)
        }
        Task { await begin(session, displays: displays) }
    }

    private func begin(_ session: Session, displays: [ScreenCapture.NumberedDisplay]) async {
        let request = session.request
        let audio = request.audio ?? .none
        // The microphone's permission is asked before any countdown, so that macOS's prompt comes
        // while the person who typed the command is there; refused, the recording does not start.
        if audio.includesMicrophone, !(await CaptureFlow.microphoneAllowed()) {
            return failed(session, ScriptError(.permission,
                "Shotts may not use the microphone: turn it on under System Settings › Privacy & Security › Microphone"))
        }
        guard await wait(request, while: { !session.ended }) else { return gaveUp(session) }
        let recorder = Recorder()
        recorder.onInterrupted = { [weak self, weak session] in
            guard let self, let session else { return }
            end(session, keeping: true)
        }
        do {
            switch session.aim.source {
            case let .window(id):
                try await recorder.start(window: id, microphone: audio.includesMicrophone, sound: audio.includesSystem)
            case let .area(number, rect):
                guard let display = displays.first(where: { $0.number == number }) else { throw ScreenCapture.Failure.noDisplay }
                try await recorder.start(display: display.id, scale: display.scale, rect: rect, excluding: [], keeping: [],
                                         microphone: audio.includesMicrophone, sound: audio.includesSystem)
            }
            guard await recorder.firstFrame(within: 5) else { throw Failure.noFrame }
        } catch {
            if let made = try? await recorder.stop() { Recording.removeFolder(made.folder) }
            return failed(session, ScriptError(.captureFailed, error.localizedDescription))
        }
        guard !session.ended else {
            if let made = try? await recorder.stop() { Recording.removeFolder(made.folder) }
            return gaveUp(session)
        }
        let started = Date.now
        session.recorder = recorder
        session.started = started
        onRecording?(recorder)
        let ready = ScriptResult(command: request.command, state: "recording", target: session.aim.info, started: Self.timestamp(started))
        if request.command == .start, let asker = session.asker {
            session.asker = nil
            answer(asker, ready)
        } else {
            session.asker?.send(ready)
        }
        if let limit = request.duration ?? (request.command == .start ? ScriptRequest.startCap : nil) {
            end(session, after: limit, of: recorder)
        }
    }

    /// Ends the recording once `recorder` has run `limit` seconds, pauses not counted: one timer
    /// for what is left, set again should a pause have made it early.
    private func end(_ session: Session, after limit: Double, of recorder: Recorder) {
        let timer = Timer(timeInterval: max(limit - recorder.elapsed, 0.01), repeats: false) { [weak self, weak session, weak recorder] _ in
            MainActor.assumeIsolated {
                guard let self, let session, let recorder, self.session === session, !session.finishing else { return }
                if recorder.elapsed >= limit { self.end(session, keeping: true) } else { self.end(session, after: limit, of: recorder) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        session.limit = timer
    }

    private enum Failure: LocalizedError {
        case noFrame

        var errorDescription: String? { "Nothing came to record: is the window on screen, not minimized or hidden?" }
    }

    /// Stopped before recording began: nothing to keep.
    private func gaveUp(_ session: Session) {
        failed(session, ScriptError(.captureFailed, "Stopped before recording began."), stopped: true)
    }

    private func failed(_ session: Session, _ error: ScriptError, stopped: Bool = false) {
        if self.session === session { self.session = nil }
        if let asker = session.asker { answer(asker, .failure(session.request.command, error)) }
        for stopper in session.stoppers {
            answer(stopper, stopped ? ScriptResult(command: .stop, state: "done") : .failure(.stop, error))
        }
    }

    /// `stop` makes the files and answers with them; `abort`, a second Control-C, keeps nothing.
    /// With nothing recording, `stop` gives the last recording's answer.
    private func stop(_ request: ScriptRequest, from connection: ScriptConnection) {
        guard let session else {
            var result = last ?? ScriptResult(command: .stop, state: "done")
            result.command = .stop
            return answer(connection, result)
        }
        session.stoppers.append(connection)
        end(session, keeping: request.command == .stop)
    }

    private func end(_ session: Session, keeping keep: Bool) {
        guard self.session === session else { return }
        if session.finishing {
            // Already stopped: `abort` gives up the files being made, and those made already.
            if !keep {
                session.aborted = true
                session.saving?.cancel()
            }
            return
        }
        guard let recorder = session.recorder else {
            // Not yet recording: `begin` sees this and gives up.
            session.ended = true
            return
        }
        session.finishing = true
        session.limit?.invalidate()
        onRecording?(nil)
        session.saving = Task { await finish(session, recorder: recorder, keeping: keep) }
    }

    /// Tells those waiting which file is being made, and how far through them all it is.
    private func report(_ session: Session, saving path: String, progress: Double) {
        guard self.session === session, !session.aborted else { return }
        var result = ScriptResult(command: session.request.command, state: "saving")
        result.saving = path
        result.progress = min(progress, 1)
        session.asker?.send(result)
        result.command = .stop
        for stopper in session.stoppers { stopper.send(result) }
    }

    private func finish(_ session: Session, recorder: Recorder, keeping keep: Bool) async {
        let request = session.request
        let recording: Recording
        do {
            recording = try await recorder.stop()
        } catch {
            return failed(session, ScriptError(.captureFailed, error.localizedDescription))
        }
        defer { Recording.removeFolder(recording.folder) }
        let notKept = ScriptError(.captureFailed, "Stopped without keeping the recording.")
        guard keep, !session.aborted else { return failed(session, notKept, stopped: true) }
        // Every file is made before any is placed: `abort` then leaves each path as it was.
        var made: [ScriptFiles.Made] = []
        let outputs = session.outputs
        for (index, output) in outputs.enumerated() {
            guard let video = output.format.recording else { continue }
            let fps = request.fps ?? ScriptRequest.defaultFrameRate(for: video)
            // Without --width, the size a file from the recording window starts at: an MP4 the
            // recording's, a GIF the area's on screen.
            let percent = RecordingRule.defaults(for: video, scale: recording.scale, hasMicrophone: false).percent
            // Sound only in an MP4, and only what --audio asked for.
            let sound = video == .mp4 ? request.audio ?? .none : .none
            let settings = RecordingSettings(format: video, percent: percent, frameRate: fps, sound: sound, width: request.width)
            report(session, saving: output.path, progress: Double(index) / Double(outputs.count))
            do {
                made.append(try await ScriptFiles.make(output, fps: fps) { url in
                    let written = try await RecordingExport.write(recording, settings: settings, to: url) { [weak self] done in
                        Task { @MainActor in self?.report(session, saving: output.path, progress: (Double(index) + done) / Double(outputs.count)) }
                    }
                    return (written.width, written.height, written.frames)
                })
            } catch {
                ScriptFiles.discard(made)
                return failed(session, session.aborted ? notKept : ScriptError(.encodeFailed, error.localizedDescription), stopped: session.aborted)
            }
        }
        let duration = (try? await RecordingExport.contents(of: recording))?.duration
        // Aborted as the last file was finished: nothing is placed then either.
        guard !session.aborted else {
            ScriptFiles.discard(made)
            return failed(session, notKept, stopped: true)
        }
        let files: [ScriptFile]
        do {
            files = try ScriptFiles.place(made)
        } catch {
            return failed(session, ScriptError(.encodeFailed, error.localizedDescription))
        }
        let result = ScriptResult(command: request.command, state: "done", target: session.aim.info, started: session.started.map(Self.timestamp),
                                  duration: duration, files: files)
        last = result
        if self.session === session { self.session = nil }
        if let asker = session.asker { answer(asker, result) }
        for stopper in session.stoppers {
            var answered = result
            answered.command = .stop
            answer(stopper, answered)
        }
    }
}
