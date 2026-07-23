import Foundation

/// Silence-based auto-stop (a lightweight VAD) for **agent-initiated** dictation.
///
/// The problem it solves: an agent (or a human answering `openwhisp dictate` at
/// the terminal) has no natural "I'm done" gesture — pressing the dictation
/// hotkey deliberately *cancels* an agent session (the human reclaiming the mic),
/// so without this the utterance can only end on the timeout. This detector
/// watches the same normalized `audioLevel` stream the overlay waveform already
/// consumes and fires once the speaker has clearly spoken and then gone quiet.
///
/// It is a pure state machine driven by `(level, timestamp)` samples so the whole
/// thing is unit-testable with `swift test`: `AppState` feeds it the levels it
/// already computes and a monotonic clock, and acts on the returned decision. It
/// owns no timers and touches no audio APIs.
///
/// Design choices, all conservative to avoid clipping a real answer:
/// - **Arm before firing.** It never fires until it has seen speech — leading
///   silence (the beat before the user starts talking) can't trigger a stop.
/// - **Hangover.** Once armed, it fires only after `silenceToStop` of continuous
///   sub-threshold audio, so natural pauses between words/sentences don't end the
///   turn early.
/// - **Hysteresis.** Speech onset uses a higher threshold than the silence gate,
///   so borderline room noise doesn't flip the armed/idle decision back and forth.
public struct SilenceAutoStop {

    /// Tunable thresholds. Defaults are chosen for the app's normalized `[0,1]`
    /// `AudioLevel` scale (‑52 dB floor → ‑12 dB ceil, gamma 0.7), not raw RMS.
    public struct Config: Equatable {
        /// Normalized level at/above which a sample counts as speech (arms the
        /// detector, and resets the silence run).
        public private(set) var speechLevel: Float
        /// Normalized level at/below which a sample counts as silence. Kept below
        /// `speechLevel` for hysteresis; a sample between the two is neither — it
        /// breaks a silence run without counting as speech.
        public private(set) var silenceLevel: Float
        /// How long a CONTINUOUS run of silence samples must persist *after*
        /// speech before the detector fires.
        public private(set) var silenceToStop: TimeInterval
        /// A floor on how much speech must accrue before a stop is allowed, so a
        /// single stray click can't arm-then-immediately-fire on the next quiet
        /// sample.
        public private(set) var minSpeechToArm: TimeInterval

        public init(
            speechLevel: Float = 0.16,
            silenceLevel: Float = 0.10,
            silenceToStop: TimeInterval = 1.5,
            minSpeechToArm: TimeInterval = 0.30
        ) {
            self.speechLevel = speechLevel
            self.silenceLevel = silenceLevel
            self.silenceToStop = silenceToStop
            self.minSpeechToArm = minSpeechToArm
        }

        public static let `default` = Config()
    }

    private let config: Config

    /// Per-sample cap on speech credit, so a sparse callback cadence (or a stalled
    /// main actor delivering queued samples late) can't inflate the accrued speech
    /// time across gaps that were mostly not speech.
    private static let maxSampleCredit: TimeInterval = 0.25

    /// Cumulative time attributed to contiguous speech (for `minSpeechToArm`).
    private var speechAccumulated: TimeInterval = 0
    /// Timestamp of the last sample classified as speech; nil until first speech.
    private var lastSpeechAt: TimeInterval?
    /// Start of the current CONTINUOUS run of silence samples; nil whenever the
    /// run is broken — by speech or by the hysteresis dead band. This anchors the
    /// hangover: firing requires `silenceToStop` of actual silence samples, not
    /// merely elapsed time since the last loud one (a speaker trailing off in the
    /// dead band must not have that time counted as silence retroactively).
    private var silenceRunStartedAt: TimeInterval?
    /// Whether the previous sample was speech — the interval ending at a speech
    /// sample only counts toward arming when it was speech throughout.
    private var previousWasSpeech = false
    /// Timestamp of the previous sample, to measure inter-sample intervals without
    /// assuming a fixed cadence (the level stream is ~30 Hz but not guaranteed).
    private var lastSampleAt: TimeInterval?

    /// Whether we've seen enough speech to be allowed to fire.
    public var isArmed: Bool {
        lastSpeechAt != nil && speechAccumulated >= config.minSpeechToArm
    }

    public init(config: Config = .default) {
        self.config = config
    }

    /// Feed one `(level, now)` sample. Returns `true` exactly once, on the sample
    /// at which the silence-after-speech condition is first met; the caller should
    /// stop the session and discard the detector. Returns `false` otherwise.
    ///
    /// `now` must be monotonic (e.g. `ProcessInfo.processInfo.systemUptime`);
    /// wall-clock time is fine in tests but must be non-decreasing.
    public mutating func ingest(level: Float, now: TimeInterval) -> Bool {
        // Interval since the previous sample (0 on the first one). Guard against a
        // non-monotonic clock by clamping negatives to 0.
        let dt = lastSampleAt.map { max(0, now - $0) } ?? 0
        lastSampleAt = now

        if level >= config.speechLevel {
            // Speech: credit the interval toward arming only when the previous
            // sample was also speech (capped) — a lone transient after a gap must
            // not inherit the whole gap as "speech time" and defeat minSpeechToArm.
            if previousWasSpeech {
                speechAccumulated += min(dt, Self.maxSampleCredit)
            }
            previousWasSpeech = true
            lastSpeechAt = now
            silenceRunStartedAt = nil
            return false
        }
        previousWasSpeech = false

        if level <= config.silenceLevel {
            guard isArmed else { return false }
            let runStart = silenceRunStartedAt ?? now
            silenceRunStartedAt = runStart
            return (now - runStart) >= config.silenceToStop
        }

        // Hysteresis dead band: neither speech nor silence. It breaks a silence
        // run (the hangover requires continuous silence) without arming anything.
        silenceRunStartedAt = nil
        return false
    }
}

extension SilenceAutoStop.Config {
    /// Silence safety config for a LOCKED user session (MAK-16). Same detector
    /// as the agent bridge but with a MUCH longer hangover: a hands-free user
    /// is likely composing and may pause to think, so this is a "you clearly
    /// walked away" backstop (~8s of continuous silence after speech), never a
    /// quick finish.
    public static let lockSafety = SilenceAutoStop.Config(silenceToStop: 8.0)

    /// Lock-safety config for quiet mode: the lowered whisper-friendly
    /// speech/silence gates (so a whisper still arms the detector) but keeping
    /// the long 8s safety stop, so a whispered session is still protected from
    /// running forever.
    public static let quietLockSafety: SilenceAutoStop.Config = {
        let q = QuietDictationMode.quietSilenceAutoStopConfig
        return SilenceAutoStop.Config(
            speechLevel: q.speechLevel,
            silenceLevel: q.silenceLevel,
            silenceToStop: 8.0,
            minSpeechToArm: q.minSpeechToArm
        )
    }()
}
