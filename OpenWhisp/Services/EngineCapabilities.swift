import Foundation

/// What each transcription engine can actually do.
///
/// The engines are not interchangeable, and pretending otherwise is a recurring
/// source of user-visible bugs: a setting is offered, the user turns it on, and
/// the engine silently discards it. That has now happened twice — translation on
/// Parakeet (#175) and custom vocabulary on Parakeet/WhisperKit/Apple Speech
/// (MAK-70) — because capability lived as ad-hoc engine-name comparisons scattered
/// across call sites instead of as one thing to ask.
///
/// This is the single place to ask "can engine X do Y?". It is deliberately pure
/// (no AppKit, no engine instances) so the UI, the pipeline, and `swift test` can
/// all consult the same answers.
///
/// MAK-69 will move these declarations onto the engines themselves and add a
/// router; until then, keeping the knowledge here — rather than inline at each
/// call site — is what makes that migration a refactor instead of another hunt.
public enum EngineCapabilities {
    // Engine identifiers, as persisted in `AppState.transcriptionEngine`.
    public static let whisperCpp = "whisper"
    public static let whisperKit = "whisperKit"
    public static let parakeet = "parakeet"
    public static let appleSpeech = "appleSpeech"
    /// Apple SpeechAnalyzer / SpeechTranscriber — the macOS 26 on-device engine
    /// (MAK-59). ASR-only (no translate), auto-punctuating, ~2× faster than
    /// Whisper on the file path. Distinct from `appleSpeech` (the legacy
    /// SFSpeechRecognizer engine): SpeechAnalyzer is a separate framework API,
    /// hidden entirely on macOS 14/15 where the symbols don't exist.
    public static let speechAnalyzer = "speechAnalyzer"

    /// Which paths an engine can bias toward user-supplied vocabulary terms.
    ///
    /// Not a boolean, because the honest answer isn't one: Parakeet biases on the
    /// batch path but not the live streaming path (MAK-71). Collapsing that to
    /// "parakeet supports vocabulary" would re-create the exact bug this type
    /// exists to prevent — a control that's offered and then quietly does nothing
    /// for the thing the user is actually doing.
    public enum VocabularySupport: Equatable {
        /// The engine discards vocabulary terms everywhere.
        case none
        /// Biased on batch/file paths (files, meetings, re-transcribe) but NOT on
        /// live dictation.
        case batchOnly
        /// Biased on every path, live dictation included.
        case all

        public var isSupportedAnywhere: Bool { self != .none }
    }

    /// How each engine handles vocabulary bias terms.
    ///
    ///   - **whisper.cpp** — `.all`. Takes a free-text `initial_prompt` (`--prompt`
    ///     on the CLI, a `prompt` form field on the server) on both paths.
    ///   - **parakeet** — `.batchOnly`. Has no prompt concept, but FluidAudio ships
    ///     a CTC context-biasing subsystem (a port of NVIDIA's CTC-WS word spotter,
    ///     arXiv:2406.07096); `ParakeetVocabularyBiaser` drives it as a second pass
    ///     over the finished transcript. Batch only: rescoring needs the full
    ///     log-prob matrix over complete audio, and FluidAudio documents weak
    ///     streaming support (no cross-chunk detection, poor multi-word). Costs a
    ///     separate ~97.5MB CTC-110M model, since TDT v3 has no CTC head.
    ///     NB: FluidAudio's own `CustomVocabulary.md` documents a
    ///     `transcribe(_:customVocabulary:)` call that **does not exist** — read the
    ///     source, not the doc.
    ///   - **whisperKit** — `.none` for now. Biases via `DecodingOptions.promptTokens:
    ///     [Int]?` (token IDs, not a string); wiring it needs the WhisperKit
    ///     tokenizer. A known pilot limitation, not a dead end (MAK-69).
    ///   - **appleSpeech** — `.none` for now. Apple offers
    ///     `SFSpeechAudioBufferRecognitionRequest.contextualStrings`, unwired (MAK-69).
    ///   - **speechAnalyzer** — `.none` for now. SpeechAnalyzer exposes
    ///     `AnalysisContext.contextualStrings`, unwired (MAK-59/69).
    ///
    /// Note this covers **bias terms only**. Vocabulary *substitutions* are a local
    /// regex pass applied after transcription (`VocabularySubstitutor`), so they
    /// work on every engine and must stay offered everywhere.
    public static func vocabularySupport(transcriptionEngine: String) -> VocabularySupport {
        switch transcriptionEngine {
        case whisperCpp: return .all
        case parakeet:   return .batchOnly
        default:         return .none
        }
    }

    /// Whether `engine` biases recognition toward custom vocabulary terms on ANY
    /// path. The single source of truth for the vocabulary UI's bias-terms gate:
    /// the field is worth offering if the terms reach the engine somewhere.
    /// Use `vocabularySupport` directly when the *path* matters.
    public static func supportsVocabularyBiasing(transcriptionEngine: String) -> Bool {
        vocabularySupport(transcriptionEngine: transcriptionEngine).isSupportedAnywhere
    }

    /// Human-readable engine name, for UI that has to explain a capability gap
    /// ("… needs WhisperKit") rather than silently hiding a control.
    public static func displayName(transcriptionEngine: String) -> String {
        switch transcriptionEngine {
        case whisperCpp:   return "whisper.cpp"
        case whisperKit:   return "WhisperKit"
        case parakeet:     return "Parakeet"
        case appleSpeech:  return "Apple Speech"
        case speechAnalyzer: return "Apple SpeechAnalyzer"
        default:           return transcriptionEngine
        }
    }
}
