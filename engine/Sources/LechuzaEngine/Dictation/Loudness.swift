import Foundation

/// Lechuza is for whispering in shared spaces. A whisper reaches the
/// microphone 20–30 dB below normal speech, too quiet for Parakeet to hear
/// well, so dictation audio is boosted to speaking level first. The level is
/// taken from the loud tenth of 20 ms frames (the speech), so silence
/// between words and a short click don't skew it. Speech that is already
/// loud enough passes unchanged.
enum Loudness {
    /// The RMS speech is brought up to: -20 dBFS.
    static let target: Float = 0.1
    /// At most +34 dB, so a silent room isn't turned into a roar.
    static let maxGain: Float = 50

    /// 16 kHz mono samples, boosted when they are quiet.
    static func normalized(_ samples: [Float]) -> [Float] {
        let frame = 320
        let levels = stride(from: 0, to: samples.count, by: frame).map { start in
            let slice = samples[start..<min(start + frame, samples.count)]
            return (slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)).squareRoot()
        }.sorted()
        guard !levels.isEmpty else { return samples }
        let speech = levels[levels.count * 9 / 10]
        let gain = speech > 0 ? min(max(target / speech, 1), maxGain) : maxGain
        guard gain > 1 else { return samples }
        return samples.map { min(max($0 * gain, -1), 1) }
    }
}
