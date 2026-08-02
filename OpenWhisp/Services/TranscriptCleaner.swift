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
public struct TranscriptCleaner {
    public struct Config {
        public var language: String
        public var customVocabularyEnabled: Bool
        public var substitutions: [Vocabulary.Substitution]
        public var smartFormattingEnabled: Bool
        public var fillerRemovalEnabled: Bool
        public var spokenPunctuationEnabled: Bool

        // --- Opt-in structural formatting (MAK-20), all default OFF -----------
        // Threaded into SmartFormatter.Options below. Off by default so behavior
        // is unchanged until a caller / Settings opts in. UI wiring is a
        // deliberate follow-up (see PR notes) — no Settings toggles yet.
        public var normalizeNumbers: Bool
        public var normalizeCurrency: Bool
        public var spokenListsEnabled: Bool
        public var basicMarkdownEnabled: Bool

        /// Rewrite spoken filenames to editor `@`-mentions (MAK-48). Default OFF.
        /// `AppState` sets this true ONLY when the user's setting is on AND the
        /// frontmost app is a known AI-native editor (see
        /// `FileTagTransform.appliesTo(bundleID:)`), so ordinary dictation into
        /// non-editor apps is never touched.
        public var fileTaggingEnabled: Bool

        public init(
            language: String,
            customVocabularyEnabled: Bool,
            substitutions: [Vocabulary.Substitution],
            smartFormattingEnabled: Bool,
            fillerRemovalEnabled: Bool,
            spokenPunctuationEnabled: Bool,
            normalizeNumbers: Bool = false,
            normalizeCurrency: Bool = false,
            spokenListsEnabled: Bool = false,
            basicMarkdownEnabled: Bool = false,
            fileTaggingEnabled: Bool = false
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
            self.fileTaggingEnabled = fileTaggingEnabled
        }
    }

    public let config: Config

    public init(config: Config) {
        self.config = config
    }

    /// Clean a transcript. `isFinalTranscript` enables the trailing
    /// meta-instruction strip (only meaningful on the whole final utterance, not
    /// per live chunk). Returns "" when the transcript is empty/ignorable.
    public func clean(_ text: String, isFinalTranscript: Bool) -> String {
        // 1+2) Normalize and drop ignorable transcripts BEFORE formatting so we
        //      never capitalize/punctuate a marker we're about to discard.
        guard var normalized = preVocabularyNormalized(text) else { return "" }

        // 3) Vocabulary substitutions before formatting, so a corrected term
        //    (e.g. "claude code" -> "Claude Code") is then cased/spaced consistently.
        if let sub = vocabularyStage {
            normalized = sub.apply(to: normalized)
        }

        // 4) Smart formatting (caps / punctuation / fillers / spoken punctuation).
        if let fmt = smartFormatterStage {
            normalized = fmt.format(normalized, language: config.language)
        }

        // 4b) File-tagging (MAK-48): rewrite spoken filenames to editor @-mentions.
        //     Runs AFTER formatting so it sees the collapsed whitespace and the
        //     capitalizer never re-capitalizes a mid-sentence "@main.ts". Gated to
        //     Cursor/Windsurf by the caller (config.fileTaggingEnabled), so it's a
        //     no-op — byte-for-byte pass-through — everywhere else.
        if config.fileTaggingEnabled {
            normalized = FileTagTransform.transform(normalized)
        }

        // 5) Strip a trailing "translate this into English" / "transcribe this"
        //    the user spoke as an instruction — only on the whole final transcript.
        if isFinalTranscript {
            normalized = MetaInstructionStripper.strip(normalized)
        }

        return normalized
    }

    /// Which vocabulary substitutions would fire against `rawTranscript` — matched
    /// against the SAME normalized, pre-substitution text `clean` feeds the
    /// vocabulary stage (steps 1–2 above), so "counted as used" and "actually
    /// rewrote" can't diverge. This exists because a post-`clean` transcript has
    /// already had its `from` phrases rewritten to `to` — matching THAT would
    /// (almost) never fire, silently zeroing the self-learning dictionary's usage
    /// counts (MAK-41 Part A). Crucially, live-chunk sessions clean each CHUNK
    /// (vocabulary applied per chunk) and accumulate the substituted text, so the
    /// firing decision must be captured per `clean` call on the raw input — the
    /// session's final accumulated text no longer contains the `from` phrases.
    /// Empty when vocabulary is off / no rules / the transcript is ignorable.
    public func firedSubstitutionIDs(inRawTranscript rawTranscript: String) -> Set<Vocabulary.Substitution.ID> {
        guard let sub = vocabularyStage,
              let normalized = preVocabularyNormalized(rawTranscript) else { return [] }
        return sub.firedSubstitutionIDs(in: normalized)
    }

    /// ONLY the vocabulary substitutions, applied to the raw transcript — the
    /// pre-translation pass for text-path translate sessions (MAK-95).
    ///
    /// Substitution rules key on what the engine actually HEARD, in the SPOKEN
    /// language ("пара кит" → "parakeet"). On a translate session the final is
    /// translated before the normal `clean` runs, so by then the mishearing has
    /// been mashed into arbitrary English and a source-language rule can never
    /// fire. This runs the substitutions (and nothing else — formatting rules
    /// target the OUTPUT language) on the raw text so the corrected transcript
    /// is what gets translated. Text unchanged when vocabulary is off / no
    /// rules / the transcript is ignorable.
    public func substitutionsApplied(toRawTranscript text: String) -> String {
        guard let sub = vocabularyStage,
              let normalized = preVocabularyNormalized(text) else { return text }
        return sub.apply(to: normalized)
    }

    /// Steps 1–2 of `clean`: whitespace/marker normalization + the ignorable
    /// guard, i.e. exactly the text the vocabulary stage runs against. Nil when
    /// the transcript is ignorable. Shared by `clean`,
    /// `substitutionsApplied(toRawTranscript:)`, and
    /// `firedSubstitutionIDs(inRawTranscript:)` so they can never disagree.
    private func preVocabularyNormalized(_ text: String) -> String? {
        // 1) Normalize whitespace and strip whisper's leading space / stray quotes,
        //    after removing non-speech markers like [music] / (laughter).
        var normalized = Self.removeNonSpeechMarkers(from: text)
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "\"'` "))

        // 2) Drop ignorable transcripts.
        guard !Self.isIgnorable(normalized) else { return nil }
        return normalized
    }

    /// The same steps expressed as a composable `PostProcessorChain`, so plugins
    /// and future stages (e.g. an LLM stage) can extend the pipeline uniformly.
    /// `clean(_:isFinalTranscript:)` is the synchronous fast path used today; this
    /// is the extensible form the rest of the roadmap builds on.
    public func makeChain(isFinalTranscript: Bool) -> PostProcessorChain {
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
    public func makeFullChain(isFinalTranscript: Bool, refiner: AsyncTextRefiner?) -> PostProcessorChain {
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
        // File-tagging runs after formatting (see clean() step 4b for why), gated
        // to Cursor/Windsurf by the caller.
        if config.fileTaggingEnabled { stages.append(FileTagStage()) }
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

    public static func removeNonSpeechMarkers(from text: String) -> String {
        var cleaned = text
        for term in markerTerms {
            cleaned = cleaned.replacingOccurrences(of: "[\(term)]", with: "", options: [.caseInsensitive])
            cleaned = cleaned.replacingOccurrences(of: "(\(term))", with: "", options: [.caseInsensitive])
        }
        return cleaned
    }

    public static func isIgnorable(_ text: String) -> Bool {
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

/// Rewrites spoken filenames to editor `@`-mentions (Cursor/Windsurf). Only
/// added to the chain when `Config.fileTaggingEnabled` is set (the caller gates
/// that on the frontmost app being a known editor).
struct FileTagStage: PostProcessor {
    func process(_ text: String, context: PostProcessContext) async throws -> String {
        FileTagTransform.transform(text)
    }
}

/// Strips a trailing translate/transcribe meta-instruction.
struct MetaInstructionStage: PostProcessor {
    func process(_ text: String, context: PostProcessContext) async throws -> String {
        text.isEmpty ? text : MetaInstructionStripper.strip(text)
    }
}
