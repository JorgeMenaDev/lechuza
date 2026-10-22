import AppKit

/// Dictation anywhere. The hotkey drives `HotkeyGesture`; its actions start
/// the microphone, or stop it and send the audio to `speech`, which stays
/// loaded so a short sentence is pasted about a second after release.
/// Transcriptions run one at a time, in the order they were spoken. The
/// words go to the app that was in front when the dictation stopped. Esc
/// throws away the dictation that is listening, or else the ones still
/// being transcribed.
@MainActor
final class Dictation {
    /// Audio kept after the release, so the last syllable isn't cut off.
    private static let tail = Duration.milliseconds(150)

    typealias MakeKeyTap = (Hotkey, @escaping @Sendable (HotkeyGesture.Input, TimeInterval) -> Void) -> KeyTap?

    private let emit: @Sendable (EngineEvent) -> Void
    private let speech: any DictationSpeech
    private let microphone: () -> any DictationMicrophone
    private let makeKeyTap: MakeKeyTap
    private let paster: Paster
    private var gesture = HotkeyGesture()
    private var keys: KeyTap?
    private var capture: (any DictationMicrophone)?
    private var startedAt = Date()
    private var timeout: Task<Void, Never>?
    // The latest transcription; the next one waits for it.
    private var queue: Task<Void, Never>?
    /// Dictations being transcribed that will still be pasted.
    private var pending = 0
    /// Goes up when Esc throws away the dictations being transcribed.
    private var generation = 0
    private var phase = DictationPhase.idle

    /// The microphone, key tap and paster are the Mac's own unless a test
    /// passes fakes.
    init(
        emit: @escaping @Sendable (EngineEvent) -> Void,
        speech: any DictationSpeech,
        microphone: @escaping () -> any DictationMicrophone = { DictationCapture() },
        keyTap: @escaping MakeKeyTap = { KeyTap(hotkey: $0, onInput: $1) },
        paster: Paster = Paster()
    ) {
        self.emit = emit
        self.speech = speech
        self.microphone = microphone
        self.makeKeyTap = keyTap
        self.paster = paster
    }

    /// Listen for `hotkey` from now on, and load the model if it's here. A
    /// dictation under way stops: the new tap knows nothing of its key.
    func configure(hotkey: Hotkey) {
        interrupt(because: "The dictation key changed, so Lechuza stopped listening.")
        keys?.stop()
        keys = makeKeyTap(hotkey) { input, time in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    if input == .interrupted {
                        self?.interrupt(because: "Lechuza missed some keys, so it stopped listening. Try again.")
                    } else {
                        self?.handle(input, at: time)
                    }
                }
            }
        }
        if keys == nil { emit(.error(message: "no event tap for the hotkey: Accessibility isn't granted")) }
        publish()
        Task { [speech, emit] in
            do { try await speech.warmUp() } catch { emit(.error(message: "dictation model didn't load: \(error)")) }
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

    /// One input from the key tap (or the Flow bar), at `time` on the uptime clock.
    func handle(_ input: HotkeyGesture.Input, at time: TimeInterval) {
        if input == .escape, !gesture.isDictating, pending > 0 {
            generation += 1
            pending = 0
        }
        for action in gesture.handle(input, at: time) {
            switch action {
            case .start: begin()
            case .commit: finish(insert: true)
            case .cancel: finish(insert: false)
            }
        }
        timeout?.cancel()
        if let deadline = gesture.deadline {
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime)))
                if !Task.isCancelled { self?.handle(.timeout, at: ProcessInfo.processInfo.systemUptime) }
            }
        }
        publish()
    }

    /// Key events or the microphone were lost: throw the dictation away and
    /// say why.
    private func interrupt(because message: String) {
        let wasDictating = gesture.isDictating
        handle(.interrupted, at: ProcessInfo.processInfo.systemUptime)
        if wasDictating { emit(.dictationFailed(message: message)) }
    }

    private func begin() {
        let capture = microphone()
        let id = ObjectIdentifier(capture)
        do {
            try capture.start(
                onLevel: { [emit] level in emit(.dictationLevel(level: Double(level))) },
                onLost: {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { [weak self] in
                            guard let self, self.capture.map(ObjectIdentifier.init) == id else { return }
                            interrupt(because: "The microphone changed, so Lechuza stopped listening. Try again.")
                        }
                    }
                })
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
        let dictated = Dictated(
            startedAt: startedAt, spokenMs: Int(Date().timeIntervalSince(startedAt) * 1000),
            target: paster.target(), generation: generation)
        let previous = queue
        pending += 1
        queue = Task { [weak self] in
            try? await Task.sleep(for: Self.tail)
            let recording = capture.stop()
            await previous?.value
            await self?.transcribe(recording, dictated)
        }
    }

    /// One dictation on its way to the paste.
    private struct Dictated {
        let startedAt: Date
        let spokenMs: Int
        /// The app in front when it stopped.
        let target: pid_t?
        let generation: Int
    }

    private func transcribe(_ recording: DictationCapture.Recording, _ dictated: Dictated) async {
        let text: String
        do {
            text = try await speech.transcribe(recording)
        } catch {
            return finished(dictated, failure: "\(error)")
        }
        guard dictated.generation == generation else { return }
        guard !text.isEmpty else { return finished(dictated, failure: "Lechuza didn't hear anything.") }
        let outcome = paster.paste(text, into: dictated.target)
        emit(
            .dictationDone(
                text: text, startedAt: ISO8601DateFormatter().string(from: dictated.startedAt),
                durationMs: dictated.spokenMs))
        finished(dictated, failure: outcome.problem)
        // The next dictation waits too, so it never saves these words as the clipboard.
        await paster.restoreClipboard()
    }

    /// A dictation is done with, unless Esc threw it away first.
    private func finished(_ dictated: Dictated, failure: String?) {
        guard dictated.generation == generation else { return }
        pending -= 1
        if let failure { emit(.dictationFailed(message: failure)) }
        publish()
    }

    /// The dictation couldn't start: forget the gesture and say why.
    private func fail(_ message: String) {
        gesture = HotkeyGesture()
        emit(.dictationFailed(message: message))
    }

    /// Tells the key tap whether Esc is Lechuza's, and the app when the phase changes.
    private func publish() {
        keys?.escapeIsOurs.withLock { [gesture, pending] in $0 = gesture.isDictating || pending > 0 }
        let phase: DictationPhase =
            switch gesture.state {
            case .pressed, .tapped, .secondPress: .listening
            case .handsFree, .stopPress: .handsFree
            case .idle, .awaitingRelease: pending > 0 ? .transcribing : .idle
            }
        guard phase != self.phase else { return }
        self.phase = phase
        emit(.dictationState(phase: phase))
    }
}

extension Paster.Outcome {
    /// What the Flow bar says when the words weren't pasted. They are in the history either way.
    var problem: String? {
        switch self {
        case .pasted: nil
        case .noAccessibility: "Allow Accessibility so Lechuza can paste. Your words are saved in Lechuza."
        case .appChanged: "Saved in Lechuza: you switched apps before it could paste."
        case .failed: "Lechuza couldn't paste. Your words are saved in Lechuza."
        }
    }
}
