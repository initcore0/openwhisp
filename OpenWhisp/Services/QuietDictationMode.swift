import Foundation

/// Quiet-dictation mode (MAK-45, v1): a preprocessing preset that makes whispered
/// / very soft speech decode better, without a custom model.
///
/// It bundles three pure, testable pieces of logic that the capture path applies
/// when the user turns the mode ON:
///
/// 1. **High-gain normalization** (`gain(forPeak:)` / `gain(forRMS:)`) — a stronger
///    auto-gain than the default `AudioRecorder.applyAutoGain`: it aims a soft
///    buffer at a higher target and allows a larger boost ceiling, while keeping
///    the same never-clip guarantees — a noise floor so near-silence isn't blown
///    up into hiss, and a hard limiter so the boost can never exceed what would
///    push the peak past a safe ceiling (no clipping).
///
/// 2. **Whisper-friendly VAD/silence thresholds** (`thresholds`) — a lowered
///    `speechThreshold` (so a whisper's low RMS still registers as speech and opens
///    a chunk) and a slightly longer `silenceDuration` (whispered pauses are quieter
///    and the gate must not clip a trailing soft word), for the pause-based
///    live-chunk recorder.
///
/// 3. **A lowered silence-auto-stop config** (`silenceAutoStopConfig`) — the
///    hands-free / agent-bridge auto-stop watches the normalized `AudioLevel`
///    stream; a whisper sits far lower on that scale, so its speech/silence gates
///    are dropped to match (otherwise a whisper never arms the detector, or a
///    normal between-word pause reads as "stopped").
///
/// All three are pure value logic (no audio APIs, no timers) so they live in
/// OpenWhispCore and are unit-tested with synthetic PCM. The DSP is *applied* in
/// the capture path app-side (`AudioRecorder`), and the thresholds are read by
/// `AppState` when it starts the recorder. When the mode is OFF, none of this is
/// consulted and the pipeline behaves exactly as before (default OFF).
public enum QuietDictationMode {

    // MARK: - High-gain normalization

    /// Tuning for the high-gain normalizer. Defaults are the "quiet mode" preset:
    /// a higher target and a larger ceiling than the default auto-gain, so a very
    /// soft mic is lifted much harder — but still never clips.
    public struct GainConfig: Equatable {
        /// Peak amplitude (0…1) the normalizer aims a soft buffer *toward*. Higher
        /// than the default auto-gain's 0.7 so whispers land at a strong level.
        public var targetPeak: Float
        /// Maximum multiplicative boost. A whisper can sit ~30–40 dB below normal
        /// speech, so the ceiling is far higher than default auto-gain's 12×.
        public var maxGain: Float
        /// Peaks at/below this are treated as silence and left untouched, so room
        /// hiss between whispered words isn't amplified into "speech".
        public var noiseFloor: Float
        /// Hard safety ceiling: the applied gain is additionally clamped so the
        /// resulting peak never exceeds this, guaranteeing no clipping even if
        /// `targetPeak`/`maxGain` were mis-set. Kept <1 for headroom.
        public var clipCeiling: Float

        public init(
            targetPeak: Float = 0.85,
            maxGain: Float = 40.0,
            noiseFloor: Float = 0.004,
            clipCeiling: Float = 0.98
        ) {
            self.targetPeak = targetPeak
            self.maxGain = maxGain
            self.noiseFloor = noiseFloor
            self.clipCeiling = clipCeiling
        }

        public static let `default` = GainConfig()
    }

    /// Compute the gain to apply to a buffer given its measured peak amplitude
    /// (max `abs(sample)`, 0…1). Pure math — the caller measures the peak and
    /// multiplies every sample by the returned factor (then hard-clamps, belt and
    /// suspenders).
    ///
    /// Guarantees:
    /// - **Never < 1** — quiet mode only ever boosts (or leaves alone), never ducks.
    /// - **Silence stays put** — peak ≤ `noiseFloor` returns exactly 1 (no
    ///   amplification of near-silence → no "gain explosion" on a silent buffer).
    /// - **Never clips** — the returned gain is capped at both `maxGain` and
    ///   `clipCeiling / peak`, so `gain * peak ≤ clipCeiling < 1`.
    public static func gain(forPeak peak: Float, config: GainConfig = .default) -> Float {
        // Non-finite / non-positive peak: nothing to boost.
        guard peak.isFinite, peak > config.noiseFloor else { return 1.0 }
        // Desired boost toward the target, then limited so the peak can't cross the
        // clip ceiling, then capped by the absolute ceiling and floored at 1.
        let toward = config.targetPeak / peak
        let noClip = config.clipCeiling / peak
        let g = min(toward, noClip, config.maxGain)
        return max(1.0, g)
    }

    /// Convenience: compute gain from an RMS amplitude instead of a peak, assuming
    /// the usual speech crest factor (peak ≈ crest × RMS). Handy where only RMS is
    /// cheaply available (the level meter path).
    public static func gain(
        forRMS rms: Float,
        crestFactor: Float = 3.0,
        config: GainConfig = .default
    ) -> Float {
        gain(forPeak: max(0, rms) * max(1, crestFactor), config: config)
    }

    // MARK: - VAD / silence thresholds (pause-based live-chunk recorder)

    /// The pause-based recorder's tuning knobs, in the same units
    /// `AudioRecorder.startStreamingOnSilence` / the `AudioCapture` protocol use.
    public struct Thresholds: Equatable {
        public var silenceDuration: TimeInterval
        public var minimumSpeechDuration: TimeInterval
        public var maximumSpeechDuration: TimeInterval
        public var speechThreshold: Float

        public init(
            silenceDuration: TimeInterval,
            minimumSpeechDuration: TimeInterval,
            maximumSpeechDuration: TimeInterval,
            speechThreshold: Float
        ) {
            self.silenceDuration = silenceDuration
            self.minimumSpeechDuration = minimumSpeechDuration
            self.maximumSpeechDuration = maximumSpeechDuration
            self.speechThreshold = speechThreshold
        }
    }

    /// The recorder's normal defaults (mirrors `AudioCapture`'s convenience
    /// defaults and `AudioRecorder`'s stored values) — used when quiet mode is OFF.
    public static let normalThresholds = Thresholds(
        silenceDuration: 0.75,
        minimumSpeechDuration: 0.35,
        maximumSpeechDuration: 12.0,
        speechThreshold: 0.018
    )

    /// The quiet-mode preset: a much lower `speechThreshold` so a whisper's low RMS
    /// still registers as speech, and a slightly longer silence hangover so a quiet
    /// trailing word isn't clipped by the pause gate. Speech-duration bounds are
    /// left as-is (they're about chunk length, not loudness).
    public static let quietThresholds = Thresholds(
        silenceDuration: 0.90,
        minimumSpeechDuration: 0.35,
        maximumSpeechDuration: 12.0,
        speechThreshold: 0.006
    )

    /// Resolve the pause-based thresholds for a given quiet-mode state.
    public static func thresholds(quietEnabled: Bool) -> Thresholds {
        quietEnabled ? quietThresholds : normalThresholds
    }

    // MARK: - Silence auto-stop (normalized-level detector)

    /// A `SilenceAutoStop.Config` tuned for whispered speech: the arm/silence gates
    /// are dropped well below the defaults (0.16 / 0.10) because a whisper maps to a
    /// much lower normalized `AudioLevel`. Hysteresis (speech > silence) is kept.
    public static let quietSilenceAutoStopConfig = SilenceAutoStop.Config(
        speechLevel: 0.07,
        silenceLevel: 0.035,
        silenceToStop: 1.6,
        minSpeechToArm: 0.30
    )

    /// Resolve the silence-auto-stop config for a given quiet-mode state, so the
    /// caller can swap presets without knowing the numbers.
    public static func silenceAutoStopConfig(quietEnabled: Bool) -> SilenceAutoStop.Config {
        quietEnabled ? quietSilenceAutoStopConfig : .default
    }
}
