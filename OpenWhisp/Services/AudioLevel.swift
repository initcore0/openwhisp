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

    /// Map an already-0…1 relative energy (e.g. WhisperKit's `bufferEnergy`) onto the
    /// same perceptual curve so all engines feel consistent. Treats the input as a
    /// linear amplitude.
    static func fromRelativeEnergy(_ energy: Float) -> Float {
        fromRMS(max(0, min(1, energy)))
    }
}
