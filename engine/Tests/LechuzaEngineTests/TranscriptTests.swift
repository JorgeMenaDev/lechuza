import FluidAudio
import XCTest

@testable import LechuzaEngine

/// Grouping words into lines, and merging each file's lines onto the
/// session clock with capture gaps left visible.
final class TranscriptTests: XCTestCase {
    private func words(_ spec: [(String, Double, Double)]) -> [WordTiming] {
        spec.map { WordTiming(word: $0.0, startTime: $0.1, endTime: $0.2) }
    }

    func testGroupsWordsIntoSentences() {
        let segments = ParakeetEngine.segments(
            from: words([
                ("Hello", 0.0, 0.4), ("there.", 0.5, 0.9), ("How", 1.0, 1.2), ("are", 1.3, 1.4), ("you?", 1.5, 1.8),
            ]))
        XCTAssertEqual(
            segments,
            [
                TranscriptSegment(start: 0.0, end: 0.9, text: "Hello there."),
                TranscriptSegment(start: 1.0, end: 1.8, text: "How are you?"),
            ])
    }

    func testBreaksOnSilenceLongerThanASecond() {
        let segments = ParakeetEngine.segments(
            from: words([("so", 0.0, 0.3), ("anyway", 0.4, 0.8), ("right", 2.0, 2.3)]))
        XCTAssertEqual(segments.map(\.text), ["so anyway", "right"])
    }

    func testWrapsARunOnSpeakerAtSixtyWords() {
        let run = (0..<61).map { ("word", Double($0) * 0.3, Double($0) * 0.3 + 0.2) }
        let segments = ParakeetEngine.segments(from: words(run))
        XCTAssertEqual(segments.map { $0.text.split(separator: " ").count }, [60, 1])
    }

    func testShiftedPreservesSegmentOffsets() {
        let raw = [
            TranscriptSegment(start: 0.5, end: 2.0, text: "hello"),
            TranscriptSegment(start: 3.0, end: 4.5, text: "world"),
        ]
        let shifted = Transcript.shifted(raw, speaker: "me", offsetMs: 1_691_120)
        XCTAssertEqual(
            shifted,
            [
                Transcript.Segment(speaker: "me", start_ms: 1_691_620, end_ms: 1_693_120, text: "hello"),
                Transcript.Segment(speaker: "me", start_ms: 1_694_120, end_ms: 1_695_620, text: "world"),
            ])
    }

    func testMergeInterleavesSegmentsAndRetainsGap() {
        // First mic segment ends at 10 s; the second starts at 25 s after a
        // 15 s capture gap. The system track spans the whole session.
        var merged: [Transcript.Segment] = []
        merged += Transcript.shifted(
            [TranscriptSegment(start: 1, end: 9, text: "before the gap")],
            speaker: "me", offsetMs: 0
        )
        merged += Transcript.shifted(
            [TranscriptSegment(start: 0, end: 5, text: "after the gap")],
            speaker: "me", offsetMs: 25000
        )
        merged += Transcript.shifted(
            [
                TranscriptSegment(start: 12, end: 14, text: "they talk"),
                TranscriptSegment(start: 31, end: 33, text: "they answer"),
            ],
            speaker: "them", offsetMs: 0
        )
        merged.sort { $0.start_ms < $1.start_ms }

        XCTAssertEqual(merged.map(\.text), ["before the gap", "they talk", "after the gap", "they answer"])
        XCTAssertEqual(merged[2].start_ms, 25000)
    }

    private func line(_ speaker: String, _ startMs: Int, _ endMs: Int, _ text: String) -> Transcript.Segment {
        Transcript.Segment(speaker: speaker, start_ms: startMs, end_ms: endMs, text: text)
    }

    /// Lines from a live test without headphones: the mic heard each `them`
    /// sentence through the speakers about 0.2 s later, one word misheard.
    func testDropsMeLinesThatRepeatThemAtTheSameTime() {
        let segments = [
            line("them", 3471, 6751, "The quarterly budget review moves to Thursday afternoon."),
            line("me", 3581, 6941, "The quarterly budget review moves to Thursday afternoon."),
            line("them", 6751, 9391, "Please send the slides to Maria before lunch."),
            line("me", 6941, 9581, "Please send us slides to Maria before lunch."),
        ]
        XCTAssertEqual(Transcript.removingEcho(from: segments), [segments[0], segments[2]])
    }

    /// The mic's transcript can break sentences differently from theirs.
    func testDropsAnEchoThatSpansTwoOfTheirLines() {
        let segments = [
            line("them", 0, 3000, "The budget review moves to Thursday."),
            line("them", 3000, 6000, "Please send the slides."),
            line("me", 1500, 6200, "Moves to Thursday please send the slides."),
        ]
        XCTAssertEqual(Transcript.removingEcho(from: segments), Array(segments[0..<2]))
    }

    func testKeepsWhatYouSayWhileTheyTalk() {
        let segments = [
            line("them", 3000, 9000, "The quarterly budget review moves to Thursday afternoon."),
            line("me", 4000, 6000, "Sorry, I can't make Thursday."),
        ]
        XCTAssertEqual(Transcript.removingEcho(from: segments), segments)
    }

    /// A short answer can repeat their word and still be yours, even with headphones.
    func testKeepsAShortReplyThatRepeatsTheirWord() {
        let segments = [
            line("them", 0, 3000, "Shall we move the review to Thursday?"),
            line("me", 2900, 3500, "Thursday."),
        ]
        XCTAssertEqual(Transcript.removingEcho(from: segments), segments)
    }

    func testKeepsTheirWordsWhenYouRepeatThemLater() {
        let segments = [
            line("them", 1000, 2500, "We meet on Thursday."),
            line("me", 4000, 5500, "We meet on Thursday."),
        ]
        XCTAssertEqual(Transcript.removingEcho(from: segments), segments)
    }

    func testRenderedMarkdownHasTimestampedSpeakersAndCaptureStatus() {
        let transcript = Transcript(
            engine: "parakeet", model: "test", created_at: "2026-10-22T14:05:09Z",
            segments: [
                Transcript.Segment(speaker: "me", start_ms: 5000, end_ms: 6000, text: "Hi."),
                Transcript.Segment(speaker: "them", start_ms: 3_725_000, end_ms: 3_726_000, text: "Hola."),
            ]
        )
        let complete = transcript.rendered(title: "2026-10-22-1405", captureStatus: .complete)
        XCTAssertTrue(complete.contains("**[0:05] me:** Hi."))
        XCTAssertTrue(complete.contains("**[1:02:05] them:** Hola."))
        XCTAssertFalse(complete.contains("capture:"))
        XCTAssertTrue(
            transcript.rendered(title: "t", captureStatus: .recovered).contains("capture: recovered"))
    }
}
