import AVFoundation
import Synchronization

/// The microphone for one dictation: DictationCapture in the app, a fake in tests.
protocol DictationMicrophone: AnyObject, Sendable {
    /// Starts listening. `onLevel` gets each buffer's RMS (0–1) on the audio
    /// thread; `onLost` fires if macOS stops the capture first.
    func start(onLevel: @escaping @Sendable (Float) -> Void, onLost: @escaping @Sendable () -> Void) throws
    /// Stops and returns what was heard.
    func stop() -> DictationCapture.Recording
}

/// The microphone for one dictation, kept in memory and mixed down to mono.
/// It has its own AVAudioEngine on the default input, so a meeting's
/// MicRecorder keeps writing its track while you dictate. Started and
/// stopped on the main actor; the audio thread only touches the mutexes.
final class DictationCapture: DictationMicrophone, @unchecked Sendable {
    struct Recording: Sendable {
        let samples: [Float]
        let sampleRate: Double
    }

    enum CaptureError: Error, CustomStringConvertible {
        case notAllowed
        case noMicrophone

        var description: String {
            switch self {
            case .notAllowed:
                "Lechuza can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone."
            case .noMicrophone: "Lechuza can't find a microphone."
            }
        }
    }

    private let engine = AVAudioEngine()
    private let samples = Mutex<[Float]>([])
    private let sampleRate = Mutex<Double>(0)
    private var configObserver: NSObjectProtocol?

    func start(onLevel: @escaping @Sendable (Float) -> Void, onLost: @escaping @Sendable () -> Void) throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status != .denied, status != .restricted else { throw CaptureError.notAllowed }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noMicrophone }
        sampleRate.withLock { $0 = format.sampleRate }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [self] buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let count = Int(buffer.format.channelCount)
            var mono = [Float](repeating: 0, count: frames)
            for channel in 0..<count {
                for frame in 0..<frames { mono[frame] += channels[channel][frame] / Float(count) }
            }
            samples.withLock { $0.append(contentsOf: mono) }
            onLevel((mono.reduce(0) { $0 + $1 * $1 } / Float(max(frames, 1))).squareRoot())
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        // A microphone change with another format stops the engine without a word.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            if self?.engine.isRunning == false { onLost() }
        }
    }

    func stop() -> Recording {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        return Recording(samples: samples.withLock { $0 }, sampleRate: sampleRate.withLock { $0 })
    }
}
