import Foundation

/// What the transcriber needs from a speech model: Parakeet in the app, a
/// fake in tests.
protocol SpeechRecognizer: Sendable {
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment]
}

extension ParakeetEngine: SpeechRecognizer {}

/// Turns a finished session's segment files into transcript.json and
/// transcript.md: mic segments become "me" lines and system segments "them",
/// each shifted onto the session clock and merged by time. Progress goes to
/// the session's transcribe.log.
enum Transcriber {
    /// Left in the session folder when transcription fails, holding the
    /// reason; the app shows it until a retry succeeds, which removes it.
    static let errorFile = "transcript-error.txt"

    /// Some segments couldn't be transcribed. The rest are in the transcript.
    struct SegmentsFailed: Error, CustomStringConvertible {
        let failures: [(file: String, error: any Error)]

        var description: String {
            failures.map { "Couldn't transcribe \($0.file): \($0.error)" }.joined(separator: "\n")
        }
    }

    /// meta.json names a segment file that isn't in the folder.
    struct MissingSegment: Error, CustomStringConvertible {
        var description: String { "the file is missing" }
    }

    /// Transcribe every input into the transcript. A segment that fails
    /// doesn't cost the rest: the transcript keeps what worked, then this
    /// throws `SegmentsFailed`, so the meeting shows as failed with Retry.
    static func transcribe(
        _ dir: URL,
        inputs: [SessionMeta.TrackInput],
        captureStatus: TrackStatus,
        with engine: some SpeechRecognizer
    ) async throws {
        var merged: [Transcript.Segment] = []
        var failures: [(file: String, error: any Error)] = []
        for input in inputs {
            let audio = dir.appendingPathComponent(input.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "missing segment \(input.file)")
                failures.append((input.file, MissingSegment()))
                continue
            }
            log(dir, "transcribing \(input.file)")
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                log(dir, "failed \(input.file): \(error)")
                failures.append((input.file, error))
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
        // The app reads transcript.json without the error file as Ready, so
        // the failure is on disk before a partial transcript, and cleared only
        // after a full one. A crash in between leaves the meeting failed.
        let failed = failures.isEmpty ? nil : SegmentsFailed(failures: failures)
        if let failed { try recordFailure(failed, in: dir) }
        try transcript.write(to: dir, captureStatus: captureStatus)
        log(dir, "done — \(merged.count) segments")
        if let failed { throw failed }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(errorFile))
    }

    /// Leave `error` in the folder as the reason transcription failed.
    static func recordFailure(_ error: any Error, in dir: URL) throws {
        try Data("\(error)\n".utf8).write(to: dir.appendingPathComponent(errorFile), options: .atomic)
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
