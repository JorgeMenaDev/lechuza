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
}
