import FluidAudio

/// Speech to text for dictation: Parakeet in the app, a fake in tests.
protocol DictationSpeech: Sendable {
    /// Loads the model when it is already downloaded, so the first dictation is quick.
    func warmUp() async throws
    func transcribe(_ recording: DictationCapture.Recording) async throws -> String
}

/// Dictation's own Parakeet, kept loaded, so the meetings' one stays free to
/// load and unload. Quiet audio is boosted first.
struct ParakeetSpeech: DictationSpeech {
    let parakeet = ParakeetEngine()
    /// Fetches Parakeet if it is missing, shared with meetings so two
    /// downloads never race.
    let downloadModel: @MainActor @Sendable () async throws -> Void

    func warmUp() async throws {
        if ParakeetEngine.isDownloaded() { try await parakeet.prepare() }
    }

    func transcribe(_ recording: DictationCapture.Recording) async throws -> String {
        let samples = try AudioConverter().resample(recording.samples, from: recording.sampleRate)
        if !ParakeetEngine.isDownloaded() { try await downloadModel() }
        try await parakeet.prepare()
        return try await parakeet.transcribe(samples: Loudness.normalized(samples))
    }
}
