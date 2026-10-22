import AVFoundation
import XCTest

@testable import LechuzaEngine

/// The mix must end, one way or the other: Stop waits on it before the app
/// leaves Saving.
final class MixerTests: XCTestCase {
    func testWaitingOnAStoppedWriterThrowsInsteadOfHanging() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lechuza-mix-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        // A failed writer (a full disk) behaves the same: its input never becomes ready again.
        writer.cancelWriting()

        let threw = expectation(description: "waiting threw")
        Task {
            do {
                try await Mixer.waitForInput(input, of: writer)
            } catch {
                threw.fulfill()
            }
        }
        await fulfillment(of: [threw], timeout: 2)
    }
}
