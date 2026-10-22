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
        }

        let transcript = try JSONDecoder().decode(
            Transcript.self, from: Data(contentsOf: dir.appendingPathComponent("transcript.json")))
        XCTAssertEqual(transcript.segments.map(\.text), ["Hi."])
    }
}
