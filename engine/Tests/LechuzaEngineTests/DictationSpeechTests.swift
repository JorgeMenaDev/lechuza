import AVFoundation
import FluidAudio
import XCTest

@testable import LechuzaEngine

/// Dictation's path from audio to text, without a microphone: `say` speaks
/// into a file, which is turned down to a whisper's level, then normalised
/// and transcribed on a warm model the way a dictation is.
final class DictationSpeechTests: XCTestCase {
    private static let parakeet = ParakeetEngine()

    /// `text` spoken by `voice` as 16 kHz mono samples, scaled by `gain`.
    private func speak(_ text: String, voice: String, gain: Float) throws -> [Float] {
        let aiff = FileManager.default.temporaryDirectory.appendingPathComponent("lechuza-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: aiff) }
        let say = try Process.run(URL(fileURLWithPath: "/usr/bin/say"), arguments: ["-v", voice, "-o", aiff.path, text])
        say.waitUntilExit()
        return try AudioConverter().resampleAudioFile(aiff).map { $0 * gain }
    }

    private func transcribe(_ samples: [Float]) async throws -> String {
        try await Self.parakeet.prepare()
        return try await Self.parakeet.transcribe(samples: Loudness.normalized(samples)).lowercased()
    }

    func testAWhisperFromAcrossTheDeskIsTranscribed() async throws {
        // -50 dB: a whisper reaching a laptop microphone with the input
        // volume low. Without the boost, Parakeet hears nonsense here.
        let samples = try speak("Please send the report to Maria before lunch.", voice: "Whisper", gain: 0.003)
        let text = try await transcribe(samples)
        XCTAssertTrue(text.contains("report") && text.contains("lunch"), text)
    }

    func testAShortSentenceIsReadyWellWithinASecondOnAWarmModel() async throws {
        let samples = try speak("See you at three.", voice: "Samantha", gain: 1)
        _ = try await transcribe(samples)
        let start = ContinuousClock.now
        let text = try await transcribe(samples)
        XCTAssertTrue(text.contains("three") || text.contains("3"), text)
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(500))
    }
}
