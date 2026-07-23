import Foundation

/// Utterance chunker for the dual-runtime translate path (pure core, tested).
///
/// The dual path tees the live engine's mic frames here; this buffers them into
/// utterance-sized PCM chunks that a whisper-family translator can run one at a
/// time. It is deliberately pure — Float samples in, `[Float]` chunks out — so
/// the boundary behavior (silence splitting, min/max caps, no-sample-loss) is
/// `swift test`-able without any audio hardware.
///
/// Boundary rule, per utterance:
///   * accumulate samples while the speaker is talking,
///   * when energy drops below `silenceThreshold` for `silenceDuration`
///     CONTINUOUS seconds AND the buffer holds at least `minDuration` of audio,
///     emit the buffer as one chunk (the natural end of a sentence),
///   * force a flush at `maxDuration` even mid-speech, so a long monologue is
///     translated incrementally rather than after a wall-clock stall,
///   * `flush()` at session stop emits whatever remains (down to a tiny floor),
///     so the last words are never lost.
///
/// Energy is derived internally (RMS over each ingested block) so the caller need
/// only forward raw frames; there is no separate VAD input to keep in sync. Every
/// sample that enters `ingest` leaves in exactly one emitted chunk (or the final
/// `flush`) — the no-loss invariant the tests assert.
public struct TranslationChunker {

    /// Sample rate of the incoming frames (16 kHz mono, matching the engine tee
    /// and the whisper file path).
    public let sampleRate: Int
    /// Minimum audio in a chunk before a silence boundary may split it. Prevents
    /// a chunk-per-cough; a boundary during a shorter buffer is ignored (the
    /// samples stay for the next utterance).
    public let minDuration: Double
    /// Hard cap: flush at this much buffered audio even without a silence
    /// boundary, so a continuous talker is still translated in pieces.
    public let maxDuration: Double
    /// Continuous below-threshold time that ends an utterance.
    public let silenceDuration: Double
    /// RMS level below which a block counts as silence.
    public let silenceThreshold: Float

    private var buffer: [Float] = []
    /// Continuous silent samples currently accumulated at the tail of `buffer`.
    private var trailingSilenceSamples: Int = 0
    /// Whether any above-threshold audio has entered the CURRENT utterance —
    /// leading silence must not trip the boundary (there is nothing to end yet).
    private var sawSpeech = false

    public init(
        sampleRate: Int = 16_000,
        minDuration: Double = 0.8,
        maxDuration: Double = 8.0,
        silenceDuration: Double = 0.7,
        silenceThreshold: Float = 0.012
    ) {
        self.sampleRate = max(1, sampleRate)
        self.minDuration = max(0.1, minDuration)
        self.maxDuration = max(minDuration, maxDuration)
        self.silenceDuration = max(0.05, silenceDuration)
        self.silenceThreshold = max(0, silenceThreshold)
    }

    private var minSamples: Int { Int(minDuration * Double(sampleRate)) }
    private var maxSamples: Int { Int(maxDuration * Double(sampleRate)) }
    private var silenceSampleCount: Int { Int(silenceDuration * Double(sampleRate)) }
    /// A flush emits only if it holds at least this much audio — a sliver of
    /// noise at stop isn't worth a translation round trip.
    private var floorSamples: Int { max(1, sampleRate / 5) } // 0.2s

    /// Ingest a block of frames and return any chunk(s) whose boundary the block
    /// completed. Usually 0 or 1; a very large block could complete several
    /// max-duration chunks, so it returns an array.
    public mutating func ingest(_ samples: [Float]) -> [[Float]] {
        guard !samples.isEmpty else { return [] }
        var emitted: [[Float]] = []

        // Update trailing-silence bookkeeping for the block as a whole using its
        // RMS; a per-block granularity is plenty at ~1024-frame taps.
        let block = Self.rms(samples)
        buffer.append(contentsOf: samples)
        if block < silenceThreshold {
            trailingSilenceSamples += samples.count
        } else {
            sawSpeech = true
            trailingSilenceSamples = 0
        }

        // Silence boundary: enough speech buffered AND a long-enough quiet tail.
        if sawSpeech,
           buffer.count >= minSamples,
           trailingSilenceSamples >= silenceSampleCount {
            emitted.append(takeAll())
        }

        // Max-duration flush(es): even mid-speech, don't let a chunk grow past the
        // cap. Loop so a huge single block can't smuggle past the cap.
        while buffer.count >= maxSamples {
            emitted.append(take(maxSamples))
        }

        return emitted
    }

    /// Emit whatever is buffered (session stop). Returns nil when there's nothing
    /// worth translating (empty or below the tiny floor).
    public mutating func flush() -> [Float]? {
        guard buffer.count >= floorSamples else {
            reset()
            return nil
        }
        return takeAll()
    }

    /// Discard all state (session teardown). No chunk is emitted.
    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        trailingSilenceSamples = 0
        sawSpeech = false
    }

    /// Buffered audio, in seconds — for callers that want to surface progress.
    public var bufferedSeconds: Double { Double(buffer.count) / Double(sampleRate) }

    private mutating func takeAll() -> [Float] {
        let out = buffer
        buffer.removeAll(keepingCapacity: true)
        trailingSilenceSamples = 0
        sawSpeech = false
        return out
    }

    private mutating func take(_ count: Int) -> [Float] {
        let n = min(count, buffer.count)
        let out = Array(buffer[0..<n])
        buffer.removeFirst(n)
        // The removed prefix may have carried the trailing-silence tail; recompute
        // conservatively from what remains rather than tracking per-sample.
        trailingSilenceSamples = min(trailingSilenceSamples, buffer.count)
        if buffer.isEmpty { sawSpeech = false }
        return out
    }

    /// Root-mean-square level of a block (the internal energy proxy).
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}
