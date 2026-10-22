import AVFoundation
import FluidAudio
import Foundation

/// One timed span of recognized speech from a single audio file, relative to
/// that file's own start.
struct TranscriptSegment: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// Parakeet TDT 0.6B v3 via FluidAudio's Core ML port: 25 European languages,
/// English and Spanish included, detected per file. The models download once
/// into FluidAudio's cache (~600 MB); after that, transcription runs entirely
/// on-device.
actor ParakeetEngine {
    enum EngineError: Error, CustomStringConvertible {
        case unreadableAudio(URL, Error?)

        var description: String {
            switch self {
            case .unreadableAudio(let url, let e):
                return "Unreadable or empty audio in \(url.lastPathComponent)"
                    + (e.map { ": \($0)" } ?? "")
            }
        }
    }

    static let name = "parakeet"
    static let model = "parakeet-tdt-0.6b-v3-coreml"

    private var manager: AsrManager?

    /// Whether the model files are already in FluidAudio's cache.
    static func isDownloaded() -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }

    /// Download the model files without loading them. Returns at once when
    /// they are already cached.
    static func download(progress: @escaping ProgressHandler) async throws {
        try await AsrModels.download(version: .v3, progressHandler: progress)
    }

    /// Load the model, downloading it first if it is missing. Later calls
    /// return at once.
    func prepare() async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager()
        try await manager.loadModels(models)
        self.manager = manager
    }

    /// Unload the model, so the engine doesn't idle holding it in memory.
    func release() async {
        if let manager { await manager.cleanup() }
        manager = nil
    }

    /// Transcribe one audio file into sentence-sized segments. Call
    /// `prepare` first.
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        // A track with no frames (recorder died before its first buffer)
        // makes AVFoundation raise an ObjC exception deep inside the
        // resampler — uncatchable from Swift, so it takes the whole engine
        // down. Check readability up front instead.
        let tooShort: Bool
        do {
            let probe = try AVAudioFile(forReading: audio)
            guard probe.length > 0 else { throw EngineError.unreadableAudio(audio, nil) }
            tooShort = Double(probe.length) / probe.fileFormat.sampleRate < ASRConstants.minimumAudioDurationSeconds
            // A header can claim a short length over packets that don't
            // decode; only a clip that reads back counts as silence below.
            if tooShort, let buffer = AVAudioPCMBuffer(pcmFormat: probe.processingFormat, frameCapacity: AVAudioFrameCount(probe.length)) {
                try probe.read(into: buffer)
            }
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.unreadableAudio(audio, error)
        }
        // The model rejects clips under its minimum; one that short holds no
        // speech, so it must not fail the meeting.
        guard !tooShort else { return [] }

        guard let manager else { throw ASRError.notInitialized }

        var state = try TdtDecoderState()
        let result = try await manager.transcribe(audio, decoderState: &state)

        let words = buildWordTimings(from: result.tokenTimings ?? [])
        guard !words.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty
                ? []
                : [TranscriptSegment(start: 0, end: result.duration, text: text)]
        }
        return Self.segments(from: words)
    }

    /// Group word timings into readable segments: break on sentence-ending
    /// punctuation (Parakeet emits punctuation), a silence gap over a second,
    /// or a 60-word cap so a run-on speaker still wraps.
    static func segments(from words: [WordTiming]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var current: [WordTiming] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(
                TranscriptSegment(
                    start: first.startTime,
                    end: last.endTime,
                    text: current.map(\.word).joined(separator: " ")
                ))
            current = []
        }

        for word in words {
            if let last = current.last, word.startTime - last.endTime > 1.0 {
                flush()
            }
            current.append(word)
            let endsSentence =
                word.word.hasSuffix(".")
                || word.word.hasSuffix("?")
                || word.word.hasSuffix("!")
            if endsSentence || current.count >= 60 {
                flush()
            }
        }
        flush()
        return out
    }
}
