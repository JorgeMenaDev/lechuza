import Foundation

/// Session metadata contract (Quill's schema v2): a typed
/// `tracks[].segments[]` representation that carries capture completeness,
/// interruptions, and per-segment session-clock offsets. Property names are
/// the JSON schema. The app adds an optional `title` when a meeting is
/// renamed; decoding ignores it.
struct SessionMeta: Codable, Equatable, Sendable {
    struct Segment: Codable, Equatable, Sendable {
        var file: String
        var start_offset_ms: Int
        var end_offset_ms: Int
        var frames_written: Int64
        var sample_rate_hz: Int
        var channels: Int
    }

    struct Track: Codable, Equatable, Sendable {
        var kind: TrackKind
        var speaker: String
        var status: TrackStatus
        var segments: [Segment]
        var interruptions: [Interruption]
        var warnings: [String]
    }

    var schema_version: Int
    var started: String
    var ended: String
    var duration_seconds: Int
    var status: TrackStatus
    var tracks: [Track]

    /// One transcription input: a segment file, who speaks on it, and where
    /// it starts on the session clock.
    struct TrackInput: Equatable, Sendable {
        var file: String
        var speaker: String
        var offsetMs: Int
    }

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "Can't read \(url.lastPathComponent); the recording may not have finished."
            }
        }
    }

    /// Write meta.json atomically so the app, which treats the file's
    /// presence as "session finished", never reads a partial document.
    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
    }

    /// Parse a session's meta.json into ordered transcription inputs plus the
    /// session capture status.
    static func readInputs(from dir: URL) throws -> (inputs: [TrackInput], captureStatus: TrackStatus) {
        let url = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let meta = try? JSONDecoder().decode(SessionMeta.self, from: data)
        else { throw MetaError.unreadable(url) }
        let inputs = meta.tracks.flatMap { track in
            track.segments.map {
                TrackInput(file: $0.file, speaker: track.speaker, offsetMs: $0.start_offset_ms)
            }
        }
        return (inputs, meta.status)
    }
}
