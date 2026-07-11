import Foundation

// MARK: - MeetingWAVWriter (app-only, crash-safe progressive WAV)

/// Progressive 16 kHz mono 16-bit PCM WAV writer for Meeting mode capture.
///
/// Why not `AVAudioFile`? `AVAudioFile` only writes a valid RIFF header when it is
/// closed cleanly — a crash mid-meeting leaves a header that claims zero frames,
/// so the whole recording reads as empty. This writer instead:
///   1. writes a WAV header up front with a PLACEHOLDER size,
///   2. appends PCM sample frames progressively (each `append` is `fsync`-able),
///   3. on `finalize()` seeks back and patches the RIFF/`data` chunk sizes.
///
/// A crash loses at most the un-flushed tail: `recoverInPlace(url:)` can patch the
/// header of a leftover file from its on-disk byte length, salvaging everything
/// written before the crash. (Wired by the integration/crash-recovery pass; the
/// capture side always calls `finalize()` on a clean stop.)
final class MeetingWAVWriter {

    private let handle: FileHandle
    let url: URL
    private let sampleRate: Int
    /// PCM frames (mono samples) written so far.
    private(set) var framesWritten: Int = 0

    private static let headerSize = 44

    init(url: URL, sampleRate: Int = 16000) throws {
        self.url = url
        self.sampleRate = sampleRate
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(dataBytes: 0, sampleRate: sampleRate))
    }

    /// Append mono Float32 samples (range roughly [-1, 1]); converted to 16-bit
    /// little-endian PCM. Safe to call from a single serial queue.
    func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let v = Int16(clamped * 32767.0)
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        try handle.write(contentsOf: pcm)
        framesWritten += samples.count
    }

    /// Patch the header with the real sizes and close. Idempotent-ish: after this
    /// the file is a valid finalized WAV.
    func finalize() throws {
        let dataBytes = framesWritten * 2
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(dataBytes: dataBytes, sampleRate: sampleRate))
        try handle.close()
    }

    /// Best-effort: force buffered bytes to disk so a crash loses only the tail.
    func sync() { try? handle.synchronize() }

    var duration: TimeInterval { Double(framesWritten) / Double(sampleRate) }

    // MARK: Header

    private static func header(dataBytes: Int, sampleRate: Int) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let riffChunkSize = 36 + dataBytes

        var d = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8))
        u32(riffChunkSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        u32(16)                 // PCM fmt chunk size
        u16(1)                  // PCM format
        u16(channels)
        u32(sampleRate)
        u32(byteRate)
        u16(blockAlign)
        u16(bitsPerSample)
        d.append(contentsOf: Array("data".utf8))
        u32(dataBytes)
        return d
    }

    /// Salvage a crash-orphaned WAV: patch its header from the actual byte length.
    /// Returns true if the file looked like our placeholder WAV and was patched.
    @discardableResult
    static func recoverInPlace(url: URL, sampleRate: Int = 16000) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let total = attrs[.size] as? Int, total > headerSize else { return false }
        let dataBytes = total - headerSize
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: header(dataBytes: dataBytes, sampleRate: sampleRate))
            return true
        } catch { return false }
    }
}
