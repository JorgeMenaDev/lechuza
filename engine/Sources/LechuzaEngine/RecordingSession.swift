import Foundation

/// One meeting recording: a timestamped folder holding two independent tracks
/// (mic = you, system = them) plus a meta.json written on clean stop. Tracks
/// are separate on purpose — speech models do better on clean single-source audio,
/// and two tracks give free two-party diarization.
///
/// The session owns lifecycle policy: each track has a health state
/// machine fed by recorder events and a one-second watchdog. A stalled track
/// is restarted into a new numbered segment on the current audio route; prior
/// segments are never reopened or modified. All offsets share one monotonic
/// session clock, and the final metadata says whether each track ran
/// `complete`, `recovered`, or `incomplete` — a recovered session is usable
/// but never represented as uninterrupted.
@MainActor
final class RecordingSession {
    /// What stop() hands back so the app can warn before transcription.
    struct StopResult {
        let dir: URL
        let status: TrackStatus
    }

    let dir: URL
    let startedAt = Date()

    /// Fired once per degradation episode — never once per watchdog tick.
    var onDegraded: ((TrackKind) -> Void)?

    /// Per-track lifecycle: the recorder, its health machine, and the
    /// segments recorded so far. Reference type so tick can mutate in place.
    private final class TrackState {
        let recorder: any TrackRecorder
        var machine: TrackHealthMachine?
        var segments: [SessionMeta.Segment] = []
        var segmentIndex = 1
        var pendingRestart: (dueMs: Int, attempt: Int)?
        var lastBufferEndMs: Int?
        /// Its teardown timed out, so its control queue is blocked: never
        /// start or stop it again.
        var wedged = false

        init(recorder: any TrackRecorder) {
            self.recorder = recorder
        }
    }

    private let clock = SessionClock.started()
    private let policy: CapturePolicy
    private let nowMs: () -> Int
    private let tracks: [TrackState]
    private var watchdog: Task<Void, Never>?
    private var live = false

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (yyyy-MM-dd-HHmm, suffixed on
    /// collision) without starting capture yet. Recorders, policy, and the
    /// time source are injectable so orchestration tests can run with fakes,
    /// short thresholds, and a manual clock.
    init(
        root: URL,
        recorders: [any TrackRecorder]? = nil,
        policy: CapturePolicy = .production,
        nowMs: (() -> Int)? = nil
    ) throws {
        let base = Self.folderFormat.string(from: startedAt)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        dir = candidate

        self.policy = policy
        // System first: its TCC prompt and tap construction are the likelier
        // startup failures, and the mic is cheaper to roll back.
        self.tracks = (recorders ?? [SystemAudioRecorder(), MicRecorder()]).map(TrackState.init)
        let clock = self.clock
        self.nowMs = nowMs ?? { clock.nowMs() }
    }

    /// Start all tracks with the all-or-nothing rule: a startup failure tears
    /// down whatever already started so we never run half a session silently.
    /// Once live, one track's failure no longer stops the other — it enters
    /// recovery independently. The watchdog starts after all recorders are up.
    func start() throws {
        var started: [TrackState] = []
        for track in tracks {
            do {
                try startSegment(track)
                started.append(track)
            } catch {
                for rollback in started {
                    _ = rollback.recorder.stop()
                }
                throw error
            }
        }
        live = true
        startWatchdog()
    }

    /// Stop every track, derive final statuses, and atomically write typed v2
    /// metadata. Watchdog and pending retries are invalidated first so a
    /// delayed retry can never start a recorder after the session ends.
    func stop() -> StopResult {
        guard live else { return StopResult(dir: dir, status: .incomplete) }
        live = false
        watchdog?.cancel()
        watchdog = nil

        let stopMs = nowMs()
        var trackMetas: [SessionMeta.Track] = []
        var worst = TrackStatus.complete
        for track in tracks {
            track.pendingRestart = nil
            track.machine?.stopped()
            let finalTelemetry = track.recorder.telemetry()
            if !track.wedged { record(track.recorder.stop(), into: track) }
            let status =
                track.machine?.finalize(
                    stopMs: stopMs,
                    telemetry: finalTelemetry,
                    sessionLastBufferEndMs: track.lastBufferEndMs
                ) ?? .incomplete
            if status.severity > worst.severity { worst = status }
            trackMetas.append(
                SessionMeta.Track(
                    kind: track.recorder.kind,
                    speaker: track.recorder.kind.speaker,
                    status: status,
                    segments: track.segments,
                    interruptions: track.machine?.interruptions ?? [],
                    warnings: track.machine?.warnings ?? []
                ))
        }
        trackMetas.sort { $0.kind == .mic && $1.kind != .mic }

        let ended = Date()
        let iso = ISO8601DateFormatter()
        let meta = SessionMeta(
            schema_version: 2,
            started: iso.string(from: startedAt),
            ended: iso.string(from: ended),
            duration_seconds: Int(ended.timeIntervalSince(startedAt)),
            status: worst,
            tracks: trackMetas
        )
        do {
            try meta.write(to: dir)
        } catch {
            FileHandle.standardError.write(Data("meta.json write failed: \(error)\n".utf8))
        }
        return StopResult(dir: dir, status: worst)
    }

    /// One watchdog pass. Internal so orchestration tests can drive time
    /// manually; the production timer calls this once per second.
    func tick() {
        guard live else { return }
        let now = nowMs()
        for track in tracks {
            if let pending = track.pendingRestart, now >= pending.dueMs {
                track.pendingRestart = nil
                performRestart(track)
            }
            guard track.machine != nil else { continue }
            if let command = track.machine!.tick(nowMs: now, telemetry: track.recorder.telemetry()) {
                execute(command, on: track)
            }
        }
    }

    /// The latest buffer peak (0–1) of each track, for live level meters.
    func levels() -> (mic: Float, system: Float) {
        (
            trackState(for: .mic)?.recorder.telemetry().peak ?? 0,
            trackState(for: .system)?.recorder.telemetry().peak ?? 0
        )
    }

    // MARK: -

    private func startWatchdog() {
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    /// Start the track's next numbered segment and (on first start) its
    /// health machine.
    private func startSegment(_ track: TrackState) throws {
        let kind = track.recorder.kind
        let name = kind.segmentFile(index: track.segmentIndex)
        let url = dir.appendingPathComponent(name)
        try track.recorder.start(url: url, clock: clock) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event, on: kind)
            }
        }
        if track.machine == nil {
            track.machine = TrackHealthMachine(kind: kind, policy: policy, startMs: nowMs())
        }
    }

    private func trackState(for kind: TrackKind) -> TrackState? {
        tracks.first { $0.recorder.kind == kind }
    }

    private func handle(_ event: RecorderEvent, on kind: TrackKind) {
        guard live, let track = trackState(for: kind), track.machine != nil else { return }
        switch event {
        case .routeChanged:
            track.machine!.routeEvent(atMs: nowMs())
        case .transportStopped, .writeFailed:
            track.machine!.fault(atMs: nowMs())
        }
    }

    private func execute(_ command: TrackHealthMachine.Command, on track: TrackState) {
        switch command {
        case .restart(_, let delayMs):
            if delayMs <= 0 {
                performRestart(track)
            } else {
                track.pendingRestart = (dueMs: nowMs() + delayMs, attempt: 0)
            }
        case .declareDegraded:
            FileHandle.standardError.write(
                Data(
                    "\(track.recorder.kind.label) capture lost — recovery exhausted\n".utf8
                ))
            onDegraded?(track.recorder.kind)
        }
    }

    /// One serialized recovery step: close the current segment (preserving
    /// whatever it captured), then rebuild the recorder on the current route
    /// into the next numbered file. A teardown that times out degrades the
    /// track instead: starting it again would block the main actor on the
    /// same stuck queue, and with it Stop and shutdown.
    private func performRestart(_ track: TrackState) {
        guard live else { return }
        let stop = track.recorder.stop()
        record(stop, into: track)
        if case .timedOut = stop {
            track.wedged = true
            if let command = track.machine?.abandon(error: "\(track.recorder.kind.label) teardown timed out") {
                execute(command, on: track)
            }
            return
        }
        track.segmentIndex += 1
        let now = nowMs()
        do {
            try startSegment(track)
            track.machine?.restartSucceeded(atMs: now)
        } catch {
            if let command = track.machine?.restartFailed(atMs: nowMs(), error: "\(error)") {
                execute(command, on: track)
            }
        }
    }

    /// Append a finished segment to the track's metadata record. A segment
    /// that never wrote a buffer stays on disk but earns no metadata entry —
    /// there is nothing to transcribe or align.
    private func record(_ stop: SegmentStop, into track: TrackState) {
        guard let stats = stop.stats else { return }
        if let end = stats.lastBufferEndMs {
            track.lastBufferEndMs = max(track.lastBufferEndMs ?? 0, end)
        }
        guard let first = stats.firstWriteMs, stats.framesWritten > 0 else { return }
        track.segments.append(
            SessionMeta.Segment(
                file: stats.file,
                start_offset_ms: first,
                end_offset_ms: stats.lastBufferEndMs ?? first,
                frames_written: stats.framesWritten,
                sample_rate_hz: stats.sampleRateHz,
                channels: stats.channels
            ))
    }
}
