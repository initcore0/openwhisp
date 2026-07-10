import Foundation
import AVFoundation

/// Decodes an arbitrary audio/video container (MP3/MP4/M4A/WAV/WEBM/…) to the
/// canonical OpenWhisp on-disk format — **16 kHz mono 16-bit signed LE PCM WAV** —
/// via AVFoundation, and slices it into per-chunk WAVs for the batch queue
/// (MAK-36).
///
/// This is app-only (AVFoundation) so it stays out of `OpenWhispCore`. The chunk
/// *plan* (which windows) is decided by the Foundation-only `FileChunkPlanner`; this
/// type just realizes each window as a WAV the existing `FileTranscriptionEngine`
/// can consume — the same format `FileAudioCapture`/`AudioRecorder` emit, so the
/// engine path is unchanged.
enum MediaFileDecoder {

    enum DecodeError: Error, LocalizedError {
        case noAudioTrack
        case readFailed(String)
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "The file has no audio track to transcribe."
            case .readFailed(let m): return "Couldn't read the audio: \(m)"
            case .exportFailed(let m): return "Couldn't decode the audio: \(m)"
            }
        }
    }

    static let targetSampleRate = 16_000

    /// The decoded whole-file duration in seconds (fast, metadata-only where
    /// possible). Throws if there's no audio track.
    static func duration(of url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw DecodeError.noAudioTrack }
        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }

    /// Decode the entire file to a single 16 kHz mono 16-bit WAV at `outputURL`.
    static func decodeToWAV(source: URL, outputURL: URL) async throws {
        try await decodeRange(source: source, start: 0, end: nil, outputURL: outputURL)
    }

    /// Decode a `[start, end)` time window (seconds) to a 16 kHz mono 16-bit WAV.
    /// `end == nil` means to the end of the file. Used to realize one `FileChunkPlan`.
    static func decodeRange(source: URL, start: Double, end: Double?, outputURL: URL) async throws {
        let asset = AVURLAsset(url: source)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = audioTracks.first else { throw DecodeError.noAudioTrack }

        guard let reader = try? AVAssetReader(asset: asset) else {
            throw DecodeError.readFailed("could not open reader")
        }
        if start > 0 || end != nil {
            let startTime = CMTime(seconds: start, preferredTimescale: 44_100)
            let dur: CMTime
            if let end { dur = CMTime(seconds: max(0, end - start), preferredTimescale: 44_100) }
            else { dur = CMTime(seconds: 1_000_000, preferredTimescale: 44_100) }
            reader.timeRange = CMTimeRange(start: startTime, duration: dur)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw DecodeError.readFailed("cannot add output") }
        reader.add(output)

        guard reader.startReading() else {
            throw DecodeError.readFailed(reader.error?.localizedDescription ?? "start failed")
        }

        var samples: [Int16] = []
        while reader.status == .reading {
            guard let buffer = output.copyNextSampleBuffer() else { break }
            if let block = CMSampleBufferGetDataBuffer(buffer) {
                let length = CMBlockBufferGetDataLength(block)
                var data = Data(count: length)
                data.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
                }
                data.withUnsafeBytes { raw in
                    let ptr = raw.bindMemory(to: Int16.self)
                    samples.append(contentsOf: ptr)
                }
            }
            CMSampleBufferInvalidate(buffer)
        }

        if reader.status == .failed {
            throw DecodeError.exportFailed(reader.error?.localizedDescription ?? "read failed")
        }

        // Write out via the same tiny RIFF writer FileAudioCapture uses.
        try WAVFile.write(samples: samples, to: outputURL)
    }
}
