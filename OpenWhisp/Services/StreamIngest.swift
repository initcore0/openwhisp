import Foundation

// MARK: - Stream audio ingest (EXPERIMENT — remote mic → this Mac)

/// The pure protocol + audio-conversion layer for the experimental remote-audio
/// ingest: a client on ANOTHER machine (browser page, Windows companion, OBS
/// plugin — anything that can open a WebSocket) streams its mic as PCM to the
/// Mac, which transcribes locally. This file is Foundation-only and engine-free:
/// it defines the wire hello, validates it, and converts incoming PCM bytes to
/// the canonical mono Float32 @ 16 kHz every transcription seam consumes. The
/// WebSocket transport lives in StreamAudioIngestServer (app/SwiftPM target).

/// The first (text) WebSocket message a client sends: what audio is coming and
/// who is sending it. Everything after a valid hello is binary PCM frames.
public struct StreamIngestHello: Codable, Equatable, Sendable {
    /// PCM sample encoding of the binary frames.
    public enum Format: String, Codable, Sendable {
        /// 32-bit little-endian IEEE float samples.
        case pcmF32LE = "pcm_f32le"
        /// 16-bit little-endian signed integer samples.
        case pcmS16LE = "pcm_s16le"
    }

    public var format: Format
    /// Source sample rate in Hz (converted to 16 kHz server-side).
    public var sampleRate: Int
    /// Interleaved channel count (downmixed to mono server-side).
    public var channels: Int
    /// Human-readable client name for the UI ("OBS on gaming PC").
    public var clientName: String
    /// Shared-secret auth. Required whenever the server listens beyond loopback.
    public var token: String

    public init(format: Format, sampleRate: Int, channels: Int, clientName: String, token: String = "") {
        self.format = format
        self.sampleRate = sampleRate
        self.channels = channels
        self.clientName = clientName
        self.token = token
    }
}

/// Validation + auth decision for a received hello. Pure, so the accept/reject
/// rules are unit-tested rather than living inside the socket callbacks.
public enum StreamIngestHandshake {
    public enum Verdict: Equatable, Sendable {
        case accepted
        /// Closed with a reason the client can show ("unsupported sampleRate").
        case rejected(reason: String)
    }

    /// Sample-rate band worth supporting: everything real capture hardware emits.
    public static let sampleRateRange = 8_000...192_000

    /// Decide whether a hello may start streaming. `requiredToken` is empty when
    /// the server is loopback-only (no auth needed on the same machine).
    public static func evaluate(_ hello: StreamIngestHello, requiredToken: String) -> Verdict {
        if !requiredToken.isEmpty, !constantTimeEquals(hello.token, requiredToken) {
            return .rejected(reason: "invalid token")
        }
        guard sampleRateRange.contains(hello.sampleRate) else {
            return .rejected(reason: "unsupported sampleRate \(hello.sampleRate) (want \(sampleRateRange.lowerBound)–\(sampleRateRange.upperBound))")
        }
        guard (1...2).contains(hello.channels) else {
            return .rejected(reason: "unsupported channels \(hello.channels) (want 1–2)")
        }
        return .accepted
    }

    /// Length-safe comparison that doesn't short-circuit on the first mismatch,
    /// so a remote token guess can't be timed byte-by-byte.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }
}

/// Converts a client's interleaved PCM byte stream to the canonical mono
/// Float32 @ 16 kHz the transcription seams consume. Stateful: the fractional
/// resample position and any half-received sample carry across chunk
/// boundaries, so arbitrary network fragmentation never drops or skews audio.
///
/// Linear-interpolation resampling — deliberately simple for the experiment;
/// caption-grade ASR doesn't need a polyphase filter, and being pure Swift
/// keeps it in core and tested.
public struct StreamIngestAudioConverter: Sendable {
    public static let targetSampleRate = 16_000

    private let format: StreamIngestHello.Format
    private let channels: Int
    private let ratio: Double  // source samples per output sample

    /// Bytes that didn't complete a full interleaved frame in the last chunk.
    private var pendingBytes = Data()
    /// Mono source samples not yet consumed by the resampler (the resampler may
    /// need up to 2 trailing samples for interpolation across chunks).
    private var carry: [Float] = []
    /// Fractional read position into the carried+new source samples.
    private var position: Double = 0

    public init(hello: StreamIngestHello) {
        self.format = hello.format
        self.channels = hello.channels
        self.ratio = Double(hello.sampleRate) / Double(Self.targetSampleRate)
    }

    private var bytesPerSample: Int { format == .pcmF32LE ? 4 : 2 }
    private var bytesPerFrame: Int { bytesPerSample * channels }

    /// Feed one binary chunk; returns the mono 16 kHz samples it completes.
    public mutating func consume(_ chunk: Data) -> [Float] {
        pendingBytes.append(chunk)
        let frameCount = pendingBytes.count / bytesPerFrame
        guard frameCount > 0 else { return [] }
        let consumed = frameCount * bytesPerFrame

        // Decode + downmix to mono.
        var mono = [Float](repeating: 0, count: frameCount)
        pendingBytes.prefix(consumed).withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for frame in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channels {
                    let offset = (frame * channels + ch) * bytesPerSample
                    switch format {
                    case .pcmF32LE:
                        sum += Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                    case .pcmS16LE:
                        let s = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))
                        sum += Float(s) / 32_768
                    }
                }
                mono[frame] = sum / Float(channels)
            }
        }
        pendingBytes.removeFirst(consumed)

        // Resample carry+mono → 16 kHz via linear interpolation.
        let source = carry + mono
        var out: [Float] = []
        out.reserveCapacity(Int(Double(source.count) / ratio) + 1)
        while position + 1 < Double(source.count) {
            let i = Int(position)
            let frac = Float(position - Double(i))
            out.append(source[i] * (1 - frac) + source[i + 1] * frac)
            position += ratio
        }
        // Keep only the tail the next interpolation can still touch.
        let keepFrom = min(Int(position), source.count)
        carry = Array(source[keepFrom...])
        position -= Double(keepFrom)
        return out
    }
}
