import Foundation

/// Canonical transcript, written as transcript.json. Property names are the
/// JSON schema the app reads.
struct Transcript: Codable, Equatable {
    struct Segment: Codable, Equatable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    let engine: String
    let model: String
    let created_at: String
    let segments: [Segment]

    /// Shift one audio file's transcript segments onto the session clock by
    /// the file's start offset. Segments are never collapsed against a
    /// previous file's end — a capture gap stays visible as a timestamp gap.
    static func shifted(
        _ segments: [TranscriptSegment], speaker: String, offsetMs: Int
    ) -> [Segment] {
        segments.map {
            Segment(
                speaker: speaker,
                start_ms: Int($0.start * 1000) + offsetMs,
                end_ms: Int($0.end * 1000) + offsetMs,
                text: $0.text
            )
        }
    }

    /// Write transcript.json and render transcript.md. Both writes are atomic
    /// (temp file + rename), so a partially written transcript never exists on
    /// disk — the app treats presence of transcript.json as "ready".
    /// A capture status other than complete stays visible in the readable
    /// header.
    func write(to dir: URL, captureStatus: TrackStatus) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
        try Data(rendered(title: dir.lastPathComponent, captureStatus: captureStatus).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
    }

    func rendered(title: String, captureStatus: TrackStatus) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))"]
        if captureStatus != .complete {
            lines.append("capture: \(captureStatus.rawValue)")
        }
        lines.append("")
        for seg in segments {
            lines.append("**[\(Self.clock(seg.start_ms))] \(seg.speaker):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
