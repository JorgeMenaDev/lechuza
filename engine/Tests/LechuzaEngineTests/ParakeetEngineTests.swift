import AVFoundation
import XCTest

@testable import LechuzaEngine

final class ParakeetEngineTests: XCTestCase {
    /// A track restarted just before Stop can leave a clip too short for the
    /// model. It holds no speech, so it must not fail the whole meeting.
    func testAClipTooShortForTheModelHasNoSpeech() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lechuza-short-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600  // 0.1 s of silence
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)

        let segments = try await ParakeetEngine().transcribe(url)

        XCTAssertEqual(segments, [])
    }

    /// A short clip that doesn't decode is broken, not silent: it must fail,
    /// or Retry would clear the meeting's earlier failure.
    func testAShortClipThatDoesNotDecodeFails() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lechuza-corrupt-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = 4_800  // 0.1 s
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buffer)
        }
        // Scramble the audio packets but keep the header, which still reports 0.1 s.
        var bytes = try Data(contentsOf: url)
        let data = try XCTUnwrap(bytes.range(of: Data("data".utf8)))
        for index in (data.upperBound + 16)..<bytes.count { bytes[index] = 0xFF }
        try bytes.write(to: url)

        do {
            _ = try await ParakeetEngine().transcribe(url)
            XCTFail("a clip that doesn't decode must not count as silence")
        } catch {}
    }
}

