import XCTest

@testable import LechuzaEngine

/// A recognizer that answers from a table and fails any file it doesn't know.
private struct FakeRecognizer: SpeechRecognizer {
    struct Failure: Error {}
    let answers: [String: [TranscriptSegment]]

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        guard let segments = answers[audio.lastPathComponent] else { throw Failure() }
        return segments
    }
}

final class TranscriberTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lechuza-transcriber-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in ["mic.aac", "system.aac"] {
            try Data().write(to: dir.appendingPathComponent(file))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// The partial transcript never stands alone: without the error file
    /// next to it, a crash before the engine records the failure would leave
    /// it looking Ready.
    func testAFailedSegmentFailsTheTranscriptionAndKeepsTheRest() async throws {
        let recognizer = FakeRecognizer(answers: ["mic.aac": [TranscriptSegment(start: 1, end: 2, text: "Hi.")]])
        let inputs = [
            SessionMeta.TrackInput(file: "mic.aac", speaker: "me", offsetMs: 0),
            SessionMeta.TrackInput(file: "system.aac", speaker: "them", offsetMs: 0),
        ]
        do {
            try await Transcriber.transcribe(dir, inputs: inputs, captureStatus: .complete, with: recognizer)
            XCTFail("a segment failed, so the transcription must too")
        } catch {
            XCTAssertTrue("\(error)".contains("system.aac"), "\(error)")
            let saved = try String(contentsOf: dir.appendingPathComponent(Transcriber.errorFile), encoding: .utf8)
            XCTAssertEqual(saved, "\(error)\n")
        }

        let transcript = try JSONDecoder().decode(
            Transcript.self, from: Data(contentsOf: dir.appendingPathComponent("transcript.json")))
        XCTAssertEqual(transcript.segments.map(\.text), ["Hi."])
    }

    func testATranscriptionThatSucceedsClearsAnEarlierFailure() async throws {
        let errorFile = dir.appendingPathComponent(Transcriber.errorFile)
        try Data("Couldn't transcribe system.aac\n".utf8).write(to: errorFile)
        let recognizer = FakeRecognizer(answers: [
            "mic.aac": [TranscriptSegment(start: 1, end: 2, text: "Hi.")],
            "system.aac": [TranscriptSegment(start: 3, end: 4, text: "Hola.")],
        ])
        let inputs = [
            SessionMeta.TrackInput(file: "mic.aac", speaker: "me", offsetMs: 0),
            SessionMeta.TrackInput(file: "system.aac", speaker: "them", offsetMs: 0),
        ]
        try await Transcriber.transcribe(dir, inputs: inputs, captureStatus: .complete, with: recognizer)

        XCTAssertFalse(FileManager.default.fileExists(atPath: errorFile.path))
    }

    func testLeavesOutTheirWordsTheMicHeard() async throws {
        let recognizer = FakeRecognizer(answers: [
            "mic.aac": [TranscriptSegment(start: 3.6, end: 6.9, text: "The budget moves to Thursday.")],
            "system.aac": [TranscriptSegment(start: 3.5, end: 6.8, text: "The budget moves to Thursday.")],
        ])
        let inputs = [
            SessionMeta.TrackInput(file: "mic.aac", speaker: "me", offsetMs: 0),
            SessionMeta.TrackInput(file: "system.aac", speaker: "them", offsetMs: 0),
        ]
        try await Transcriber.transcribe(dir, inputs: inputs, captureStatus: .complete, with: recognizer)

        let transcript = try JSONDecoder().decode(
            Transcript.self, from: Data(contentsOf: dir.appendingPathComponent("transcript.json")))
        XCTAssertEqual(transcript.segments.map(\.speaker), ["them"])
    }

    /// meta.json names a segment that isn't on disk: the meeting is missing
    /// audio, so it fails, keeping what the other segments said.
    func testAMissingSegmentFailsTheTranscriptionAndKeepsTheRest() async throws {
        try FileManager.default.removeItem(at: dir.appendingPathComponent("system.aac"))
        let recognizer = FakeRecognizer(answers: ["mic.aac": [TranscriptSegment(start: 1, end: 2, text: "Hi.")]])
        let inputs = [
            SessionMeta.TrackInput(file: "mic.aac", speaker: "me", offsetMs: 0),
            SessionMeta.TrackInput(file: "system.aac", speaker: "them", offsetMs: 0),
        ]
        do {
            try await Transcriber.transcribe(dir, inputs: inputs, captureStatus: .complete, with: recognizer)
            XCTFail("a segment is missing, so the transcription must fail")
        } catch {
            XCTAssertTrue("\(error)".contains("system.aac"), "\(error)")
        }

        let transcript = try JSONDecoder().decode(
            Transcript.self, from: Data(contentsOf: dir.appendingPathComponent("transcript.json")))
        XCTAssertEqual(transcript.segments.map(\.text), ["Hi."])
    }
}
