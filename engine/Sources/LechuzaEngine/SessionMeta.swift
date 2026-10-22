import AVFoundation
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

    static let fileName = "meta.json"
    /// Written while recording and replaced by meta.json on stop. A crash
    /// leaves it behind, listing every segment that started writing.
    static let manifestFile = "recording.json"

    /// Write meta.json (or the manifest) atomically so the app, which treats
    /// the file's presence as "session finished", never reads a partial
    /// document.
    func write(to dir: URL, as file: String = fileName) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent(file), options: .atomic)
    }

    /// Turn the manifest a crashed recording left behind into meta.json, so
    /// it can be mixed and transcribed. Each segment's length comes from its
    /// file; a segment that can't be read is left out. The session is marked
    /// incomplete. Does nothing when meta.json exists or there's no manifest.
    static func recoverIfCrashed(_ dir: URL) throws {
        let manifestURL = dir.appendingPathComponent(manifestFile)
        guard
            !FileManager.default.fileExists(atPath: dir.appendingPathComponent(fileName).path),
            let data = try? Data(contentsOf: manifestURL)
        else { return }
        var meta = try JSONDecoder().decode(SessionMeta.self, from: data)
        for t in meta.tracks.indices {
            meta.tracks[t].status = .incomplete
            meta.tracks[t].segments = meta.tracks[t].segments.compactMap { segment in
                guard
                    let audio = try? AVAudioFile(forReading: dir.appendingPathComponent(segment.file)),
                    audio.length > 0
                else { return nil }
                let rate = audio.fileFormat.sampleRate
                var read = segment
                read.end_offset_ms = segment.start_offset_ms + Int(Double(audio.length) * 1000 / rate)
                read.frames_written = audio.length
                read.sample_rate_hz = Int(rate)
                read.channels = Int(audio.fileFormat.channelCount)
                return read
            }
        }
        let endMs = meta.tracks.flatMap(\.segments).map(\.end_offset_ms).max() ?? 0
        let iso = ISO8601DateFormatter()
        meta.duration_seconds = endMs / 1000
        meta.ended = iso.date(from: meta.started).map { iso.string(from: $0 + Double(endMs) / 1000) } ?? meta.started
        meta.status = .incomplete
        try meta.write(to: dir)
        try? FileManager.default.removeItem(at: manifestURL)
    }

    /// Parse a session's meta.json into ordered transcription inputs plus the
    /// session capture status.
    static func readInputs(from dir: URL) throws -> (inputs: [TrackInput], captureStatus: TrackStatus) {
        let url = dir.appendingPathComponent(fileName)
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
