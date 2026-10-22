import AVFoundation
import Synchronization

/// The microphone for one dictation, kept in memory and mixed down to mono.
/// It has its own AVAudioEngine on the default input, so a meeting's
/// MicRecorder keeps writing its track while you dictate. Started and
/// stopped on the main actor; the audio thread only touches the mutexes.
final class DictationCapture: @unchecked Sendable {
    struct Recording {
        let samples: [Float]
        let sampleRate: Double
    }

    enum CaptureError: Error, CustomStringConvertible {
        case noMicrophone

        var description: String { "Lechuza can't find a microphone." }
    }

    private let engine = AVAudioEngine()
    private let samples = Mutex<[Float]>([])
    private let sampleRate = Mutex<Double>(0)

    /// Starts capturing. `onLevel` gets each buffer's RMS (0–1) on the audio thread.
    func start(onLevel: @escaping @Sendable (Float) -> Void) throws {
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
    }

    /// Stops and returns what was heard.
    func stop() -> Recording {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        return Recording(samples: samples.withLock { $0 }, sampleRate: sampleRate.withLock { $0 })
    }
}
