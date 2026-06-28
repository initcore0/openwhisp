import Foundation

/// Derives a lively 0–1 indicator level from the GROWTH of a streaming transcript,
/// for engines whose own energy signal is unusable for a waveform (the WhisperKit
/// streaming path: its VAD only emits state intermittently and its relative-energy
/// array doesn't track the live voice). The preview transcript IS reliably flowing,
/// so we pulse the bars from it instead.
///
/// Model: each time the transcript grows, inject energy proportional to how much new
/// text appeared (sub-linear, so a big revision doesn't slam to full and a one-char
/// tick still registers). Every tick the level decays exponentially toward zero, so
/// between words the bars settle rather than freeze. Pure (Foundation-only) so it
/// lives in OpenWhispCore and is unit-tested; AppState owns the timer that calls
/// `decay(dt:)` and feeds `ingest(transcript:)` from the partial callback.
struct TranscriptActivityMeter {
    /// Current indicator level (0–1).
    private(set) var level: Float = 0

    /// Length of the transcript at the last ingest, to measure growth.
    private var lastLength: Int = 0

    // Tuning.
    /// New characters that map to a full-strength kick (sub-linear via sqrt below).
    private let charsForFullKick: Float
    /// Exponential decay time constant (seconds): higher = bars linger longer.
    private let decayTimeConstant: Float
    /// Floor the kick lifts toward, so even a tiny delta visibly moves the bars.
    private let minKick: Float

    init(
        charsForFullKick: Float = 12,
        decayTimeConstant: Float = 0.45,
        minKick: Float = 0.35
    ) {
        self.charsForFullKick = max(1, charsForFullKick)
        self.decayTimeConstant = max(0.01, decayTimeConstant)
        self.minKick = max(0, min(1, minKick))
    }

    /// Feed the latest streaming transcript. Returns the (possibly raised) level.
    /// Growth raises the level toward a kick sized by the new-character count; a
    /// shorter/equal transcript (revision, reset, no change) leaves the level alone
    /// and lets `decay` carry it down.
    @discardableResult
    mutating func ingest(transcript: String) -> Float {
        let length = transcript.count
        defer { lastLength = max(lastLength, length) }

        let grew = length - lastLength
        guard grew > 0 else { return level }

        // Sub-linear so a large jump doesn't pin to 1 and a 1-char delta still shows.
        let strength = min(1, sqrt(Float(grew) / charsForFullKick))
        let kick = max(minKick, strength)
        // Take the louder of current level and this kick (attack instantly, never
        // duck an ongoing pulse).
        level = max(level, kick)
        return level
    }

    /// Advance time by `dt` seconds, decaying the level exponentially toward zero.
    /// Returns the new level.
    @discardableResult
    mutating func decay(dt: Float) -> Float {
        guard dt > 0, level > 0 else { return level }
        // Exponential decay: level *= e^(-dt / tau).
        let factor = expf(-dt / decayTimeConstant)
        level *= factor
        if level < 0.001 { level = 0 }   // snap to rest so the bars fully settle
        return level
    }

    /// Reset for a new session (level to rest, growth baseline cleared).
    mutating func reset() {
        level = 0
        lastLength = 0
    }
}
