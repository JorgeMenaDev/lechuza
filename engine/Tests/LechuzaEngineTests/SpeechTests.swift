import AVFoundation
import XCTest

@testable import LechuzaEngine

/// End to end without a person: macOS `say` speaks English on the mic track
/// and Spanish on the system track, and the engine mixes and transcribes the
/// session with Parakeet v3. The first run downloads the model (~600 MB) into
/// FluidAudio's cache.
@MainActor
final class SpeechTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lechuza-speech-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Speak `text` with `voice` into an AAC CAF file, like a recorded track.
    private func speak(_ text: String, voice: String, into file: String) throws -> TimeInterval {
        let aiff = dir.appendingPathComponent("\(file).aiff")
        try run("/usr/bin/say", ["-v", voice, "-o", aiff.path, text])
        let caf = dir.appendingPathComponent(file)
        try run("/usr/bin/afconvert", ["-f", "caff", "-d", "aac", aiff.path, caf.path])
        try FileManager.default.removeItem(at: aiff)
        let audio = try AVAudioFile(forReading: caf)
        return Double(audio.length) / audio.fileFormat.sampleRate
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments)")
    }

    private func track(_ kind: TrackKind, file: String, offsetMs: Int, seconds: TimeInterval) -> SessionMeta.Track {
        SessionMeta.Track(
            kind: kind, speaker: kind.speaker, status: .complete,
            segments: [
                SessionMeta.Segment(
                    file: file, start_offset_ms: offsetMs, end_offset_ms: offsetMs + Int(seconds * 1000),
                    frames_written: 1, sample_rate_hz: 22050, channels: 1)
            ],
            interruptions: [], warnings: [])
    }

    func testTranscribesEnglishMeAndSpanishThem() async throws {
        let english = try speak(
            "The weather in London is cloudy today, so we will meet indoors.", voice: "Samantha", into: "mic.caf")
        let spanish = try speak(
            "Hoy tenemos una reunión importante con todo el equipo de ventas.", voice: "Paulina", into: "system.caf")
        let themOffsetMs = Int(english * 1000) + 1000
        try SessionMeta(
            schema_version: 2, started: "2026-10-22T14:05:09Z", ended: "2026-10-22T14:05:20Z",
            duration_seconds: 11, status: .complete,
            tracks: [
                track(.mic, file: "mic.caf", offsetMs: 0, seconds: english),
                track(.system, file: "system.caf", offsetMs: themOffsetMs, seconds: spanish),
            ]
        ).write(to: dir)

        let events = EventLog()
        let engine = Engine(emit: events.append)
        await engine.run(.transcriptionStart(dir: dir.path))

        XCTAssertEqual(events.all.first, .transcriptionStarted(dir: dir.path))
        XCTAssertEqual(events.all.last, .transcriptionDone(dir: dir.path))
        XCTAssertTrue(events.all.contains(.modelReady))

        let transcript = try JSONDecoder().decode(
            Transcript.self, from: Data(contentsOf: dir.appendingPathComponent("transcript.json")))
        let me = transcript.segments.filter { $0.speaker == "me" }.map(\.text).joined(separator: " ").lowercased()
        let them = transcript.segments.filter { $0.speaker == "them" }.map(\.text).joined(separator: " ")
            .lowercased()
        XCTAssertTrue(me.contains("weather") && me.contains("london"), me)
        XCTAssertTrue(them.contains("reunión") && them.contains("equipo"), them)
        XCTAssertEqual(transcript.segments.first?.speaker, "me")
        XCTAssertGreaterThanOrEqual(
            transcript.segments.first { $0.speaker == "them" }?.start_ms ?? 0, themOffsetMs)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.md").path))

        // The mix holds both tracks, the Spanish one at its offset.
        let mix = AVURLAsset(url: dir.appendingPathComponent(Mixer.fileName))
        let duration = try await mix.load(.duration).seconds
        XCTAssertEqual(duration, Double(themOffsetMs) / 1000 + spanish, accuracy: 0.5)
    }

    func testFailureLeavesItsReasonForTheApp() async throws {
        let events = EventLog()
        let engine = Engine(emit: events.append)
        await engine.run(.transcriptionStart(dir: dir.path))

        guard case .transcriptionFailed(let path, let message) = events.all.last else {
            return XCTFail("expected transcription.failed, got \(events.all)")
        }
        XCTAssertEqual(path, dir.path)
        let saved = try String(contentsOf: dir.appendingPathComponent(Transcriber.errorFile), encoding: .utf8)
        XCTAssertEqual(saved.trimmingCharacters(in: .whitespacesAndNewlines), message)
    }
}
