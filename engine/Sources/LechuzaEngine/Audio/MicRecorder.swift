import AVFoundation
import CoreAudio
import Foundation

/// Records the default input device to a file via AVAudioEngine, encoding AAC
/// mono. Buffers stream straight to disk — nothing is held in memory, so
/// session length is unbounded. Capture is raw: no echo cancellation, so on
/// speakers the call's audio also reaches this track.
///
/// One start/stop pair is one segment. The recorder observes route and engine
/// configuration changes while a segment runs and reports them as health
/// events; the session owns the recovery decision. All graph
/// construction and teardown is serialized on a private control queue so the
/// main actor never blocks on Core Audio.
final class MicRecorder: TrackRecorder, @unchecked Sendable {
    enum RecorderError: Error, CustomStringConvertible {
        case alreadyRecording
        case engineStartFailed(Error)
        case fileCreationFailed(Error)
        case formatUnsupported(AVAudioFormat)

        var description: String {
            switch self {
            case .alreadyRecording: return "mic segment already active"
            case .engineStartFailed(let e): return "mic engine start failed: \(e)"
            case .fileCreationFailed(let e): return "mic file creation failed: \(e)"
            case .formatUnsupported(let f): return "can't downmix mic format \(f)"
            }
        }
    }

    let kind = TrackKind.mic

    private let control = DispatchQueue(label: "app.lechuza.engine.mic-control")
    private var engine: AVAudioEngine?
    private var segment: SegmentFile?
    private var configObserver: NSObjectProtocol?
    private var routeListener: AudioObjectPropertyListenerBlock?
    private var lastStats: SegmentStats?

    /// Start a new segment. Throws if one is already active.
    func start(url: URL, clock: SessionClock, onEvent: @escaping @Sendable (RecorderEvent) -> Void) throws {
        try control.sync {
            guard engine == nil else { throw RecorderError.alreadyRecording }
            try attach(url: url, clock: clock, onEvent: onEvent)
        }
    }

    /// Stop the active segment and return its stats. Bounded: if Core Audio
    /// teardown wedges, gives up after 5 s and reports stats from telemetry
    /// rather than hanging the caller.
    func stop() -> SegmentStop {
        let done = DispatchSemaphore(value: 0)
        control.async {
            self.lastStats = self.teardownLocked()
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            FileHandle.standardError.write(Data("mic teardown timed out\n".utf8))
            return .timedOut(segment?.stats())
        }
        return .stopped(lastStats)
    }

    func telemetry() -> TelemetrySnapshot {
        segment?.telemetry.snapshot() ?? TelemetrySnapshot()
    }

    // MARK: -

    /// Build the engine graph, create the AAC file, start capture, and attach
    /// route observers. Runs on the control queue.
    private func attach(
        url: URL,
        clock: SessionClock,
        onEvent: @escaping @Sendable (RecorderEvent) -> Void
    ) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        // Downmix to one channel at the device's rate; speech models want one
        // channel anyway, and a multichannel route format stays out of the file.
        guard
            let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputFormat.sampleRate,
                channels: 1,
                interleaved: false
            )
        else {
            throw RecorderError.formatUnsupported(inputFormat)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: monoFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: monoFormat.commonFormat,
                interleaved: monoFormat.isInterleaved
            )
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }
        let segment = SegmentFile(
            file: file,
            fileName: url.lastPathComponent,
            sampleRateHz: Int(monoFormat.sampleRate),
            channels: 1,
            clock: clock
        )

        try installTap(
            on: input, inputFormat: inputFormat, monoFormat: monoFormat,
            segment: segment, onEvent: onEvent
        )

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            _ = segment.finish()
            throw RecorderError.engineStartFailed(error)
        }

        self.engine = engine
        self.segment = segment
        observeRoute(engine: engine, onEvent: onEvent)

        let report =
            "mic: segment=\(url.lastPathComponent) "
            + "input=\(input.outputFormat(forBus: 0)) tap=\(monoFormat)\n"
        FileHandle.standardError.write(Data(report.utf8))
    }

    /// Watch for the engine's graph being reconfigured by a route change and
    /// for the system default input moving. Both mark the track suspect; the
    /// watchdog decides whether callbacks actually stopped. An engine that is
    /// no longer running after a configuration change is reported immediately.
    private func observeRoute(engine: AVAudioEngine, onEvent: @escaping @Sendable (RecorderEvent) -> Void) {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            onEvent(.routeChanged)
            guard let self else { return }
            self.control.async {
                if let engine = self.engine, !engine.isRunning {
                    onEvent(.transportStopped)
                }
            }
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            onEvent(.routeChanged)
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, control, listener
        )
        if status == noErr {
            routeListener = listener
        } else {
            FileHandle.standardError.write(
                Data(
                    "warning: default-input listener failed (OSStatus \(status))\n".utf8
                ))
        }
    }

    /// Idempotent, ordered teardown: stop engine, remove tap, detach
    /// observers, close file, release graph. Runs on the control queue.
    private func teardownLocked() -> SegmentStats? {
        guard let engine else { return nil }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if let routeListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, control, routeListener
            )
            self.routeListener = nil
        }
        let stats: SegmentStats?
        if let segment {
            _ = segment.finish()
            stats = segment.stats()
        } else {
            stats = nil
        }
        segment = nil
        self.engine = nil
        return stats
    }

    /// Tap at the device's native format and downmix to mono. Same sample
    /// rate on both sides, so the one-shot convert applies.
    private func installTap(
        on input: AVAudioInputNode,
        inputFormat: AVAudioFormat,
        monoFormat: AVAudioFormat,
        segment: SegmentFile,
        onEvent: @escaping @Sendable (RecorderEvent) -> Void
    ) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: monoFormat) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, when in
            guard
                let mono = AVAudioPCMBuffer(
                    pcmFormat: monoFormat,
                    frameCapacity: buffer.frameCapacity
                )
            else { return }
            do {
                try converter.convert(to: mono, from: buffer)
            } catch {
                onEvent(.writeFailed("mic downmix failed: \(error)"))
                return
            }
            let hostTime = when.isHostTimeValid ? when.hostTime : nil
            if let error = segment.write(mono, hostTime: hostTime) {
                onEvent(.writeFailed(error))
            }
        }
    }
}
