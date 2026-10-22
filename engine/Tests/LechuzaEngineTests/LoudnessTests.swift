import Foundation
import XCTest

@testable import LechuzaEngine

/// Whispers are boosted to speaking level before transcription; speech at a
/// normal level passes unchanged.
final class LoudnessTests: XCTestCase {
    private func tone(_ amplitude: Float, seconds: Double = 1) -> [Float] {
        (0..<Int(16_000 * seconds)).map { amplitude * sin(Float($0) * 2 * .pi * 220 / 16_000) }
    }

    private func rms(_ samples: [Float]) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    func testAWhisperIsBoostedToSpeakingLevel() {
        let boosted = Loudness.normalized(tone(0.01))
        XCTAssertEqual(rms(boosted), Loudness.target, accuracy: 0.005)
    }

    func testSpeechAtANormalLevelPassesUnchanged() {
        let loud = tone(0.3)
        XCTAssertEqual(Loudness.normalized(loud), loud)
    }

    func testAShortLoudClickDoesNotHoldTheWhisperDown() {
        // A start sound or a knock in the first tenth of a second.
        let samples = tone(0.9, seconds: 0.05) + tone(0.01, seconds: 2)
        let boosted = Loudness.normalized(samples)
        XCTAssertEqual(rms(Array(boosted.suffix(16_000))), Loudness.target, accuracy: 0.005)
        XCTAssertLessThanOrEqual(boosted.map(abs).max() ?? 0, 1)
    }

    func testSilenceGetsAtMostTheLargestBoost() {
        let hiss = tone(0.0001)
        XCTAssertEqual(rms(Loudness.normalized(hiss)), rms(hiss) * Loudness.maxGain, accuracy: 0.0001)
        XCTAssertEqual(Loudness.normalized([Float](repeating: 0, count: 8_000)), [Float](repeating: 0, count: 8_000))
        XCTAssertEqual(Loudness.normalized([]), [])
    }
}
