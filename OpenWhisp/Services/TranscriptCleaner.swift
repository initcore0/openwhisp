import Foundation

/// The local, on-device transcript post-processing pipeline, assembled as a
/// `PostProcessorChain`. This is the OS-independent core of what used to live as
/// hardcoded steps in `AppState.postProcess(...)`: normalize → drop non-speech
/// markers → (vocabulary substitutions) → (smart formatting) → (meta-instruction
/// strip). Pure and Foundation-only, so it lives in `OpenWhispCore` and is unit-
/// tested directly.
///
/// The async LLM pass (rephrase / improve-translation / voice commands) is NOT
/// part of this chain — it has its own control flow (session guards, status,
/// fallback-on-failure) in AppState. It can be added as a `PostProcessor` stage
/// later; this stage covers exactly the prior synchronous behavior.
struct TranscriptCleaner {
    struct Config {
        var language: String
        var customVocabularyEnabled: Bool
        var substitutions: [Vocabulary.Substitution]
        var smartFormattingEnabled: Bool
        var fillerRemovalEnabled: Bool
        var spokenPunctuationEnabled: Bool

        // --- Opt-in structural formatting (MAK-20), all default OFF -----------
        // Threaded into SmartFormatter.Options below. Off by default so behavior
        // is unchanged until a caller / Settings opts in. UI wiring is a
        // deliberate follow-up (see PR notes) — no Settings toggles yet.
        var normalizeNumbers: Bool
        var normalizeCurrency: Bool
        var spokenListsEnabled: Bool
        var basicMarkdownEnabled: Bool

        init(
            language: String,
            customVocabularyEnabled: Bool,
            substitutions: [Vocabulary.Substitution],
            smartFormattingEnabled: Bool,
            fillerRemovalEnabled: Bool,
            spokenPunctuationEnabled: Bool,
            normalizeNumbers: Bool = false,
            normalizeCurrency: Bool = false,
            spokenListsEnabled: Bool = false,
            basicMarkdownEnabled: Bool = false
        ) {
            self.language = language
            self.customVocabularyEnabled = customVocabularyEnabled
            self.substitutions = substitutions
            self.smartFormattingEnabled = smartFormattingEnabled
            self.fillerRemovalEnabled = fillerRemovalEnabled
            self.spokenPunctuationEnabled = spokenPunctuationEnabled
            self.normalizeNumbers = normalizeNumbers
            self.normalizeCurrency = normalizeCurrency
            self.spokenListsEnabled = spokenListsEnabled
            self.basicMarkdownEnabled = basicMarkdownEnabled
        }
    }

    let config: Config

    init(config: Config) {
        self.config = config
    }

    /// Clean a transcript. `isFinalTranscript` enables the trailing
    /// meta-instruction strip (only meaningful on the whole final utterance, not
    /// per live chunk). Returns "" when the transcript is empty/ignorable.
    func clean(_ text: String, isFinalTranscript: Bool) -> String {
        // 1) Normalize whitespace and strip whisper's leading space / stray quotes,
        //    after removing non-speech markers like [music] / (laughter).
        var normalized = Self.removeNonSpeechMarkers(from: text)
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "\"'` "))

        // 2) Drop ignorable transcripts BEFORE formatting so we never
        //    capitalize/punctuate a marker we're about to discard.
        guard !Self.isIgnorable(normalized) else { return "" }

        // 3) Vocabulary substitutions before formatting, so a corrected term
        //    (e.g. "claude code" -> "Claude Code") is then cased/spaced consistently.
        if let sub = vocabularyStage {
            normalized = sub.apply(to: normalized)
        }

        // 4) Smart formatting (caps / punctuation / fillers / spoken punctuation).
        if let fmt = smartFormatterStage {
            normalized = fmt.format(normalized, language: config.language)
        }

        // 5) Strip a trailing "translate this into English" / "transcribe this"
        //    the user spoke as an instruction — only on the whole final transcript.
        if isFinalTranscript {
            normalized = MetaInstructionStripper.strip(normalized)
        }

        return normalized
    }

    /// The same steps expressed as a composable `PostProcessorChain`, so plugins
    /// and future stages (e.g. an LLM stage) can extend the pipeline uniformly.
    /// `clean(_:isFinalTranscript:)` is the synchronous fast path used today; this
    /// is the extensible form the rest of the roadmap builds on.
    func makeChain(isFinalTranscript: Bool) -> PostProcessorChain {
        PostProcessorChain(localStages(isFinalTranscript: isFinalTranscript))
    }

    /// The ONE real chain the roadmap asked for (MAK-15):
    /// `VocabularySubstitutor → SmartFormatter → AIPostProcessor`, on top of the
    /// existing normalize/marker/ignorable/meta stages, in their current order.
    ///
    /// This is the single ordered place transforms drop in. The local stages are
    /// byte-identical to `clean(_:isFinalTranscript:)` (see `makeChain`); the AI
    /// stage appends the injected LLM refiner and re-cleans its output with a
    /// NON-final pass — reproducing `AppState.completeFinalText`'s
    /// `postProcess(processedText)` and its empty/failure fallbacks exactly.
    ///
    /// `refiner == nil` yields a chain identical to `makeChain` (local-only), so a
    /// session with the AI step disabled routes through the very same assembly.
    func makeFullChain(isFinalTranscript: Bool, refiner: AsyncTextRefiner?) -> PostProcessorChain {
        var stages = localStages(isFinalTranscript: isFinalTranscript)
        // The AI stage re-cleans its output the way the app does: a NON-final
        // `clean` (no meta-strip — the LLM result is not a spoken instruction).
        let reclean: @Sendable (String) -> String = { [config] text in
            TranscriptCleaner(config: config).clean(text, isFinalTranscript: false)
        }
        stages.append(AIPostProcessor(refiner: refiner, reclean: reclean))
        return PostProcessorChain(stages)
    }

    /// The local (non-AI) stage list, shared by `makeChain` and `makeFullChain` so
    /// the two can never disagree on the ordering of the on-device pipeline.
    private func localStages(isFinalTranscript: Bool) -> [PostProcessor] {
        var stages: [PostProcessor] = [NonSpeechMarkerStage(), NormalizeStage(), IgnorableGuardStage()]
        if let sub = vocabularyStage { stages.append(sub) }
        if let fmt = smartFormatterStage { stages.append(fmt) }
        if isFinalTranscript { stages.append(MetaInstructionStage()) }
        return stages
    }

    // Single source of truth for the optional stages, so clean() and makeChain()
    // can never disagree on gating or formatter options.
    private var vocabularyStage: VocabularySubstitutor? {
        guard config.customVocabularyEnabled, !config.substitutions.isEmpty else { return nil }
        return VocabularySubstitutor(substitutions: config.substitutions)
    }

    private var smartFormatterStage: SmartFormatter? {
        guard config.smartFormattingEnabled else { return nil }
        return SmartFormatter(options: SmartFormatter.Options(
            removeFillers: config.fillerRemovalEnabled,
            applySpokenPunctuation: config.spokenPunctuationEnabled,
            capitalizeSentences: true,
            ensureTerminalPunctuation: false,
            normalizeNumbers: config.normalizeNumbers,
            normalizeCurrency: config.normalizeCurrency,
            spokenLists: config.spokenListsEnabled,
            basicMarkdown: config.basicMarkdownEnabled
        ))
    }

    // MARK: - Pure helpers (moved out of AppState)

    static func removeNonSpeechMarkers(from text: String) -> String {
        var cleaned = text
        for term in markerTerms {
            cleaned = cleaned.replacingOccurrences(of: "[\(term)]", with: "", options: [.caseInsensitive])
            cleaned = cleaned.replacingOccurrences(of: "(\(term))", with: "", options: [.caseInsensitive])
        }
        return cleaned
    }

    static func isIgnorable(_ text: String) -> Bool {
        let lowercased = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowercased.isEmpty || ignorableTokens.contains(lowercased)
    }

    private static let markerTerms = [
        "blank_audio", "silence", "no speech", "music", "video playback",
        "background noise", "noise", "static", "applause", "laughter", "laughing",
        "cough", "coughing", "sigh", "breath", "breathing", "inaudible", "unintelligible"
    ]

    private static let ignorableTokens: Set<String> = [
        "[blank_audio]", "[silence]", "(silence)", "[no speech]", "(no speech)",
        "[music]", "(music)", "[video playback]", "(video playback)",
        "[background noise]", "(background noise)", "[noise]", "(noise)",
        "[applause]", "(applause)", "[laughter]", "(laughter)"
    ]
}

// MARK: - PostProcessor stage adapters

/// Removes non-speech markers ([music], (laughter), …).
struct NonSpeechMarkerStage: PostProcessor {
    func process(_ text: String, context: PostProcessContext) async throws -> String {
        TranscriptCleaner.removeNonSpeechMarkers(from: text)
    }
}

/// Collapses whitespace / newlines and trims stray quotes.
struct NormalizeStage: PostProcessor {
    func process(_ text: String, context: PostProcessContext) async throws -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'` "))
    }
}

/// Collapses an ignorable transcript to "" so downstream stages no-op.
struct IgnorableGuardStage: PostProcessor {
    func process(_ text: String, context: PostProcessContext) async throws -> String {
        TranscriptCleaner.isIgnorable(text) ? "" : text
    }
}

/// Strips a trailing translate/transcribe meta-instruction.
struct MetaInstructionStage: PostProcessor {
    func process(_ text: String, context: PostProcessContext) async throws -> String {
        text.isEmpty ? text : MetaInstructionStripper.strip(text)
    }
}
