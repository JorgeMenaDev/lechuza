import Foundation

// The engine protocol: one JSON object per line on stdin (commands) and
// stdout (events), each with a "type". The TypeScript side of this contract is
// packages/contracts/src/engine.ts; packages/contracts/fixtures/engine-protocol.json
// holds one example of every message, and both sides' tests decode it.
// Types are grouped by feature (meeting.*, model.*, transcription.*), so
// dictation.* can join without touching the rest.

/// What the app asks the engine to do.
enum EngineCommand: Equatable, Sendable {
    /// Start recording a meeting into a new folder under `root`.
    case meetingStart(root: String)
    /// Stop the meeting, write meta.json and the mix.
    case meetingStop
    /// Transcribe a finished session folder (mixing it first if needed).
    case transcriptionStart(dir: String)
    /// Download the speech model if it is missing.
    case modelPrepare
}

/// What the engine tells the app.
enum EngineEvent: Equatable, Sendable {
    /// The engine is up. `modelDownloaded` says whether Parakeet is cached.
    case ready(modelDownloaded: Bool)
    case meetingStarted(dir: String, startedAt: String)
    /// Peak levels (0–1) of the microphone and system audio, ~10 times a second.
    case meetingLevel(mic: Double, system: Double)
    /// A track lost capture mid-meeting; recording goes on.
    case meetingWarning(message: String)
    /// meta.json and meeting.m4a are written; `status` is the capture status.
    case meetingStopped(dir: String, status: TrackStatus)
    /// A meeting could not start.
    case meetingFailed(message: String)
    case modelProgress(phase: ModelPhase, fraction: Double)
    case modelReady
    case modelFailed(message: String)
    case transcriptionStarted(dir: String)
    case transcriptionDone(dir: String)
    case transcriptionFailed(dir: String, message: String)
    /// A line the engine could not act on.
    case error(message: String)
}

enum ModelPhase: String, Codable, Sendable {
    case listing, downloading, compiling
}

extension EngineCommand: Codable {
    enum Kind: String, Codable, CaseIterable {
        case meetingStart = "meeting.start"
        case meetingStop = "meeting.stop"
        case transcriptionStart = "transcription.start"
        case modelPrepare = "model.prepare"
    }

    private enum Key: String, CodingKey {
        case type, root, dir
    }

    var kind: Kind {
        switch self {
        case .meetingStart: .meetingStart
        case .meetingStop: .meetingStop
        case .transcriptionStart: .transcriptionStart
        case .modelPrepare: .modelPrepare
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .meetingStart: self = .meetingStart(root: try c.decode(String.self, forKey: .root))
        case .meetingStop: self = .meetingStop
        case .transcriptionStart: self = .transcriptionStart(dir: try c.decode(String.self, forKey: .dir))
        case .modelPrepare: self = .modelPrepare
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(kind, forKey: .type)
        switch self {
        case .meetingStart(let root): try c.encode(root, forKey: .root)
        case .transcriptionStart(let dir): try c.encode(dir, forKey: .dir)
        case .meetingStop, .modelPrepare: break
        }
    }
}

extension EngineEvent: Codable {
    enum Kind: String, Codable, CaseIterable {
        case ready
        case meetingStarted = "meeting.started"
        case meetingLevel = "meeting.level"
        case meetingWarning = "meeting.warning"
        case meetingStopped = "meeting.stopped"
        case meetingFailed = "meeting.failed"
        case modelProgress = "model.progress"
        case modelReady = "model.ready"
        case modelFailed = "model.failed"
        case transcriptionStarted = "transcription.started"
        case transcriptionDone = "transcription.done"
        case transcriptionFailed = "transcription.failed"
        case error
    }

    private enum Key: String, CodingKey {
        case type, modelDownloaded, dir, startedAt, mic, system, status, message, phase, fraction
    }

    var kind: Kind {
        switch self {
        case .ready: .ready
        case .meetingStarted: .meetingStarted
        case .meetingLevel: .meetingLevel
        case .meetingWarning: .meetingWarning
        case .meetingStopped: .meetingStopped
        case .meetingFailed: .meetingFailed
        case .modelProgress: .modelProgress
        case .modelReady: .modelReady
        case .modelFailed: .modelFailed
        case .transcriptionStarted: .transcriptionStarted
        case .transcriptionDone: .transcriptionDone
        case .transcriptionFailed: .transcriptionFailed
        case .error: .error
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func string(_ key: Key) throws -> String { try c.decode(String.self, forKey: key) }
        switch try c.decode(Kind.self, forKey: .type) {
        case .ready: self = .ready(modelDownloaded: try c.decode(Bool.self, forKey: .modelDownloaded))
        case .meetingStarted: self = .meetingStarted(dir: try string(.dir), startedAt: try string(.startedAt))
        case .meetingLevel:
            self = .meetingLevel(
                mic: try c.decode(Double.self, forKey: .mic), system: try c.decode(Double.self, forKey: .system))
        case .meetingWarning: self = .meetingWarning(message: try string(.message))
        case .meetingStopped:
            self = .meetingStopped(dir: try string(.dir), status: try c.decode(TrackStatus.self, forKey: .status))
        case .meetingFailed: self = .meetingFailed(message: try string(.message))
        case .modelProgress:
            self = .modelProgress(
                phase: try c.decode(ModelPhase.self, forKey: .phase),
                fraction: try c.decode(Double.self, forKey: .fraction))
        case .modelReady: self = .modelReady
        case .modelFailed: self = .modelFailed(message: try string(.message))
        case .transcriptionStarted: self = .transcriptionStarted(dir: try string(.dir))
        case .transcriptionDone: self = .transcriptionDone(dir: try string(.dir))
        case .transcriptionFailed: self = .transcriptionFailed(dir: try string(.dir), message: try string(.message))
        case .error: self = .error(message: try string(.message))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(kind, forKey: .type)
        switch self {
        case .ready(let modelDownloaded):
            try c.encode(modelDownloaded, forKey: .modelDownloaded)
        case .meetingStarted(let dir, let startedAt):
            try c.encode(dir, forKey: .dir)
            try c.encode(startedAt, forKey: .startedAt)
        case .meetingLevel(let mic, let system):
            try c.encode(mic, forKey: .mic)
            try c.encode(system, forKey: .system)
        case .meetingStopped(let dir, let status):
            try c.encode(dir, forKey: .dir)
            try c.encode(status, forKey: .status)
        case .modelProgress(let phase, let fraction):
            try c.encode(phase, forKey: .phase)
            try c.encode(fraction, forKey: .fraction)
        case .transcriptionStarted(let dir), .transcriptionDone(let dir):
            try c.encode(dir, forKey: .dir)
        case .transcriptionFailed(let dir, let message):
            try c.encode(dir, forKey: .dir)
            try c.encode(message, forKey: .message)
        case .meetingWarning(let message), .meetingFailed(let message), .modelFailed(let message),
            .error(let message):
            try c.encode(message, forKey: .message)
        case .modelReady:
            break
        }
    }
}
