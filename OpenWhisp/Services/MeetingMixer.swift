import Foundation

// MARK: - MeetingMixer

/// Pure, Foundation-only two-stream audio mixer for Meeting mode (MAK-50).
///
/// Two mono Float32 sample streams (system audio + microphone), each already
/// resampled to the same rate (16 kHz mono), arrive in independently-sized
/// chunks at independent cadences. `MeetingMixer` accumulates them and emits the
/// mixed frontier — the prefix for which BOTH streams have samples available —
/// as combined Float32 samples, retaining each stream's unmatched tail for the
/// next call.
///
/// ## Mixing law: 0.5/0.5 average with a hard clip guard
///
/// We mix as `out = 0.5*a + 0.5*b`, then hard-clamp to [-1, 1]. Averaging (rather
/// than a raw sum) means two full-scale inputs can never exceed full scale, so
/// the common case never clips. The clamp is a belt-and-suspenders guard that
/// only bites if a caller feeds samples already outside [-1, 1]. This trades a
/// little headroom (each leg is 6 dB quieter than a raw sum) for a guaranteed
/// no-clip mix — the right call for a meeting recording where intelligibility,
/// not loudness, matters, and downstream auto-gain can lift the result.
///
/// ## Drift handling (honest limits)
///
/// v1 does *naive frontier mixing*: it aligns the two streams purely by sample
/// count from the start of the session, with no timestamp resync. If the two
/// capture clocks drift (system-audio clock vs. mic clock), the alignment slowly
/// slides — a few tens of milliseconds over a long meeting is typical and
/// inaudible for a transcript. It does NOT correct for:
///   - large clock drift (many seconds over hours) — the legs desync,
///   - a stream that stalls and resumes (its samples simply queue up and mix
///     late, shifting everything after by the stall length),
///   - dropped-sample gaps (no silence is inserted to re-align).
/// These are acceptable for meeting *transcription/summary* v1. A future version
/// would carry per-chunk host timestamps and insert/trim silence to resync.
///
/// One leg ending before the other (e.g. system audio stops, mic keeps going) is
/// handled by `drainRemainder()`: after both legs stop, the longer stream's
/// leftover tail is emitted un-mixed (mixed with implicit silence) so no audio is
/// lost at the end.
struct MeetingMixer {

    /// Pending system-audio samples not yet matched by a mic sample.
    private var systemTail: [Float] = []
    /// Pending microphone samples not yet matched by a system sample.
    private var micTail: [Float] = []

    /// Total mixed frames emitted so far (for duration bookkeeping / tests).
    private(set) var framesEmitted: Int = 0

    init() {}

    // MARK: Ingestion

    mutating func appendSystem(_ samples: [Float]) -> [Float] {
        systemTail.append(contentsOf: samples)
        return mixFrontier()
    }

    mutating func appendMic(_ samples: [Float]) -> [Float] {
        micTail.append(contentsOf: samples)
        return mixFrontier()
    }

    /// Mixes and consumes the prefix both tails have in common. The shorter tail
    /// determines the frontier; each tail keeps its unmatched remainder.
    private mutating func mixFrontier() -> [Float] {
        let n = min(systemTail.count, micTail.count)
        guard n > 0 else { return [] }

        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = Self.mixSample(systemTail[i], micTail[i])
        }
        systemTail.removeFirst(n)
        micTail.removeFirst(n)
        framesEmitted += n
        return out
    }

    /// After BOTH legs have stopped, emit whichever stream still has an unmatched
    /// tail — its samples mixed with implicit silence (i.e. passed through the
    /// same 0.5 gain + clamp so the level is consistent with the mixed body).
    /// Call exactly once at end-of-session; clears both tails.
    mutating func drainRemainder() -> [Float] {
        let leftover = systemTail.isEmpty ? micTail : systemTail
        systemTail.removeAll()
        micTail.removeAll()
        guard !leftover.isEmpty else { return [] }
        var out = [Float](repeating: 0, count: leftover.count)
        for i in 0..<leftover.count {
            out[i] = Self.mixSample(leftover[i], 0)
        }
        framesEmitted += leftover.count
        return out
    }

    /// Frames buffered but not yet mixed (the longer stream's lead over the
    /// shorter). A persistently large value signals real drift/stall, not just
    /// chunk-cadence jitter.
    var pendingImbalance: Int { abs(systemTail.count - micTail.count) }

    // MARK: Mixing law

    /// 0.5/0.5 average + hard clip guard. Static + pure so it is trivially
    /// unit-testable and identical everywhere.
    static func mixSample(_ a: Float, _ b: Float) -> Float {
        let mixed = 0.5 * a + 0.5 * b
        if mixed > 1 { return 1 }
        if mixed < -1 { return -1 }
        return mixed
    }
}
