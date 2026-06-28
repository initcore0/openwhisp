import Foundation

/// Perceptual normalization of raw audio loudness into a lively 0–1 value for the
/// overlay indicator. Pure (Foundation-only) so it lives in OpenWhispCore and is
/// unit-tested, and so every capture path (whisper.cpp recording, the streaming
/// recorder, Apple Speech, WhisperKit) maps loudness the SAME way.
///
/// The problem it fixes: linear RMS for speech sits very low (~0.01–0.1), so the
/// old `rms * 8` barely moved the indicator; and `averagePower` dBFS was heavily
/// compressed. Mapping a speech-relevant dB window to 0–1 with a mild gamma makes
/// normal talking swing across most of the range.
enum AudioLevel {
    /// dBFS window mapped to 0…1. Quiet room ~ -55 dB; normal speech peaks ~ -15 dB.
    static let floorDB: Float = -52
    static let ceilDB: Float = -12
    /// <1 brightens (lifts quiet speech); 0.7 gives a lively-but-not-twitchy curve.
    static let gamma: Float = 0.7

    /// Map a linear RMS amplitude (0…1, e.g. `sqrt(mean(sample^2))`) to a normalized
    /// indicator level (0…1).
    static func fromRMS(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return fromDB(db)
    }

    /// Map a dBFS value (e.g. `AVAudioRecorder.averagePower`) to a normalized level.
    static func fromDB(_ db: Float) -> Float {
        let clamped = min(max(db, floorDB), ceilDB)
        let t = (clamped - floorDB) / (ceilDB - floorDB)   // 0…1 linear in dB
        return powf(max(0, min(1, t)), gamma)
    }

    /// Map WhisperKit's `bufferEnergy` value to a normalized indicator level.
    ///
    /// IMPORTANT: WhisperKit's relative energy is ALREADY a 0…1 perceptual value
    /// (`calculateRelativeEnergy` normalizes the buffer RMS in dB against a rolling
    /// silence reference and clamps to 0…1). It is NOT a tiny linear RMS amplitude.
    /// Pushing it through `fromRMS` (which expects ~0.01–0.1 linear RMS and maps a
    /// −52…−12 dB window) double-compresses it: ~0.02 already reads ~0.57 and
    /// anything ≳0.3 pins to 1.0, so the bars sit near full and barely move — the
    /// "doesn't react to voice" bug.
    ///
    /// Instead use the value directly, with a mild gamma to lift quiet speech into a
    /// livelier range without slamming to the ceiling. Identity at 0 and 1.
    static let relativeEnergyGamma: Float = 0.65
    static func fromRelativeEnergy(_ energy: Float) -> Float {
        let e = max(0, min(1, energy))
        return powf(e, relativeEnergyGamma)
    }

    /// Buffers (~0.1s each) to consider for the live level. A tiny trailing window
    /// smooths single-buffer flicker without lagging the voice.
    static let liveEnergyWindow = 3

    /// Derive the live indicator level from WhisperKit's `bufferEnergy` — a
    /// CUMULATIVE per-0.1s relative-energy history (it grows all session).
    ///
    /// Use the RECENT window, not `history.max()` over the whole array: the all-time
    /// max only ever rises, so it pins the indicator at the loudest moment ever and
    /// the bars freeze after the first sound. The trailing-window max tracks the live
    /// voice and relaxes toward silence between words. Returns nil for empty history
    /// (no update — hold the prior level).
    static func liveLevel(fromEnergyHistory history: [Float]) -> Float? {
        history.suffix(liveEnergyWindow).max().map(fromRelativeEnergy)
    }
}
