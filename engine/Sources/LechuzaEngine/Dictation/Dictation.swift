import AVFoundation
import AppKit
import FluidAudio

/// Dictation anywhere. The hotkey drives `HotkeyGesture`; its actions start
/// the microphone, or stop it and send the audio to Parakeet, which stays
/// loaded so a short sentence is pasted about a second after release.
/// Transcriptions run one at a time, in the order they were spoken. Its own
/// ParakeetEngine leaves the meetings' one free to load and unload.
@MainActor
final class Dictation {
    /// Audio kept after the release, so the last syllable isn't cut off.
    private static let tail = Duration.milliseconds(150)

    private let emit: @Sendable (EngineEvent) -> Void
    private let downloadModel: @MainActor () async throws -> Void
    private let parakeet = ParakeetEngine()
    private var gesture = HotkeyGesture()
    private var keys: KeyTap?
    private var capture: DictationCapture?
    private var startedAt = Date()
    private var timeout: Task<Void, Never>?
    // The latest transcription; the next one waits for it.
    private var queue: Task<Void, Never>?
    private var pending = 0
    private var phase = DictationPhase.idle

    /// `downloadModel` fetches Parakeet if it is missing, shared with meetings
    /// so two downloads never race.
    init(emit: @escaping @Sendable (EngineEvent) -> Void, downloadModel: @escaping @MainActor () async throws -> Void) {
        self.emit = emit
        self.downloadModel = downloadModel
    }

    /// Listen for `hotkey` from now on, and load the model if it's here.
    func configure(hotkey: Hotkey) {
        keys?.stop()
        keys = KeyTap(hotkey: hotkey) { input, time in
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.handle(input, at: time) } }
        }
        if keys == nil { emit(.error(message: "no event tap for the hotkey: Accessibility isn't granted")) }
        if ParakeetEngine.isDownloaded() {
            Task { [parakeet, emit] in
                do { try await parakeet.prepare() } catch { emit(.error(message: "dictation model didn't load: \(error)")) }
            }
        }
    }

    /// The Flow bar was clicked while idle.
    func start() {
        if !gesture.isDictating { handle(.click, at: ProcessInfo.processInfo.systemUptime) }
    }

    /// The Flow bar's stop button was clicked.
    func stop() {
        if gesture.state == .handsFree { handle(.click, at: ProcessInfo.processInfo.systemUptime) }
    }

    private func handle(_ input: HotkeyGesture.Input, at time: TimeInterval) {
        for action in gesture.handle(input, at: time) {
            switch action {
            case .start: begin()
            case .commit: finish(insert: true)
            case .cancel: finish(insert: false)
            }
        }
        keys?.dictating.withLock { $0 = gesture.isDictating }
        timeout?.cancel()
        if let deadline = gesture.deadline {
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime)))
                if !Task.isCancelled { self?.handle(.timeout, at: ProcessInfo.processInfo.systemUptime) }
            }
        }
        publish()
    }

    private func begin() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status != .denied, status != .restricted else {
            return fail("Lechuza can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone.")
        }
        let capture = DictationCapture()
        do {
            try capture.start { [emit] level in emit(.dictationLevel(level: Double(level))) }
        } catch {
            return fail("\(error)")
        }
        self.capture = capture
        startedAt = Date()
    }

    /// Stops the microphone, then transcribes and pastes, or throws the audio away.
    private func finish(insert: Bool) {
        guard let capture else { return }
        self.capture = nil
        guard insert else {
            _ = capture.stop()
            return
        }
        let startedAt = startedAt
        let spokenMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let previous = queue
        pending += 1
        queue = Task { [weak self] in
            try? await Task.sleep(for: Self.tail)
            let recording = capture.stop()
            await previous?.value
            await self?.transcribe(recording, startedAt: startedAt, spokenMs: spokenMs)
            self?.pending -= 1
            self?.publish()
        }
    }

    private func transcribe(_ recording: DictationCapture.Recording, startedAt: Date, spokenMs: Int) async {
        do {
            let samples = try AudioConverter().resample(recording.samples, from: recording.sampleRate)
            if !ParakeetEngine.isDownloaded() { try await downloadModel() }
            try await parakeet.prepare()
            let text = try await parakeet.transcribe(samples: Loudness.normalized(samples))
            guard !text.isEmpty else { return emit(.dictationFailed(message: "Lechuza didn't hear anything.")) }
            let clipboard = ClipboardSnapshot(replacingWith: text, on: .general)
            let pasted = Paste.pressCommandV()
            emit(
                .dictationDone(
                    text: text, startedAt: ISO8601DateFormatter().string(from: startedAt), durationMs: spokenMs))
            guard pasted else {
                return emit(
                    .dictationFailed(message: "Allow Accessibility so Lechuza can paste. Your words are on the clipboard."))
            }
            // The next dictation waits too, so it never saves this one's text as the clipboard.
            try? await Task.sleep(for: Paste.restoreDelay)
            clipboard.restore(on: .general)
        } catch {
            emit(.dictationFailed(message: "\(error)"))
        }
    }

    /// The dictation couldn't start: forget the gesture and say why.
    private func fail(_ message: String) {
        gesture = HotkeyGesture()
        emit(.dictationFailed(message: message))
    }

    /// Tells the app when the phase changes.
    private func publish() {
        let phase: DictationPhase =
            switch gesture.state {
            case .pressed, .tapped: .listening
            case .handsFree: .handsFree
            case .idle, .awaitingRelease: pending > 0 ? .transcribing : .idle
            }
        guard phase != self.phase else { return }
        self.phase = phase
        emit(.dictationState(phase: phase))
    }
}
