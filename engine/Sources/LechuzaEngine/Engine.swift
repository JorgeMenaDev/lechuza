import AVFoundation
import FluidAudio
import Foundation
import Synchronization

/// Acts on the app's commands and reports what happens as events. Lives on
/// the main actor, like the recording session; mixing and transcription run
/// off it. Paths in events are the ones the app sent, so it can match them.
@MainActor
final class Engine {
    private let emit: @Sendable (EngineEvent) -> Void
    private let parakeet = ParakeetEngine()
    private var session: RecordingSession?
    private var starting = false
    private var levels: Task<Void, Never>?
    private var download: Task<Void, Error>?
    private lazy var dictation = Dictation(emit: emit, downloadModel: { [weak self] in try await self?.downloadModel() })

    init(emit: @escaping @Sendable (EngineEvent) -> Void) {
        self.emit = emit
    }

    /// The first event: the engine is listening.
    func announce() {
        emit(.ready(modelDownloaded: ParakeetEngine.isDownloaded()))
    }

    /// Decode one stdin line and act on it in the background.
    func handle(line: String) {
        guard let command = try? JSONDecoder().decode(EngineCommand.self, from: Data(line.utf8)) else {
            emit(.error(message: "unreadable command: \(line)"))
            return
        }
        Task { await run(command) }
    }

    /// Act on one command; returns when its work is done.
    func run(_ command: EngineCommand) async {
        switch command {
        case .meetingStart(let root): await startMeeting(root: root)
        case .meetingStop: await stopMeeting()
        case .transcriptionStart(let dir): await transcribe(dir)
        case .modelPrepare: try? await downloadModel()
        case .dictationConfigure(let hotkey): dictation.configure(hotkey: hotkey)
        case .dictationStart: dictation.start()
        case .dictationStop: dictation.stop()
        }
    }

    /// Stdin closed (the app quit): save the meeting in progress, if any.
    func shutdown() async {
        if session != nil { await stopMeeting() }
    }

    // MARK: - Meetings

    private func startMeeting(root: String) async {
        guard session == nil, !starting else {
            emit(.meetingFailed(message: "A meeting is already recording."))
            return
        }
        starting = true
        defer { starting = false }
        guard await Self.microphoneAllowed() else {
            emit(
                .meetingFailed(
                    message:
                        "Lechuza can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone."
                ))
            return
        }

        let session: RecordingSession
        do {
            session = try RecordingSession(root: URL(fileURLWithPath: root, isDirectory: true))
            try session.start()
        } catch {
            emit(.meetingFailed(message: "\(error)"))
            return
        }
        session.onDegraded = { [emit] kind in
            emit(
                .meetingWarning(
                    message: "\(kind.label.capitalized) capture was lost. The recording will be marked incomplete."))
        }
        self.session = session
        emit(
            .meetingStarted(
                dir: session.dir.path, startedAt: ISO8601DateFormatter().string(from: session.startedAt)))

        levels = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let session = self.session else { return }
                let (mic, system) = session.levels()
                self.emit(.meetingLevel(mic: Double(mic), system: Double(system)))
            }
        }
    }

    private func stopMeeting() async {
        guard let session else {
            emit(.error(message: "no meeting is recording"))
            return
        }
        self.session = nil
        levels?.cancel()
        levels = nil
        let result = session.stop()
        // The mix is what the app plays. If it fails here, transcription
        // tries again and reports the error.
        do {
            let (inputs, _) = try SessionMeta.readInputs(from: result.dir)
            try await Mixer.mix(inputs, in: result.dir)
        } catch {
            Transcriber.log(result.dir, "mix failed: \(error)")
        }
        emit(.meetingStopped(dir: result.dir.path, status: result.status))
    }

    /// macOS asks for the microphone on first use, naming the app that
    /// spawned the engine.
    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: - Transcription

    private func transcribe(_ path: String) async {
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        let errorURL = dir.appendingPathComponent(Transcriber.errorFile)
        try? FileManager.default.removeItem(at: errorURL)
        emit(.transcriptionStarted(dir: path))
        do {
            let (inputs, captureStatus) = try SessionMeta.readInputs(from: dir)
            if !FileManager.default.fileExists(atPath: dir.appendingPathComponent(Mixer.fileName).path) {
                try await Mixer.mix(inputs, in: dir)
            }
            try await downloadModel()
            try await parakeet.prepare()
            try await Transcriber.transcribe(dir, inputs: inputs, captureStatus: captureStatus, with: parakeet)
            await parakeet.release()
            emit(.transcriptionDone(dir: path))
        } catch {
            await parakeet.release()
            Transcriber.log(dir, "transcription failed: \(error)")
            try? Data("\(error)\n".utf8).write(to: errorURL, options: .atomic)
            emit(.transcriptionFailed(dir: path, message: "\(error)"))
        }
    }

    /// Download the model once, however many commands ask at the same time.
    /// Reports progress, then model.ready; on failure model.failed, and the
    /// next call tries again.
    private func downloadModel() async throws {
        let task =
            download
            ?? Task { [emit] in
                let throttle = ProgressThrottle(emit: emit)
                try await ParakeetEngine.download(progress: { throttle.report($0) })
            }
        download = task
        do {
            try await task.value
            emit(.modelReady)
        } catch {
            if download == task { download = nil }
            emit(.modelFailed(message: "\(error)"))
            throw error
        }
    }
}

/// Passes download progress on only when the phase changes or the fraction
/// moves by a whole percent, so the app isn't flooded.
final class ProgressThrottle: Sendable {
    private let emit: @Sendable (EngineEvent) -> Void
    private let last = Mutex<(phase: ModelPhase, percent: Int)?>(nil)

    init(emit: @escaping @Sendable (EngineEvent) -> Void) {
        self.emit = emit
    }

    func report(_ progress: DownloadProgress) {
        let phase: ModelPhase =
            switch progress.phase {
            case .listing: .listing
            case .downloading: .downloading
            case .compiling: .compiling
            }
        let percent = Int(progress.fractionCompleted * 100)
        let changed = last.withLock { last in
            if let last, last.phase == phase, last.percent == percent { return false }
            last = (phase, percent)
            return true
        }
        if changed { emit(.modelProgress(phase: phase, fraction: progress.fractionCompleted)) }
    }
}

/// Writes events to stdout, one JSON line each, from any thread.
final class EventOutput: Sendable {
    private let lock = Mutex(())

    func send(_ event: EngineEvent) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let json = try? encoder.encode(event) else { return }
        lock.withLock { _ in FileHandle.standardOutput.write(json + Data("\n".utf8)) }
    }
}

/// The executable's entry point: reads commands from stdin, writes events to
/// stdout and logs to stderr. When stdin closes (the app quit), it saves any
/// meeting in progress and exits.
public enum EngineMain {
    @MainActor
    public static func run() -> Never {
        let output = EventOutput()
        let engine = Engine(emit: { output.send($0) })
        engine.announce()
        Thread.detachNewThread {
            while let line = readLine() {
                Task { @MainActor in engine.handle(line: line) }
            }
            Task { @MainActor in
                await engine.shutdown()
                exit(0)
            }
        }
        dispatchMain()
    }
}
