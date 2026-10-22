import AVFoundation
import Foundation

/// Mixes a session's segment files into one compressed file for playback:
/// meeting.m4a, AAC mono at 48 kHz and 64 kbps (about 29 MB per hour). Each
/// segment lands at its session-clock offset, so the mix lines up with the
/// transcript timestamps. The moov atom goes first, so the app's player can
/// seek before the whole file has loaded.
enum Mixer {
    static let fileName = "meeting.m4a"

    enum MixError: Error, CustomStringConvertible {
        case noAudio
        case failed(String)

        var description: String {
            switch self {
            case .noAudio: return "No audio was recorded."
            case .failed(let reason): return "Mixing the tracks failed: \(reason)"
            }
        }
    }

    /// Write `dir/meeting.m4a` from `inputs`. Missing or unreadable segments
    /// are left out; with none left, throws `noAudio`. Writes through a temp
    /// file, so a crash never leaves a half-written mix behind.
    static func mix(_ inputs: [SessionMeta.TrackInput], in dir: URL) async throws {
        let composition = AVMutableComposition()
        for input in inputs {
            let asset = AVURLAsset(url: dir.appendingPathComponent(input.file))
            guard
                let source = try? await asset.loadTracks(withMediaType: .audio).first,
                let duration = try? await asset.load(.duration),
                let track = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try track.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: source,
                at: CMTime(value: Int64(input.offsetMs), timescale: 1000)
            )
        }
        let tracks = composition.tracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw MixError.noAudio }

        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        reader.add(output)

        let temp = dir.appendingPathComponent(".meeting.part.m4a")
        try? FileManager.default.removeItem(at: temp)
        let writer = try AVAssetWriter(outputURL: temp, fileType: .m4a)
        writer.shouldOptimizeForNetworkUse = true
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64000,
            ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)

        guard reader.startReading() else { throw MixError.failed("\(reader.error.map { "\($0)" } ?? "reader")") }
        guard writer.startWriting() else { throw MixError.failed("\(writer.error.map { "\($0)" } ?? "writer")") }
        writer.startSession(atSourceTime: .zero)
        // Offline, so polling for writer readiness costs nothing noticeable.
        while let buffer = output.copyNextSampleBuffer() {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard input.append(buffer) else { break }
        }
        input.markAsFinished()
        await writer.finishWriting()

        guard reader.status == .completed, writer.status == .completed else {
            try? FileManager.default.removeItem(at: temp)
            let error = writer.error ?? reader.error
            throw MixError.failed(error.map { "\($0)" } ?? "unknown error")
        }
        _ = try FileManager.default.replaceItemAt(dir.appendingPathComponent(fileName), withItemAt: temp)
    }
}
