import Foundation

/// Turns a finished session's segment files into transcript.json and
/// transcript.md: mic segments become "me" lines and system segments "them",
/// each shifted onto the session clock and merged by time. Progress goes to
/// the session's transcribe.log.
enum Transcriber {
    /// Left in the session folder when transcription fails, holding the
    /// reason; the app shows it until a retry succeeds.
    static let errorFile = "transcript-error.txt"

    static func transcribe(
        _ dir: URL,
        inputs: [SessionMeta.TrackInput],
        captureStatus: TrackStatus,
        with engine: ParakeetEngine
    ) async throws {
        var merged: [Transcript.Segment] = []
        for input in inputs {
            let audio = dir.appendingPathComponent(input.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing segment \(input.file)")
                continue
            }
            log(dir, "transcribing \(input.file)")
            // One bad segment (empty, truncated) shouldn't cost us the rest —
            // log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                log(dir, "skipping \(input.file): \(error)")
                continue
            }
            merged += Transcript.shifted(segments, speaker: input.speaker, offsetMs: input.offsetMs)
        }
        merged.sort { $0.start_ms < $1.start_ms }

        let transcript = Transcript(
            engine: ParakeetEngine.name,
            model: ParakeetEngine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: merged
        )
        try transcript.write(to: dir, captureStatus: captureStatus)
        log(dir, "done — \(merged.count) segments")
    }

    /// Append a timestamped line to the session's transcribe.log.
    static func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
