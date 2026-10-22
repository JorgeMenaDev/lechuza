import AVFoundation
import XCTest

@testable import LechuzaEngine

/// Schema v2 write/read round-trips into ordered transcription inputs.
final class SessionMetaTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lechuza-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ json: String) throws {
        try Data(json.utf8).write(to: dir.appendingPathComponent("meta.json"))
    }

    func testV2RoundTripAcrossMultipleSegments() throws {
        let meta = SessionMeta(
            schema_version: 2,
            started: "2026-08-03T19:32:55Z",
            ended: "2026-08-03T20:09:35Z",
            duration_seconds: 2200,
            status: .recovered,
            tracks: [
                SessionMeta.Track(
                    kind: .mic,
                    speaker: "me",
                    status: .recovered,
                    segments: [
                        SessionMeta.Segment(
                            file: "mic.aac", start_offset_ms: 18, end_offset_ms: 1_687_869,
                            frames_written: 81_016_832, sample_rate_hz: 48000, channels: 1
                        ),
                        SessionMeta.Segment(
                            file: "mic-002.aac", start_offset_ms: 1_691_120, end_offset_ms: 2_200_014,
                            frames_written: 24_426_720, sample_rate_hz: 48000, channels: 1
                        ),
                    ],
                    interruptions: [
                        Interruption(
                            detected_offset_ms: 1_690_869, recovered_offset_ms: 1_691_120,
                            reason: "callback_stalled", attempts: 1, error: nil
                        )
                    ],
                    warnings: []
                ),
                SessionMeta.Track(
                    kind: .system,
                    speaker: "them",
                    status: .complete,
                    segments: [
                        SessionMeta.Segment(
                            file: "system.aac", start_offset_ms: 0, end_offset_ms: 2_200_000,
                            frames_written: 105_600_000, sample_rate_hz: 48000, channels: 2
                        )
                    ],
                    interruptions: [],
                    warnings: ["exact digital silence for 520s"]
                ),
            ]
        )
        try meta.write(to: dir)

        let decoded = try JSONDecoder().decode(
            SessionMeta.self,
            from: Data(contentsOf: dir.appendingPathComponent("meta.json"))
        )
        XCTAssertEqual(decoded, meta)

        let (inputs, status) = try SessionMeta.readInputs(from: dir)
        XCTAssertEqual(status, .recovered)
        XCTAssertEqual(
            inputs,
            [
                SessionMeta.TrackInput(file: "mic.aac", speaker: "me", offsetMs: 18),
                SessionMeta.TrackInput(file: "mic-002.aac", speaker: "me", offsetMs: 1_691_120),
                SessionMeta.TrackInput(file: "system.aac", speaker: "them", offsetMs: 0),
            ])
    }

    func testUnreadableMetaThrows() throws {
        try write("not json")
        XCTAssertThrowsError(try SessionMeta.readInputs(from: dir))
    }

    /// A crash leaves the segment being written unclosed. Its file must
    /// still read back, or a crashed meeting has nothing to recover.
    func testASegmentFileReadsBackBeforeItIsClosed() throws {
        let url = dir.appendingPathComponent(TrackKind.mic.segmentFile(index: 1))
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let writer = try AVAudioFile(
            forWriting: url,
            settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        for i in 0..<4800 { buffer.floatChannelData![0][i] = sin(Float(i) * 0.06) * 0.3 }
        for _ in 0..<20 { try writer.write(from: buffer) }  // 2 s

        try withExtendedLifetime(writer) {
            let reader = try AVAudioFile(forReading: url)
            XCTAssertGreaterThan(Double(reader.length) / reader.fileFormat.sampleRate, 1.5)
        }
    }

    func testSegmentFileNaming() {
        XCTAssertEqual(TrackKind.mic.segmentFile(index: 1), "mic.aac")
        XCTAssertEqual(TrackKind.mic.segmentFile(index: 2), "mic-002.aac")
        XCTAssertEqual(TrackKind.system.segmentFile(index: 3), "system-003.aac")
    }
}
