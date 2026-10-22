import XCTest

@testable import LechuzaEngine

/// A recorder the session can start, stop, and poll without audio devices.
/// Tests drive its telemetry by hand and can make starts fail on demand.
final class FakeRecorder: TrackRecorder, @unchecked Sendable {
    let kind: TrackKind
    var current = TelemetrySnapshot()
    var startedFiles: [String] = []
    var startAttempts = 0
    var failStarts = false
    /// Teardown wedges: stop times out and the recorder's queue stays
    /// blocked, so a real start would never return.
    var stopTimesOut = false
    var stopCalls = 0
    var startsWhileWedged = 0
    private var active = false
    private var wedged = false

    init(kind: TrackKind) {
        self.kind = kind
    }

    struct StartError: Error {}

    func start(url: URL, clock: SessionClock, onEvent: @escaping @Sendable (RecorderEvent) -> Void) throws {
        startAttempts += 1
        if wedged { startsWhileWedged += 1 }
        if failStarts { throw StartError() }
        active = true
        current = TelemetrySnapshot()
        startedFiles.append(url.lastPathComponent)
    }

    func stop() -> SegmentStop {
        stopCalls += 1
        guard active else { return .stopped(nil) }
        active = false
        let stats = SegmentStats(
            file: startedFiles.last ?? "?",
            firstWriteMs: current.firstWriteMs,
            lastBufferEndMs: current.lastBufferEndMs,
            framesWritten: current.framesWritten,
            sampleRateHz: 48000,
            channels: 1
        )
        if stopTimesOut {
            wedged = true
            return .timedOut(stats)
        }
        return .stopped(stats)
    }

    func telemetry() -> TelemetrySnapshot {
        current
    }

    /// Mark the fake as continuously writing from `first` through `last`.
    func writes(first: Int, last: Int) {
        current.firstWriteMs = first
        current.lastWriteMs = last
        current.lastBufferEndMs = last
        current.framesWritten = Int64(max(1, last - first)) * 48
    }
}

/// Recovery orchestration and stop-race tests with fake recorders and a
/// manual clock — no microphone, AirPods, TCC, or real-time sleeps.
@MainActor
final class RecordingSessionTests: XCTestCase {
    private final class TimeBox: @unchecked Sendable {
        var ms = 0
    }

    private var root: URL!
    private var time: TimeBox!
    private var mic: FakeRecorder!
    private var system: FakeRecorder!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lechuza-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        time = TimeBox()
        mic = FakeRecorder(kind: .mic)
        system = FakeRecorder(kind: .system)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSession() throws -> RecordingSession {
        let time = time!
        return try RecordingSession(
            root: root,
            recorders: [system, mic],
            policy: .production,
            nowMs: { time.ms }
        )
    }

    /// Advance the manual clock, refresh both fakes' "still writing" state
    /// unless a track is deliberately stalled, and run one watchdog pass.
    private func tick(_ session: RecordingSession, at ms: Int, micStalled: Bool = false) {
        time.ms = ms
        if !micStalled {
            mic.writes(first: mic.current.firstWriteMs ?? 500, last: ms - 100)
        }
        system.writes(first: system.current.firstWriteMs ?? 0, last: ms - 100)
        session.tick()
    }

    private func readMeta(_ session: RecordingSession) throws -> SessionMeta {
        try JSONDecoder().decode(
            SessionMeta.self,
            from: Data(contentsOf: session.dir.appendingPathComponent("meta.json"))
        )
    }

    func testUninterruptedSessionWritesCompleteV2Metadata() throws {
        let session = try makeSession()
        try session.start()
        tick(session, at: 1000)
        tick(session, at: 60000)

        time.ms = 61000
        let result = session.stop()
        XCTAssertEqual(result.status, .complete)

        let meta = try readMeta(session)
        XCTAssertEqual(meta.schema_version, 2)
        XCTAssertEqual(meta.status, .complete)
        XCTAssertEqual(meta.tracks.map(\.kind), [.mic, .system])
        XCTAssertEqual(meta.tracks[0].segments.map(\.file), ["mic.aac"])
        XCTAssertTrue(meta.tracks[0].interruptions.isEmpty)
    }

    func testKeepsAManifestOfItsSegmentsUntilItStops() throws {
        func manifestURL(_ session: RecordingSession) -> URL {
            session.dir.appendingPathComponent(SessionMeta.manifestFile)
        }
        func manifestFiles(_ session: RecordingSession) throws -> [String: [String]] {
            let manifest = try JSONDecoder().decode(SessionMeta.self, from: Data(contentsOf: manifestURL(session)))
            return Dictionary(uniqueKeysWithValues: manifest.tracks.map { ($0.kind.rawValue, $0.segments.map(\.file)) })
        }
        let session = try makeSession()
        try session.start()
        tick(session, at: 1000)
        XCTAssertEqual(try manifestFiles(session), ["mic": ["mic.aac"], "system": ["system.aac"]])

        // A restarted segment joins once it writes.
        mic.writes(first: 500, last: 1000)
        tick(session, at: 6000, micStalled: true)
        tick(session, at: 7000)
        XCTAssertEqual(try manifestFiles(session)["mic"], ["mic.aac", "mic-002.aac"])

        time.ms = 8000
        _ = session.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL(session).path))
        XCTAssertNoThrow(try readMeta(session))
    }

    func testStallRotatesOnceAndRecoversWithoutTouchingOtherTrack() throws {
        let session = try makeSession()
        try session.start()
        tick(session, at: 1000)

        // Mic stalls; system keeps writing. Detection rotates the mic once.
        mic.writes(first: 500, last: 1000)
        tick(session, at: 6000, micStalled: true)
        XCTAssertEqual(mic.startedFiles, ["mic.aac", "mic-002.aac"])
        XCTAssertEqual(system.startedFiles, ["system.aac"])

        // Replacement segment stabilizes; later stop is a recovered session.
        for ms in stride(from: 7000, through: 13000, by: 1000) {
            tick(session, at: ms)
        }
        time.ms = 14000
        mic.writes(first: mic.current.firstWriteMs ?? 6900, last: 13900)
        system.writes(first: 0, last: 13900)
        let result = session.stop()
        XCTAssertEqual(result.status, .recovered)

        let meta = try readMeta(session)
        let micTrack = meta.tracks.first { $0.kind == .mic }!
        XCTAssertEqual(micTrack.status, .recovered)
        XCTAssertEqual(micTrack.segments.map(\.file), ["mic.aac", "mic-002.aac"])
        XCTAssertEqual(micTrack.segments[0].end_offset_ms, 1000)
        XCTAssertEqual(micTrack.interruptions.count, 1)
        XCTAssertNotNil(micTrack.interruptions[0].recovered_offset_ms)
        let systemTrack = meta.tracks.first { $0.kind == .system }!
        XCTAssertEqual(systemTrack.status, .complete)
        XCTAssertEqual(systemTrack.segments.map(\.file), ["system.aac"])
    }

    func testExhaustedRetriesDegradeOnceAndFinalizeIncomplete() throws {
        var degradedTracks: [TrackKind] = []
        let session = try makeSession()
        session.onDegraded = { degradedTracks.append($0) }
        try session.start()
        tick(session, at: 1000)

        // Every restart fails: attempt 1 immediately, 2 after 500 ms, 3 after
        // 2 s more. Exactly one degraded notification.
        mic.failStarts = true
        mic.writes(first: 500, last: 1000)
        tick(session, at: 6000, micStalled: true)
        tick(session, at: 7000, micStalled: true)
        tick(session, at: 9500, micStalled: true)
        XCTAssertEqual(degradedTracks, [.mic])
        XCTAssertEqual(mic.startAttempts, 4)  // initial + 3 recovery attempts

        // Repeated watchdog ticks stay quiet.
        tick(session, at: 10500, micStalled: true)
        tick(session, at: 11500, micStalled: true)
        XCTAssertEqual(degradedTracks, [.mic])
        XCTAssertEqual(mic.startAttempts, 4)

        time.ms = 12000
        let result = session.stop()
        XCTAssertEqual(result.status, .incomplete)
        let meta = try readMeta(session)
        let micTrack = meta.tracks.first { $0.kind == .mic }!
        XCTAssertEqual(micTrack.status, .incomplete)
        XCTAssertEqual(micTrack.interruptions[0].attempts, 3)
        XCTAssertNil(micTrack.interruptions[0].recovered_offset_ms)
        // The healthy track still finishes complete.
        XCTAssertEqual(meta.tracks.first { $0.kind == .system }!.status, .complete)
    }

    func testStopDuringRetryDelayCreatesNoPostStopSegment() throws {
        let session = try makeSession()
        try session.start()
        tick(session, at: 1000)

        // Attempt 1 fails; attempt 2 is pending 500 ms out when stop lands.
        mic.failStarts = true
        mic.writes(first: 500, last: 1000)
        tick(session, at: 6000, micStalled: true)
        let attemptsAtStop = mic.startAttempts

        time.ms = 6200
        let result = session.stop()
        XCTAssertEqual(result.status, .incomplete)

        // The delayed retry firing after stop must not start a recorder.
        time.ms = 7000
        session.tick()
        XCTAssertEqual(mic.startAttempts, attemptsAtStop)

        // Metadata is still parseable and truthful.
        let meta = try readMeta(session)
        XCTAssertEqual(meta.tracks.first { $0.kind == .mic }!.segments.map(\.file), ["mic.aac"])
    }

    func testATeardownThatTimesOutDegradesTheTrackWithoutRestartingIt() throws {
        var degradedTracks: [TrackKind] = []
        let session = try makeSession()
        session.onDegraded = { degradedTracks.append($0) }
        try session.start()
        tick(session, at: 1000)

        // The mic stalls and its teardown wedges on the way to a restart.
        mic.stopTimesOut = true
        mic.writes(first: 500, last: 1000)
        tick(session, at: 6000, micStalled: true)
        tick(session, at: 7000, micStalled: true)
        XCTAssertEqual(mic.startsWhileWedged, 0)
        XCTAssertEqual(degradedTracks, [.mic])

        // Stop doesn't wait on the blocked queue again, and keeps what the
        // mic wrote before it wedged.
        time.ms = 8000
        let result = session.stop()
        XCTAssertEqual(mic.stopCalls, 1)
        XCTAssertEqual(result.status, .incomplete)
        let micTrack = try readMeta(session).tracks.first { $0.kind == .mic }!
        XCTAssertEqual(micTrack.status, .incomplete)
        XCTAssertEqual(micTrack.segments.map(\.file), ["mic.aac"])
    }

    func testStartupFailureRollsBackStartedTracks() throws {
        mic.failStarts = true
        let session = try makeSession()
        XCTAssertThrowsError(try session.start())
        // System started first and must be torn down again.
        XCTAssertEqual(system.startedFiles, ["system.aac"])
        XCTAssertNil(system.stop().stats)  // already stopped by rollback
    }
}
