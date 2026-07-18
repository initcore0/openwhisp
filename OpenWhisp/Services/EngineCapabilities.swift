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
/// MAK-69 grows this from static name-sets into a per-engine capability *record*
/// (`Capabilities`, keyed by engine id in `table`), so every capability is
/// declared once per engine rather than re-derived at each call site. The old
/// free functions (`vocabularySupport`, `supportsVocabularyBiasing`,
/// `displayName`) remain as thin readers over the record, so existing call sites
/// and the LanguageResolver translate rule keep working unchanged.
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

    /// Every engine id the app can be set to, in a stable display order. The
    /// contract test iterates this, so adding engine #6 fails its per-engine
    /// assertions until the new engine's `Capabilities` record is declared.
    public static let allEngineIDs: [String] = [
        whisperCpp, whisperKit, parakeet, appleSpeech, speechAnalyzer,
    ]

    // MARK: - Vocabulary bias support (per path)

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
        /// Whether the live streaming (dictation) path honors bias terms.
        public var honorsStreaming: Bool { self == .all }
        /// Whether the batch/file path honors bias terms.
        public var honorsBatch: Bool { self != .none }
    }

    // MARK: - Supported languages

    /// The language coverage an engine declares. Kept coarse on purpose: the UI
    /// gates the language *picker* at pick-time on this, so it must answer "can
    /// this engine ever produce output in language X?" purely (no model loaded).
    public enum LanguageCoverage: Equatable {
        /// Multilingual: any of the picker's language codes (and "auto") is fine.
        /// The whisper engines and Parakeet's multilingual variant.
        case multilingual
        /// English only. A fixed non-English pick is refused up front (Parakeet's
        /// English-only streaming variants, per ParakeetLanguageGate).
        case englishOnly
        /// Locale-gated: coverage is whatever locales the OS/framework has
        /// installed (Apple Speech, SpeechAnalyzer). Can't be answered purely, so
        /// the picker allows the pick and the engine reports an unavailable-locale
        /// error at start-time if the locale isn't installed.
        case localeInstalled

        /// Whether a fixed (non-"auto") `languageCode` is allowed at PICK time.
        /// "auto" and English are always allowed. `localeInstalled` allows the
        /// pick and defers the real check to start-time (it can't be known purely).
        public func allowsPick(languageCode: String) -> Bool {
            let base = ParakeetLanguageHint.baseCode(from: languageCode)
            switch self {
            case .multilingual, .localeInstalled: return true
            case .englishOnly:                    return base == nil || base == "en"
            }
        }
    }

    // MARK: - The capability record

    /// The full capability declaration for one engine. One record per engine in
    /// `table` — this is the single object the UI and pipeline ask, so a new
    /// engine is a new record (and the contract test forces its every field to be
    /// a deliberate choice).
    public struct Capabilities: Equatable {
        /// Stable engine id (matches `AppState.transcriptionEngine`).
        public let id: String
        /// Human-readable name for capability-gap copy ("… needs WhisperKit").
        public let displayName: String
        /// Whether the engine has a speech→English translate task.
        public let translation: Bool
        /// Vocabulary/prompt biasing, split by path (batch vs. live streaming).
        public let vocabulary: VocabularySupport
        /// Whether the engine emits interim (partial) hypotheses while streaming.
        public let streamingPartials: Bool
        /// Whether the engine can emit per-word timestamps.
        public let wordTimestamps: Bool
        /// Language coverage, for the pick-time language gate.
        public let languages: LanguageCoverage

        public init(
            id: String,
            displayName: String,
            translation: Bool,
            vocabulary: VocabularySupport,
            streamingPartials: Bool,
            wordTimestamps: Bool,
            languages: LanguageCoverage
        ) {
            self.id = id
            self.displayName = displayName
            self.translation = translation
            self.vocabulary = vocabulary
            self.streamingPartials = streamingPartials
            self.wordTimestamps = wordTimestamps
            self.languages = languages
        }
    }

    /// The capability matrix — the single source of truth. Every field is a
    /// deliberate declaration; see the per-engine notes below.
    ///
    ///   - **whisper.cpp** — translates; biases via a free-text `initial_prompt`
    ///     on both paths (`.all`); word timestamps available; multilingual.
    ///   - **whisperKit** — translates; biases via `DecodingOptions.promptTokens`
    ///     (token IDs from the WhisperKit tokenizer) on both paths, wired in
    ///     MAK-69 (`.all`); word timestamps available; multilingual.
    ///   - **parakeet** — ASR-only (no translate, MAK-46). Biases via FluidAudio's
    ///     CTC-WS word spotter as a second pass over the finished transcript —
    ///     batch only (`.batchOnly`, MAK-71): rescoring needs the full log-prob
    ///     matrix over complete audio, and FluidAudio documents weak streaming
    ///     support. Streaming partials yes; word timestamps yes. Language coverage
    ///     is per-variant, and the multilingual variant is the app default, so the
    ///     coarse table declares `.multilingual`; the English-only variants are
    ///     refused at start-time by `ParakeetLanguageGate` (which has the variant
    ///     in hand). NB: FluidAudio's own `CustomVocabulary.md` documents a
    ///     `transcribe(_:customVocabulary:)` call that **does not exist** — read
    ///     the source, not the doc.
    ///   - **appleSpeech** — ASR-only. Biases via
    ///     `SFSpeechAudioBufferRecognitionRequest.contextualStrings`, wired in
    ///     MAK-69. It's a live-recognizer request field, so this is a streaming
    ///     path — hence `.all` (the app drives Apple Speech only as a streamer).
    ///     Locale-gated languages; streaming partials yes; no word timestamps
    ///     surfaced.
    ///   - **speechAnalyzer** — ASR-only. `AnalysisContext.contextualStrings`
    ///     exists but is only reachable behind the `#if compiler(>=6.2)` /
    ///     `macOS 26` gates and isn't wired through the current bridge, so it is
    ///     declared **unsupported** (`.none`) — offered-iff-honored means we don't
    ///     claim it until the bridge carries it. Locale-gated; streaming partials
    ///     yes; no word timestamps surfaced.
    private static let table: [String: Capabilities] = Dictionary(
        uniqueKeysWithValues: [
            Capabilities(
                id: whisperCpp, displayName: "whisper.cpp",
                translation: true, vocabulary: .all,
                streamingPartials: false, wordTimestamps: true,
                languages: .multilingual),
            Capabilities(
                id: whisperKit, displayName: "WhisperKit",
                translation: true, vocabulary: .all,
                streamingPartials: true, wordTimestamps: true,
                languages: .multilingual),
            Capabilities(
                id: parakeet, displayName: "Parakeet",
                translation: false, vocabulary: .batchOnly,
                streamingPartials: true, wordTimestamps: true,
                languages: .multilingual),
            Capabilities(
                id: appleSpeech, displayName: "Apple Speech",
                translation: false, vocabulary: .all,
                streamingPartials: true, wordTimestamps: false,
                languages: .localeInstalled),
            Capabilities(
                id: speechAnalyzer, displayName: "Apple SpeechAnalyzer",
                translation: false, vocabulary: .none,
                streamingPartials: true, wordTimestamps: false,
                languages: .localeInstalled),
        ].map { ($0.id, $0) })

    /// The capability record for `transcriptionEngine`. An unknown id claims
    /// nothing (a lean/dead-code default that can't silently over-promise): no
    /// translate, no vocabulary, no partials, no timestamps, English-only.
    public static func capabilities(for transcriptionEngine: String) -> Capabilities {
        table[transcriptionEngine] ?? Capabilities(
            id: transcriptionEngine,
            displayName: transcriptionEngine,
            translation: false, vocabulary: .none,
            streamingPartials: false, wordTimestamps: false,
            languages: .englishOnly)
    }

    // MARK: - Thin readers (backward-compatible free functions)

    /// How each engine handles vocabulary bias terms. See `Capabilities.vocabulary`.
    ///
    /// Note this covers **bias terms only**. Vocabulary *substitutions* are a local
    /// regex pass applied after transcription (`VocabularySubstitutor`), so they
    /// work on every engine and must stay offered everywhere.
    public static func vocabularySupport(transcriptionEngine: String) -> VocabularySupport {
        capabilities(for: transcriptionEngine).vocabulary
    }

    /// Whether `engine` biases recognition toward custom vocabulary terms on ANY
    /// path. The single source of truth for the vocabulary UI's bias-terms gate:
    /// the field is worth offering if the terms reach the engine somewhere.
    /// Use `vocabularySupport` directly when the *path* matters.
    public static func supportsVocabularyBiasing(transcriptionEngine: String) -> Bool {
        vocabularySupport(transcriptionEngine: transcriptionEngine).isSupportedAnywhere
    }

    /// Whether the live streaming (dictation) path honors bias terms on `engine`.
    /// This is the gate for whether to hand the streaming engine a `prompt`:
    /// offered-iff-honored means AppState only passes bias terms to `start` when
    /// this is true. (Batch paths ask `vocabularySupport(_).honorsBatch`.)
    public static func honorsStreamingVocabulary(transcriptionEngine: String) -> Bool {
        vocabularySupport(transcriptionEngine: transcriptionEngine).honorsStreaming
    }

    /// The bias prompt to hand a streaming engine's `start` — the user's
    /// vocabulary prompt when this engine honors vocabulary on the STREAMING
    /// path, else "" (offered-iff-honored, MAK-69): whisper.cpp/WhisperKit/
    /// Apple Speech honor it; Parakeet (batch-only) and SpeechAnalyzer (unwired)
    /// get "" — a declared no-op the vocabulary UI already told the user about,
    /// never a silent drop.
    public static func streamingPrompt(
        transcriptionEngine: String, vocabularyPrompt: String
    ) -> String {
        honorsStreamingVocabulary(transcriptionEngine: transcriptionEngine)
            ? vocabularyPrompt : ""
    }

    /// Whether a fixed language `languageCode` may be PICKED for `engine`. Gates
    /// the language picker at pick-time (not speak-time): an English-only engine
    /// refuses a non-English fixed pick up front rather than emitting garbage.
    public static func allowsLanguagePick(languageCode: String, transcriptionEngine: String) -> Bool {
        capabilities(for: transcriptionEngine).languages.allowsPick(languageCode: languageCode)
    }

    /// Human-readable engine name, for UI that has to explain a capability gap
    /// ("… needs WhisperKit") rather than silently hiding a control.
    public static func displayName(transcriptionEngine: String) -> String {
        capabilities(for: transcriptionEngine).displayName
    }
}
